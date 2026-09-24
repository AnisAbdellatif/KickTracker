defmodule Sim.Recorder.WebhookPolicy do
  @moduledoc """
  Decides what the capture server answers to each delivery, to provoke and
  observe Kick's retries:

    * `fail_for_s`: answer 500 to everything for the first N seconds;
    * `fail_first`: answer 500 to the first N attempts of each message id.

  With neither set, every delivery gets 200. Also keeps every delivery's
  message id, time and answer for the retry analysis.
  """

  use Agent

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts) do
    started = System.monotonic_time(:millisecond)

    Agent.start_link(fn ->
      %{
        fail_until: started + Keyword.get(opts, :fail_for_s, 0) * 1000,
        fail_first: Keyword.get(opts, :fail_first, 0),
        attempts: %{},
        log: []
      }
    end)
  end

  @doc "Returns the status to answer with, and records the delivery."
  @spec decide(pid(), String.t()) :: integer()
  def decide(policy, message_id) do
    Agent.get_and_update(policy, fn state ->
      attempt = Map.get(state.attempts, message_id, 0) + 1
      status = status(state, attempt, System.monotonic_time(:millisecond))
      entry = %{message_id: message_id, at_ms: System.system_time(:millisecond), status: status}

      {status,
       %{state | attempts: Map.put(state.attempts, message_id, attempt), log: [entry | state.log]}}
    end)
  end

  @spec deliveries(pid()) :: [map()]
  def deliveries(policy), do: policy |> Agent.get(& &1.log) |> Enum.reverse()

  @doc false
  def status(state, attempt, now) do
    if now < state.fail_until or attempt <= state.fail_first, do: 500, else: 200
  end
end
