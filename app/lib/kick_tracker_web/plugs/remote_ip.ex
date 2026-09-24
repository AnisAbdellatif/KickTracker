defmodule KickTrackerWeb.Plugs.RemoteIp do
  @moduledoc """
  The visitor's address behind our own proxies (Caddy, and Cloudflare if in
  front), for rate limits (project.md §19.3). Only a request arriving from
  a private or loopback address (a proxy on our network) has its
  `X-Forwarded-For` read, and only as many hops as we run
  (`TRUSTED_PROXY_HOPS`, default 1: Caddy): the address that many entries
  from the right is the one our outermost proxy saw. Anything further left
  is what the client claimed, and never trusted.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{remote_ip: ip} = conn, _opts) do
    hops = Application.get_env(:kick_tracker, :trusted_proxy_hops, 1)

    with true <- hops > 0 and private?(ip),
         [_ | _] = header <- Plug.Conn.get_req_header(conn, "x-forwarded-for"),
         {:ok, client} <- pick(header, hops) do
      %{conn | remote_ip: client}
    else
      _ -> conn
    end
  end

  @doc "The address `hops` entries from the right of the X-Forwarded-For chain. Pure."
  @spec pick([String.t()], pos_integer()) :: {:ok, :inet.ip_address()} | :error
  def pick(header, hops) do
    chain =
      header
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    with addr when is_binary(addr) <- Enum.at(chain, -hops),
         {:ok, ip} <- :inet.parse_strict_address(String.to_charlist(addr)) do
      {:ok, ip}
    else
      _ -> :error
    end
  end

  defp private?({127, _, _, _}), do: true
  defp private?({10, _, _, _}), do: true
  defp private?({172, b, _, _}) when b in 16..31, do: true
  defp private?({192, 168, _, _}), do: true
  defp private?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp private?({a, _, _, _, _, _, _, _}) when a in 0xFC00..0xFDFF, do: true
  defp private?(_), do: false
end
