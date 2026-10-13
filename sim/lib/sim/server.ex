defmodule Sim.Server do
  @moduledoc """
  What the running simulator is: which scenario, which clock, which signing
  key, and which access tokens it has issued.

  The scenario, clock and key are kept in `:persistent_term` so every
  request reads them without going through a process. Tokens change often
  enough to live in an ETS table instead.
  """

  use GenServer

  alias Sim.{Clock, Keys, Scenario}

  @key {__MODULE__, :state}
  @tokens __MODULE__.Tokens

  # The realtime server's ping interval and token lifetime, as the
  # recording showed (25s, 45 minutes).
  @realtime_defaults %{ping_s: 25, ttl_s: 2_700, disconnect_after_ms: nil}

  @type state :: %{scenario: Scenario.t(), clock: Clock.t(), keys: Keys.t()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    scenario = Keyword.get(opts, :scenario) || Scenario.new()
    clock = Keyword.get(opts, :clock) || Clock.new()
    keys = Keyword.get(opts, :keys) || Keys.generate()
    realtime = Map.merge(@realtime_defaults, Map.new(Keyword.get(opts, :realtime, [])))

    :ets.new(@tokens, [:set, :public, :named_table, read_concurrency: true])

    :persistent_term.put(@key, %{scenario: scenario, clock: clock, keys: keys, realtime: realtime})

    {:ok, %{}}
  end

  @doc "The running scenario."
  @spec scenario() :: Scenario.t()
  def scenario, do: state().scenario

  @doc "The simulator's clock."
  @spec clock() :: Clock.t()
  def clock, do: state().clock

  @doc "The public PEM of the key webhooks are signed with."
  @spec public_key_pem() :: String.t()
  def public_key_pem, do: state().keys.pem

  @doc "The private key webhooks are signed with."
  @spec private_key() :: :public_key.rsa_private_key()
  def private_key, do: state().keys.private

  @doc "The fake realtime server's settings: ping interval, token lifetime, disconnect fault."
  @spec realtime() :: map()
  def realtime, do: state().realtime

  @doc "Simulated time now."
  @spec now() :: DateTime.t()
  def now, do: Clock.now(clock(), System.system_time(:millisecond))

  @doc "Replaces the running scenario, for the control API and for tests."
  @spec put_scenario(Scenario.t()) :: :ok
  def put_scenario(%Scenario{} = scenario),
    do: GenServer.call(__MODULE__, {:put, :scenario, scenario})

  @doc "Replaces the clock, e.g. to jump the simulation forward."
  @spec put_clock(Clock.t()) :: :ok
  def put_clock(%Clock{} = clock), do: GenServer.call(__MODULE__, {:put, :clock, clock})

  @doc "Issues an app access token, valid for `expires_in` seconds."
  @spec issue_token(pos_integer()) :: String.t()
  def issue_token(expires_in \\ 5_184_000) do
    token = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    :ets.insert(@tokens, {token, System.system_time(:second) + expires_in})
    token
  end

  @doc "Issues a realtime (chat) guest token, valid for the server's `ttl_s`."
  @spec issue_realtime_token() :: String.t()
  def issue_realtime_token do
    token = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    :ets.insert(@tokens, {{:realtime, token}, System.system_time(:second) + realtime().ttl_s})
    token
  end

  @doc "Whether this realtime token was issued here and hasn't expired."
  @spec valid_realtime_token?(term()) :: boolean()
  def valid_realtime_token?(token) when is_binary(token), do: valid_token?({:realtime, token})
  def valid_realtime_token?(_), do: false

  @doc "Expires every token issued so far, app and realtime, so a client has to fetch a new one."
  @spec expire_tokens() :: :ok
  def expire_tokens do
    :ets.delete_all_objects(@tokens)
    :ok
  end

  @doc "Whether this token was issued here and hasn't expired."
  @spec valid_token?(String.t() | nil) :: boolean()
  def valid_token?(nil), do: false

  def valid_token?(token) do
    case :ets.lookup(@tokens, token) do
      [{^token, expires_at}] -> expires_at > System.system_time(:second)
      [] -> false
    end
  end

  @doc "Whether a simulator is running in this node."
  @spec running?() :: boolean()
  def running?, do: :persistent_term.get(@key, nil) != nil

  @impl true
  def handle_call({:put, field, value}, _from, s) do
    :persistent_term.put(@key, Map.put(state(), field, value))
    {:reply, :ok, s}
  end

  defp state do
    case :persistent_term.get(@key, nil) do
      nil -> raise "the simulator is not running: start Sim.Server first"
      state -> state
    end
  end
end
