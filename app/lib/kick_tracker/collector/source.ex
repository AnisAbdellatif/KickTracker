defmodule KickTracker.Collector.Source do
  @moduledoc """
  A polled source of data from Kick (project.md §10.3): viewers, subscriber
  totals, followers, and whatever comes next. A source only says **what**
  to ask, **how** to ask it and **what the answer means**; the
  `Collector.SourceRunner` does the rest the same way for all of them:
  the cadence, running requests concurrently under a deadline, isolating
  crashes, recording coverage, journaling the writes, reporting status.

  A cycle:

    1. `units/3` splits the work (e.g. 50 channels per request);
    2. `fetch/1` runs for each unit in its own task: network only, no
       database, no state; it returns `{:ok, data}` only for an answer
       that can be used, and anything else is a failure;
    3. `record/4` turns each outcome into journal operations
       (`Collector.Ops`) and effects, and may update the source's state;
    4. `finish/2` (optional) runs once at the end of the cycle.

  A failed or timed-out fetch writes nothing (a gap, never a zero) and is
  recorded in `coverage` for the unit's channels, under `coverage/0`.

  Effects:

    * `{:send, kick_user_id, message}` — to the channel's process;
    * `{:broadcast, topic, message}` — on PubSub;
    * `{:channel, %Channel{}}` — a channel row changed (a rename, an id
      learnt): refreshes the tracked list and tells its processes.
  """

  alias KickTracker.Channels.Channel

  @type unit :: %{required(:channels) => [Channel.t()], optional(atom()) => term()}
  @type outcome :: {:ok, term()} | {:error, term()}
  @type effect ::
          {:send, integer(), term()} | {:broadcast, String.t(), term()} | {:channel, Channel.t()}
  @type state :: term()

  @doc "A short name, for logs and status."
  @callback name() :: atom()

  @doc "The coverage source this records and the gap that splits a period, or nil."
  @callback coverage() :: {String.t(), pos_integer()} | nil

  @callback init(keyword()) :: state()

  @doc "Time between the starts of two cycles."
  @callback interval_ms(state()) :: pos_integer()

  @doc "How many fetches may run at once, and how long one may take."
  @callback limits(state()) :: %{concurrency: pos_integer(), timeout_ms: pos_integer()}

  @callback units([Channel.t()], state(), DateTime.t()) :: {[unit()], state()}
  @callback fetch(unit()) :: outcome()
  @callback record(unit(), outcome(), DateTime.t(), state()) :: {[term()], [effect()], state()}
  @callback finish(state(), DateTime.t()) :: {[term()], [effect()], state()}

  @doc "A request from elsewhere (e.g. a reading asked for at a stream's start)."
  @callback handle_request(term(), state()) :: state()

  @optional_callbacks finish: 2, handle_request: 2
end
