defmodule KickTrackerWeb.Plugs.RateLimit do
  @moduledoc """
  Rate limits per visitor address (project.md §19.3), with PlugAttack:

    * pages: 120 a minute;
    * `/data`: 600 a minute (a channel page loads several series);
    * channels' pictures (`/img`): 600 a minute (a page shows many);
    * admin login attempts: 10 a minute per address, and after 20 failures
      in 10 minutes the address is shut out for an hour.

  Exceeding a limit is a 429 with `Retry-After`. The addresses live in
  memory only, for the length of a period.
  """

  use PlugAttack
  import Plug.Conn

  @storage {PlugAttack.Storage.Ets, KickTrackerWeb.Plugs.RateLimit.Storage}

  @doc "The storage process, for the web role's supervision tree."
  def storage_child, do: {PlugAttack.Storage.Ets, name: elem(@storage, 1), clean_period: 60_000}

  rule "login attempts", conn do
    if conn.method == "POST" and conn.path_info == ["admin", "login"] do
      throttle({:login, conn.remote_ip},
        period: 60_000,
        limit: limit(:login, 10),
        storage: @storage
      )
    end
  end

  rule "data", conn do
    if match?(["data" | _], conn.path_info) do
      throttle({:data, conn.remote_ip},
        period: 60_000,
        limit: limit(:data, 600),
        storage: @storage
      )
    end
  end

  # A page shows many channels' pictures at once.
  rule "images", conn do
    if match?(["img" | _], conn.path_info) do
      throttle({:images, conn.remote_ip},
        period: 60_000,
        limit: limit(:images, 600),
        storage: @storage
      )
    end
  end

  rule "pages", conn do
    throttle({:pages, conn.remote_ip},
      period: 60_000,
      limit: limit(:pages, 120),
      storage: @storage
    )
  end

  # Tests lower the limits (config :kick_tracker, :rate_limits).
  defp limit(key, default),
    do: get_in(Application.get_env(:kick_tracker, :rate_limits, []), [key]) || default

  @impl PlugAttack
  def block_action(conn, {:throttle, data}, _opts) do
    retry_s = max(div(data[:expires_at] - System.system_time(:millisecond), 1000), 1)

    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_s))
    |> put_resp_content_type("text/plain")
    |> send_resp(429, "Too many requests. Try again in a minute.")
    |> halt()
  end

  def block_action(conn, _data, _opts), do: conn |> send_resp(429, "Too many requests.") |> halt()

  @impl PlugAttack
  def allow_action(conn, _data, _opts), do: conn

  @failures 20
  @failure_period_ms 600_000
  @ban_ms 3_600_000

  @doc """
  Records a failed admin login; after 20 in 10 minutes the address is
  banned from logging in for an hour. Returns whether it is banned.

  Every failure counts. (PlugAttack's own `fail2ban` keys its entries by
  the millisecond, so failures in the same millisecond, a parallel
  burst, counted once.) Each failure is its own entry, which expires with
  its period and is removed by the storage's cleaner.
  """
  @spec login_failed(Plug.Conn.t()) :: boolean()
  def login_failed(conn) do
    {mod, table} = @storage
    now = System.system_time(:millisecond)
    ip = conn.remote_ip

    if login_banned?(conn) do
      true
    else
      :ets.insert(
        table,
        {{:login_failure, ip, System.unique_integer([:monotonic])}, 0, now + @failure_period_ms}
      )

      recent =
        :ets.select_count(table, [
          {{{:login_failure, ip, :_}, :_, :"$1"}, [{:>, :"$1", now}], [true]}
        ])

      if recent >= @failures do
        :ok = mod.write(table, {:fail2ban_banned, {:login_failed, ip}}, true, now + @ban_ms)
        true
      else
        false
      end
    end
  end

  @doc "Whether an address is banned from logging in."
  @spec login_banned?(Plug.Conn.t()) :: boolean()
  def login_banned?(conn) do
    {mod, opts} = @storage
    now = System.system_time(:millisecond)

    case mod.read(opts, {:fail2ban_banned, {:login_failed, conn.remote_ip}}, now) do
      {:ok, _} -> true
      :error -> false
    end
  end
end
