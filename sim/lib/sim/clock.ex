defmodule Sim.Clock do
  @moduledoc """
  The simulator's own clock: simulated time, optionally starting elsewhere
  and running faster than real time. Pure; `Sim.Clock.Server` holds one.

  A `speed` above 1 makes a day pass in minutes, which is how weeks of
  history are produced without waiting. Only the simulator's clock moves
  faster: the app under test still runs in real time, so anything it
  measures in wall-clock seconds stays honest.
  """

  defstruct real_epoch_ms: 0, sim_epoch_ms: 0, speed: 1.0

  @type t :: %__MODULE__{real_epoch_ms: integer(), sim_epoch_ms: integer(), speed: float()}

  @doc """
  A clock reading `sim_start` at the moment `real_now` and advancing
  `speed` times as fast.

      iex> clock = Sim.Clock.new(sim_start: ~U[2026-01-01 00:00:00Z], speed: 60, real_now_ms: 1_000)
      iex> Sim.Clock.now(clock, 1_000 + 60_000)
      ~U[2026-01-01 01:00:00.000Z]
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    sim_start = Keyword.get(opts, :sim_start) || DateTime.utc_now()
    speed = opts |> Keyword.get(:speed, 1) |> to_speed()

    %__MODULE__{
      real_epoch_ms: Keyword.get(opts, :real_now_ms, System.system_time(:millisecond)),
      sim_epoch_ms: DateTime.to_unix(sim_start, :millisecond),
      speed: speed
    }
  end

  @doc "Simulated time, in milliseconds since the Unix epoch, at real time `real_now_ms`."
  @spec now_ms(t(), integer()) :: integer()
  def now_ms(%__MODULE__{} = clock, real_now_ms) do
    clock.sim_epoch_ms + round((real_now_ms - clock.real_epoch_ms) * clock.speed)
  end

  @doc "Simulated time as a `DateTime` at real time `real_now_ms`."
  @spec now(t(), integer()) :: DateTime.t()
  def now(%__MODULE__{} = clock, real_now_ms) do
    clock |> now_ms(real_now_ms) |> DateTime.from_unix!(:millisecond)
  end

  @doc "How much real time passes while the simulation advances `sim_ms`."
  @spec real_ms_for(t(), integer()) :: integer()
  def real_ms_for(%__MODULE__{speed: speed}, sim_ms), do: round(sim_ms / speed)

  defp to_speed(speed) when is_number(speed) and speed > 0, do: speed / 1

  defp to_speed(other),
    do: raise(ArgumentError, "speed must be a positive number, got: #{inspect(other)}")
end
