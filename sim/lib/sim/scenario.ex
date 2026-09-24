defmodule Sim.Scenario do
  @moduledoc """
  What the fake Kick should pretend to be: which channels exist, how big
  they are, when they stream, how busy their chat is, and which faults to
  inject. Pure: building and validating only.

  Ids are derived from the slug, so a scenario names channels and nothing
  else, and the same slug always gets the same ids across runs.
  """

  alias Sim.Scenario.Channel

  defstruct channels: [], seed: 1, faults: %{}

  @type t :: %__MODULE__{channels: [Channel.t()], seed: integer(), faults: map()}

  @doc """
  Builds a scenario from plain data (keyword lists or maps), filling in
  defaults. Raises on anything it doesn't understand, so a typo in a
  scenario file fails at load rather than silently doing nothing.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    seed = Keyword.get(opts, :seed, 1)

    channels =
      opts
      |> Keyword.get(:channels, [])
      |> Enum.with_index()
      |> Enum.map(fn {spec, index} -> Channel.new(spec, seed + index) end)

    case Enum.frequencies_by(channels, & &1.slug) |> Enum.filter(fn {_slug, n} -> n > 1 end) do
      [] -> :ok
      [{slug, _} | _] -> raise ArgumentError, "duplicate channel slug in scenario: #{slug}"
    end

    %__MODULE__{channels: channels, seed: seed, faults: Map.new(Keyword.get(opts, :faults, []))}
  end

  @doc "The channel with this slug, or nil."
  @spec channel(t(), String.t()) :: Channel.t() | nil
  def channel(%__MODULE__{channels: channels}, slug) do
    Enum.find(channels, &(String.downcase(&1.slug) == String.downcase(slug)))
  end

  @doc "The channel with this broadcaster user id, or nil."
  @spec channel_by_user_id(t(), integer()) :: Channel.t() | nil
  def channel_by_user_id(%__MODULE__{channels: channels}, user_id) do
    Enum.find(channels, &(&1.user_id == user_id))
  end

  @doc "Whether a fault is switched on for this scenario."
  @spec fault(t(), atom(), term()) :: term()
  def fault(%__MODULE__{faults: faults}, name, default \\ false),
    do: Map.get(faults, name, default)
end
