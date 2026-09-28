defmodule KickTracker.ApiKeys do
  @moduledoc """
  Keys to the public read API, `/api/v1` (project.md §13.10). An admin
  issues each one by hand, choosing what it reaches (`Access`); the key is
  shown once and stored as its SHA-256, like an invitation. Admin table,
  written by the web role.

  A key is looked up at most every 30 seconds per web node (the ETS
  cache), so a revoked or edited key takes effect within 30 seconds.
  """

  import Ecto.Query

  alias KickTracker.{Cache, Channels, Groups, Reports, Repo}
  alias KickTracker.ApiKeys.{Access, ApiKey}
  alias KickTracker.Channels.Channel

  @prefix "kt_"
  @lookup_ttl_s 30
  @touch_every_s 300

  @doc "Every key, newest first, revoked ones included."
  @spec list() :: [ApiKey.t()]
  def list, do: Repo.all(from k in ApiKey, order_by: [desc: k.inserted_at, desc: k.id])

  @spec get!(integer()) :: ApiKey.t()
  def get!(id), do: Repo.get!(ApiKey, id)

  @doc "A changeset for the admin's form."
  def change(key \\ %ApiKey{}, attrs \\ %{}), do: ApiKey.changeset(key, attrs)

  @doc "Issues a key. Returns it with the key itself, which is never shown again."
  @spec create(map() | nil, map()) :: {:ok, ApiKey.t(), String.t()} | {:error, Ecto.Changeset.t()}
  def create(admin, attrs) do
    raw = @prefix <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    %ApiKey{
      token_hash: hash(raw),
      prefix: String.slice(raw, 0, 10),
      created_by_id: admin && admin.id
    }
    |> ApiKey.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, key} -> {:ok, key, raw}
      error -> error
    end
  end

  @doc "Changes what a key reaches or its limits; the key itself stays."
  @spec update(ApiKey.t(), map()) :: {:ok, ApiKey.t()} | {:error, Ecto.Changeset.t()}
  def update(%ApiKey{} = key, attrs) do
    result = key |> ApiKey.changeset(attrs) |> Repo.update()
    Cache.clear()
    result
  end

  @doc "Revokes a key for good."
  @spec revoke(ApiKey.t()) :: {:ok, ApiKey.t()}
  def revoke(%ApiKey{} = key) do
    result = key |> Ecto.Changeset.change(revoked_at: DateTime.utc_now()) |> Repo.update()
    Cache.clear()
    result
  end

  @doc """
  The key a request presents, if it is one of ours, not revoked or
  expired, and accepted from the request's address.
  """
  @spec authenticate(String.t(), :inet.ip_address(), DateTime.t()) :: {:ok, ApiKey.t()} | :error
  def authenticate(raw, ip, now \\ DateTime.utc_now()) do
    hash = hash(raw)

    key =
      Cache.fetch({__MODULE__, hash}, @lookup_ttl_s, fn ->
        Repo.one(from k in ApiKey, where: k.token_hash == ^hash)
      end)

    if key && usable?(key, now) && Access.address_allowed?(key, ip),
      do: {:ok, key},
      else: :error
  end

  @doc "Whether a key is neither revoked nor expired."
  @spec usable?(ApiKey.t(), DateTime.t()) :: boolean()
  def usable?(key, now \\ DateTime.utc_now()),
    do:
      is_nil(key.revoked_at) and
        (is_nil(key.expires_at) or DateTime.compare(key.expires_at, now) == :gt)

  @doc "Records that a key was used, at most every few minutes."
  @spec touch(ApiKey.t(), DateTime.t()) :: :ok
  def touch(%ApiKey{id: id}, now \\ DateTime.utc_now()) do
    stale = DateTime.add(now, -@touch_every_s)

    Repo.update_all(
      from(k in ApiKey,
        where: k.id == ^id and (is_nil(k.last_used_at) or k.last_used_at < ^stale)
      ),
      set: [last_used_at: now]
    )

    :ok
  end

  @doc "A channel by slug (or an old slug) with how far the key reaches it, or `:error`."
  @spec channel(ApiKey.t(), String.t()) :: {:ok, Channel.t(), Access.access()} | :error
  def channel(key, slug) do
    with %Channel{} = channel <- Reports.channel_by_slug(slug, visibility: :any),
         access when access != :none <- access(key, channel) do
      {:ok, channel, access}
    else
      _ -> :error
    end
  end

  @doc "How far a key reaches a channel."
  @spec access(ApiKey.t(), Channel.t()) :: Access.access()
  def access(key, channel), do: Access.channel_access(key, channel, Groups.of_channel(channel.id))

  @doc "Every channel the key reaches, with how far, by slug."
  @spec channels(ApiKey.t()) :: [{Channel.t(), Access.access()}]
  def channels(key) do
    groups = Groups.by_channel()

    Channels.list_all()
    |> Enum.map(&{&1, Access.channel_access(key, &1, Map.get(groups, &1.id, []))})
    |> Enum.reject(fn {_, access} -> access == :none end)
    |> Enum.sort_by(fn {c, _} -> c.slug end)
  end

  defp hash(raw), do: :crypto.hash(:sha256, raw)
end
