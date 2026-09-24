defmodule KickTracker.Role do
  @moduledoc """
  Which parts of the app this node runs (project.md §10).

    * `collector` — polling, channel processes, the queue consumer: it owns
      every write of collected data;
    * `web` — the public site, the admin interface and `/data`.

  Each role is its own service in production, deployed on its own, so a
  site change never restarts collection. Development and tests run both.
  The value comes from `ROLE` (see `config/runtime.exs`).
  """

  @type t :: :collector | :web

  @roles %{"collector" => :collector, "web" => :web}

  @doc """
  Parses `collector`, `web`, or both separated by a comma.

      iex> KickTracker.Role.parse("collector,web")
      {:ok, [:collector, :web]}

      iex> KickTracker.Role.parse(" web ")
      {:ok, [:web]}

      iex> KickTracker.Role.parse("worker")
      {:error, "unknown role \\"worker\\": use collector, web, or collector,web"}
  """
  @spec parse(String.t()) :: {:ok, [t()]} | {:error, String.t()}
  def parse(value) when is_binary(value) do
    names =
      value
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    case Enum.find(names, &(not Map.has_key?(@roles, &1))) do
      nil when names != [] ->
        {:ok, names |> Enum.map(&@roles[&1]) |> Enum.uniq() |> Enum.sort()}

      nil ->
        {:error, "ROLE is empty: use collector, web, or collector,web"}

      unknown ->
        {:error, "unknown role #{inspect(unknown)}: use collector, web, or collector,web"}
    end
  end

  @doc "The roles this node was started with. Raises on a bad value, so a typo stops the node at boot."
  @spec current() :: [t()]
  def current do
    value = Application.get_env(:kick_tracker, :role, "collector,web")

    case parse(value) do
      {:ok, roles} -> roles
      {:error, message} -> raise ArgumentError, message
    end
  end

  @doc "Whether this node runs a role."
  @spec runs?(t()) :: boolean()
  def runs?(role), do: role in current()
end
