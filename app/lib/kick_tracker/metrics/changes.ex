defmodule KickTracker.Metrics.Changes do
  @moduledoc """
  Title, category, language and mature-flag changes during one stream
  (project.md §12.4). Pure.

  Two sources report the same four fields:

    * `livestream.metadata.updated`, a full snapshot sent on every change;
      which field changed is found by comparing with the previous one.
      Its time is the delivery's timestamp.
    * The 60s poll, which fills in changes whose events were missed. It
      lags Kick: right after an event it may still show the old value. So
      a poll only counts a difference that it sees **twice in a row**, and
      not within two minutes of an event; the change is dated at the first
      sighting.

  A snapshot older than the latest one applied is ignored (events can
  arrive out of order; the newer one already describes the stream). The
  first values seen for a stream are recorded with no old value: what the
  stream started with.
  """

  @fields ~w(title category language mature)
  @event_quiet_s 120

  defstruct values: nil, as_of: nil, last_event_at: nil, pending: %{}

  @type field :: String.t()
  @type snapshot :: %{optional(field) => String.t() | nil}
  @type change :: %{
          field: field(),
          old_value: String.t() | nil,
          new_value: String.t() | nil,
          occurred_at: DateTime.t(),
          source: :event | :poll
        }
  @type t :: %__MODULE__{}

  @doc "The fields tracked."
  def fields, do: @fields

  @doc "A tracker for a new stream, optionally knowing its current values (on restart)."
  @spec new(snapshot() | nil, DateTime.t() | nil) :: t()
  def new(values \\ nil, as_of \\ nil), do: %__MODULE__{values: values, as_of: as_of}

  @doc "Applies a metadata event's snapshot."
  @spec event(t(), snapshot(), DateTime.t()) :: {t(), [change()]}
  def event(%__MODULE__{} = state, snapshot, at) do
    if stale?(state, at) do
      {state, []}
    else
      changes = diff(state.values, snapshot, at, :event)
      values = Map.merge(state.values || %{}, snapshot)
      {%{state | values: values, as_of: at, last_event_at: at, pending: %{}}, changes}
    end
  end

  @doc "Applies what a poll reading showed."
  @spec poll(t(), snapshot(), DateTime.t()) :: {t(), [change()]}
  def poll(%__MODULE__{values: nil} = state, snapshot, at) do
    {%{state | values: snapshot, as_of: at}, diff(nil, snapshot, at, :poll)}
  end

  def poll(%__MODULE__{} = state, snapshot, at) do
    if stale?(state, at) or quiet?(state, at) do
      {state, []}
    else
      Enum.reduce(@fields, {state, []}, fn field, {state, changes} ->
        poll_field(state, changes, field, Map.fetch(snapshot, field), at)
      end)
      |> then(fn {state, changes} -> {%{state | as_of: at}, Enum.reverse(changes)} end)
    end
  end

  defp poll_field(state, changes, _field, :error, _at), do: {state, changes}

  defp poll_field(state, changes, field, {:ok, value}, at) do
    current = Map.get(state.values, field)

    case Map.get(state.pending, field) do
      _ when value == current ->
        {%{state | pending: Map.delete(state.pending, field)}, changes}

      {^value, first_seen} ->
        change = %{
          field: field,
          old_value: current,
          new_value: value,
          occurred_at: first_seen,
          source: :poll
        }

        state = %{
          state
          | values: Map.put(state.values, field, value),
            pending: Map.delete(state.pending, field)
        }

        {state, [change | changes]}

      _ ->
        {%{state | pending: Map.put(state.pending, field, {value, at})}, changes}
    end
  end

  defp diff(old, snapshot, at, source) do
    # A stream's first values record only what is known; after that, any
    # difference counts, including a value going away.
    for field <- @fields,
        Map.has_key?(snapshot, field),
        changed?(old, field, Map.get(snapshot, field)) do
      %{
        field: field,
        old_value: old && Map.get(old, field),
        new_value: Map.get(snapshot, field),
        occurred_at: at,
        source: source
      }
    end
  end

  defp changed?(nil, _field, new), do: new != nil
  defp changed?(old, field, new), do: Map.get(old, field) != new

  defp stale?(%{as_of: nil}, _at), do: false
  defp stale?(%{as_of: as_of}, at), do: DateTime.before?(at, as_of)

  defp quiet?(%{last_event_at: nil}, _at), do: false
  defp quiet?(%{last_event_at: t}, at), do: DateTime.diff(at, t) < @event_quiet_s

  @doc """
  A snapshot from a `livestream.metadata.updated` body. The category comes
  twice (`category` and `Category`); the lowercase one is read.
  """
  @spec from_event(map()) :: {snapshot(), map() | nil}
  def from_event(%{"metadata" => m}) when is_map(m) do
    snapshot(m["title"], m["category"], m["language"], m["has_mature_content"])
  end

  def from_event(_), do: {%{}, nil}

  @doc "A snapshot from one `/livestreams` entry."
  @spec from_livestream(map()) :: {snapshot(), map() | nil}
  def from_livestream(l) do
    snapshot(l["stream_title"], l["category"], l["language"], l["has_mature_content"])
  end

  # Returns the snapshot and the category seen, if any, so it can be
  # recorded in `categories`.
  defp snapshot(title, category, language, mature) do
    {category_id, category} =
      case category do
        %{"id" => id, "name" => name} when is_integer(id) ->
          {Integer.to_string(id), %{id: id, name: name}}

        _ ->
          {nil, nil}
      end

    values = %{
      "title" => title,
      "category" => category_id,
      "language" => language,
      "mature" => if(is_boolean(mature), do: to_string(mature))
    }

    {values, category}
  end
end
