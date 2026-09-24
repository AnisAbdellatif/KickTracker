defmodule KickTracker.Metrics.Sessionizer do
  @moduledoc """
  Turns what we learn about a channel into streams (project.md §3.3). Pure:
  a state and an observation in, a new state and the writes to make out.

  A stream is identified by Kick's own `started_at`. Three kinds of
  observation feed it:

    * `{:live, started_at, at}`: the stream that started at `started_at`
      was live at `at` (a status event, or a poll reading);
    * `{:ended, started_at, ended_at}`: Kick's end event;
    * `{:offline, at}`: a poll that succeeded and didn't list the channel.

  And three writes come out, which the database applies as upserts on
  `(channel_id, started_at)`:

    * `{:open, started_at}`;
    * `{:reopen, started_at}`: a stream we had closed from polling came back
      with the same `started_at` (Kick keeps it through a short
      disconnect);
    * `{:close, started_at, ended_at, :event | :poll}`.

  The rules, chosen so that **arrival order doesn't change the result**
  (§8.2):

    * Kick's end event is the truth about an end and always wins. A stream
      it closed never reopens (the API still lists a stream for a few
      seconds after it ends).
    * Without it, a stream ends at the **last moment it was seen live**,
      whenever that evidence arrives: later evidence moves the end later,
      never earlier. So the inferred end is the latest live evidence, in
      any order.
    * A newer `started_at` means the previous stream is over.
    * A poll must miss the channel for 90 seconds after its last live
      evidence before we call it offline: the API lags Kick's own state by
      up to ~20s, and a start event can arrive before the API lists the
      stream.
    * Evidence about a stream older than the newest one, never seen before,
      records it (closed at its last evidence) rather than dropping it.
  """

  @grace_s 90
  @keep 20

  defmodule Stream do
    @moduledoc false
    # `offline_seen_at`: when a poll last saw the channel offline after
    # this stream's evidence; live evidence after that reopens it.
    defstruct [:started_at, :ended_at, :end_source, :last_live_at, :offline_seen_at]
  end

  # `offline_at`: the latest poll that saw the channel offline, kept even
  # when no stream is open, so evidence arriving after it is judged by it.
  defstruct streams: %{}, offline_at: nil

  @type t :: %__MODULE__{streams: %{DateTime.t() => %Stream{}}, offline_at: DateTime.t() | nil}
  @type observation ::
          {:live, DateTime.t(), DateTime.t()}
          | {:ended, DateTime.t(), DateTime.t()}
          | {:offline, DateTime.t()}
  @type action ::
          {:open, DateTime.t()}
          | {:reopen, DateTime.t()}
          | {:close, DateTime.t(), DateTime.t(), :event | :poll}

  @doc """
  A state from the streams already in the database, as maps with
  `started_at`, `ended_at`, `end_source` (`"event"`, `"poll"` or nil) and
  `last_live_at` (the latest viewer sample, or nil).
  """
  @spec new([map()]) :: t()
  def new(rows \\ []) do
    streams =
      Map.new(rows, fn row ->
        source = row.end_source && String.to_existing_atom(to_string(row.end_source))

        started_at = norm(row.started_at)
        ended_at = row.ended_at && norm(row.ended_at)

        {started_at,
         %Stream{
           started_at: started_at,
           ended_at: ended_at,
           end_source: source,
           last_live_at: max_time(row[:last_live_at] && norm(row[:last_live_at]), started_at),
           offline_seen_at: if(source == :poll, do: ended_at)
         }}
      end)

    trim(%__MODULE__{streams: streams})
  end

  @doc "Applies one observation. Returns the new state and the writes, in order."
  @spec apply(t(), observation()) :: {t(), [action()]}
  def apply(%__MODULE__{} = state, {:live, started_at, at}) do
    started_at = norm(started_at)
    at = max_time(norm(at), started_at)

    {state, actions} =
      case Map.get(state.streams, started_at) do
        nil ->
          live_unknown(state, started_at, at)

        %Stream{end_source: :event} ->
          {state, []}

        %Stream{ended_at: nil} = s ->
          {put(state, %{s | last_live_at: max_time(s.last_live_at, at)}), []}

        %Stream{end_source: :poll} = s ->
          live_poll_closed(state, s, at)
      end

    {state, more} = check_offline(state)
    {state, actions ++ more}
  end

  def apply(%__MODULE__{} = state, {:ended, started_at, ended_at}) do
    started_at = norm(started_at)
    ended_at = max_time(norm(ended_at), started_at)
    known = Map.get(state.streams, started_at)

    if known && known.end_source == :event && known.ended_at == ended_at do
      {state, []}
    else
      {state, before} =
        if known, do: {state, []}, else: close_previous_open(state, started_at)

      base = known || %Stream{started_at: started_at, last_live_at: started_at}
      stream = %{base | ended_at: ended_at, end_source: :event}

      {put(state, stream), before ++ [{:close, started_at, ended_at, :event}]}
    end
  end

  def apply(%__MODULE__{} = state, {:offline, at}) do
    at = norm(at)
    state = %{state | offline_at: max_time(state.offline_at, at)}

    case newest(state) do
      %Stream{end_source: :poll} = s ->
        if DateTime.after?(at, s.ended_at),
          do: {put(state, %{s | offline_seen_at: max_time(s.offline_seen_at, at)}), []},
          else: {state, []}

      _ ->
        check_offline(state)
    end
  end

  # The newest stream is open, but a poll saw the channel offline long
  # enough after its last evidence: it ended at that evidence.
  defp check_offline(%{offline_at: nil} = state), do: {state, []}

  defp check_offline(state) do
    case newest(state) do
      %Stream{ended_at: nil} = s ->
        if DateTime.after?(state.offline_at, s.started_at) and
             DateTime.diff(state.offline_at, s.last_live_at) >= @grace_s do
          closed = %{
            s
            | ended_at: s.last_live_at,
              end_source: :poll,
              offline_seen_at: state.offline_at
          }

          {put(state, closed), [{:close, s.started_at, s.last_live_at, :poll}]}
        else
          {state, []}
        end

      _ ->
        {state, []}
    end
  end

  @doc "Applies observations in turn, collecting every write."
  @spec apply_all(t(), [observation()]) :: {t(), [action()]}
  def apply_all(state, observations) do
    Enum.reduce(observations, {state, []}, fn obs, {state, acc} ->
      {state, actions} = __MODULE__.apply(state, obs)
      {state, acc ++ actions}
    end)
  end

  @doc "The stream that is live now, if any: the newest one, still open."
  @spec open_stream(t()) :: DateTime.t() | nil
  def open_stream(state) do
    case newest(state) do
      %Stream{ended_at: nil, started_at: s} -> s
      _ -> nil
    end
  end

  @doc """
  Whether a viewer reading taken at `at` belongs to the stream that
  started at `started_at`: the stream is known and was not over by then.
  """
  @spec sample?(t(), DateTime.t(), DateTime.t()) :: boolean()
  def sample?(state, started_at, at) do
    case Map.get(state.streams, norm(started_at)) do
      nil -> false
      %Stream{ended_at: nil} -> true
      %Stream{ended_at: ended_at} -> DateTime.compare(at, ended_at) != :gt
    end
  end

  @doc "The known streams as `{started_at, ended_at, end_source}`, oldest first."
  @spec streams(t()) :: [{DateTime.t(), DateTime.t() | nil, :event | :poll | nil}]
  def streams(state) do
    state.streams
    |> Map.values()
    |> Enum.sort_by(& &1.started_at, DateTime)
    |> Enum.map(&{&1.started_at, &1.ended_at, &1.end_source})
  end

  # A started_at we haven't seen: the newest stream so far, or an older one
  # we missed.
  defp live_unknown(state, started_at, at) do
    case newest(state) do
      %Stream{started_at: newest_start} when newest_start != nil ->
        if DateTime.after?(started_at, newest_start),
          do: open_new(state, started_at, at),
          else: record_old(state, started_at, at)

      nil ->
        open_new(state, started_at, at)
    end
  end

  defp open_new(state, started_at, at) do
    {state, before} = close_previous_open(state, started_at)
    stream = %Stream{started_at: started_at, last_live_at: at}
    {put(state, stream), before ++ [{:open, started_at}]}
  end

  # An older stream we never saw: it is over (a newer one exists), and all
  # we know of its end is this evidence.
  defp record_old(state, started_at, at) do
    at = clamp_to_next(state, started_at, at)

    stream = %Stream{
      started_at: started_at,
      ended_at: at,
      end_source: :poll,
      last_live_at: at,
      offline_seen_at: at
    }

    {put(state, stream), [{:close, started_at, at, :poll}]}
  end

  defp live_poll_closed(state, s, at) do
    newest? = newest(state).started_at == s.started_at

    cond do
      # Seen offline, now live again with the same start: Kick kept the
      # stream through a short disconnect.
      newest? and s.offline_seen_at != nil and DateTime.after?(at, s.offline_seen_at) ->
        reopened = %{s | ended_at: nil, end_source: nil, last_live_at: at, offline_seen_at: nil}
        {put(state, reopened), [{:reopen, s.started_at}]}

      # Late evidence from before we saw it offline: the end moves later.
      DateTime.after?(at, s.ended_at) ->
        at = clamp_to_next(state, s.started_at, at)

        if DateTime.after?(at, s.ended_at) do
          {put(state, %{s | ended_at: at, last_live_at: at}), [{:close, s.started_at, at, :poll}]}
        else
          {state, []}
        end

      true ->
        {state, []}
    end
  end

  # A stream that started at `started_at` means any older open stream is
  # over, at its last evidence (never after the new start).
  defp close_previous_open(state, started_at) do
    case newest(state) do
      %Stream{ended_at: nil} = s ->
        if DateTime.before?(s.started_at, started_at) do
          ended_at = min_time(s.last_live_at, started_at)
          closed = %{s | ended_at: ended_at, end_source: :poll}
          {put(state, closed), [{:close, s.started_at, ended_at, :poll}]}
        else
          {state, []}
        end

      _ ->
        {state, []}
    end
  end

  defp clamp_to_next(state, started_at, at) do
    next =
      state.streams
      |> Map.keys()
      |> Enum.filter(&DateTime.after?(&1, started_at))
      |> Enum.min(DateTime, fn -> nil end)

    if next, do: min_time(at, next), else: at
  end

  defp newest(state) do
    case map_size(state.streams) do
      0 -> nil
      _ -> state.streams |> Map.values() |> Enum.max_by(& &1.started_at, DateTime)
    end
  end

  defp put(state, %Stream{} = s),
    do: trim(%{state | streams: Map.put(state.streams, s.started_at, s)})

  # Only the most recent streams are kept in memory; older ones are in the
  # database, and the upserts there keep the same rules.
  defp trim(%{streams: streams} = state) when map_size(streams) <= @keep, do: state

  defp trim(state) do
    keep = state.streams |> Map.keys() |> Enum.sort(DateTime) |> Enum.take(-@keep)
    %{state | streams: Map.take(state.streams, keep)}
  end

  @doc "A time in the one form used as a key: UTC, microsecond precision."
  @spec norm(DateTime.t()) :: DateTime.t()
  def norm(%DateTime{microsecond: {us, _}} = at),
    do: %{DateTime.shift_zone!(at, "Etc/UTC") | microsecond: {us, 6}}

  defp max_time(nil, b), do: b
  defp max_time(a, b), do: if(DateTime.after?(a, b), do: a, else: b)

  defp min_time(a, b), do: if(DateTime.before?(a, b), do: a, else: b)
end
