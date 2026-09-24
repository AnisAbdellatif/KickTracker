defmodule KickTracker.Groups do
  @moduledoc """
  Channel groups (project.md §13.8), e.g. "Tunisian streamers": lists of
  channels used for public leaderboards and the compare page. Admin
  tables; a group is shown publicly only when marked public.
  """

  import Ecto.Query
  alias KickTracker.Repo

  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    query =
      from g in "channel_groups",
        order_by: g.name,
        select: %{id: g.id, name: g.name, slug: g.slug, public: g.public}

    query = if opts[:public], do: where(query, [g], g.public), else: query
    groups = Repo.all(query)
    members = members_by_group(Enum.map(groups, & &1.id))
    Enum.map(groups, &Map.put(&1, :channel_ids, Map.get(members, &1.id, [])))
  end

  @spec get_by_slug(String.t()) :: map() | nil
  def get_by_slug(slug), do: Enum.find(list(), &(&1.slug == slug))

  defp members_by_group(ids) do
    Repo.all(
      from m in "channel_group_members",
        where: m.group_id in ^ids,
        select: {m.group_id, m.channel_id}
    )
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  @doc "Creates a group; the slug comes from the name."
  @spec create(String.t(), boolean()) :: {:ok, integer()} | {:error, String.t()}
  def create(name, public?) do
    name = String.trim(name)
    slug = KickTracker.Reports.slugify(name)

    cond do
      slug == "" ->
        {:error, "a name is required"}

      Repo.exists?(from g in "channel_groups", where: g.slug == ^slug) ->
        {:error, "a group with that name exists"}

      true ->
        now = DateTime.utc_now()

        {1, [%{id: id}]} =
          Repo.insert_all(
            "channel_groups",
            [%{name: name, slug: slug, public: public?, inserted_at: now, updated_at: now}],
            returning: [:id]
          )

        {:ok, id}
    end
  end

  @spec set_public(integer(), boolean()) :: :ok
  def set_public(id, public?) do
    Repo.update_all(from(g in "channel_groups", where: g.id == ^id),
      set: [public: public?, updated_at: DateTime.utc_now()]
    )

    :ok
  end

  @spec delete(integer()) :: :ok
  def delete(id) do
    Repo.delete_all(from g in "channel_groups", where: g.id == ^id)
    :ok
  end

  @doc "Sets a group's members to exactly these channels."
  @spec set_members(integer(), [integer()]) :: :ok
  def set_members(id, channel_ids) do
    Repo.transaction(fn ->
      Repo.delete_all(from m in "channel_group_members", where: m.group_id == ^id)

      Repo.insert_all(
        "channel_group_members",
        Enum.map(Enum.uniq(channel_ids), &%{group_id: id, channel_id: &1})
      )
    end)

    :ok
  end
end
