defmodule KickTracker.Annotations do
  @moduledoc """
  Notes on a channel's timeline (project.md §13.8): "collector outage",
  "suspected viewbots", "charity stream". Written by admins; the public
  ones are drawn on charts.
  """

  import Ecto.Query
  alias KickTracker.Repo

  @doc "Public annotations touching a range: for a channel, and site-wide ones (no channel)."
  @spec public_for(integer(), DateTime.t(), DateTime.t()) :: [map()]
  def public_for(channel_id, from, to) do
    Repo.all(
      from a in "annotations",
        where: a.public and (a.channel_id == ^channel_id or is_nil(a.channel_id)),
        where: a.from_at < ^to and (is_nil(a.to_at) or a.to_at > ^from),
        order_by: a.from_at,
        select: %{
          from: fragment("extract(epoch FROM ?)::bigint", a.from_at),
          to: fragment("extract(epoch FROM ?)::bigint", a.to_at),
          text: a.text
        }
    )
  end

  @doc "Every annotation, newest first (admin)."
  @spec list(integer() | nil) :: [map()]
  def list(channel_id \\ nil) do
    query =
      from a in "annotations",
        left_join: c in "channels",
        on: c.id == a.channel_id,
        order_by: [desc: a.from_at],
        select: %{
          id: a.id,
          channel_id: a.channel_id,
          slug: c.slug,
          from_at: a.from_at,
          to_at: a.to_at,
          text: a.text,
          public: a.public
        }

    query = if channel_id, do: where(query, [a], a.channel_id == ^channel_id), else: query
    Repo.all(query)
  end

  @doc "Adds an annotation."
  @spec create(map(), integer() | nil) :: {:ok, integer()} | {:error, String.t()}
  def create(attrs, admin_id) do
    with {:ok, from} <- parse_time(attrs["from_at"]),
         {:ok, to} <- parse_optional_time(attrs["to_at"]),
         text when text != "" <- String.trim(attrs["text"] || "") do
      now = DateTime.utc_now()

      channel_id =
        case Integer.parse(to_string(attrs["channel_id"] || "")) do
          {id, ""} -> id
          _ -> nil
        end

      {1, [%{id: id}]} =
        Repo.insert_all(
          "annotations",
          [
            %{
              channel_id: channel_id,
              from_at: from,
              to_at: to,
              text: text,
              public: attrs["public"] in [true, "true", "on"],
              admin_id: admin_id,
              inserted_at: now,
              updated_at: now
            }
          ],
          returning: [:id]
        )

      {:ok, id}
    else
      "" -> {:error, "text is required"}
      {:error, msg} -> {:error, msg}
    end
  end

  @spec delete(integer()) :: :ok
  def delete(id) do
    Repo.delete_all(from a in "annotations", where: a.id == ^id)
    :ok
  end

  defp parse_optional_time(v) when v in [nil, ""], do: {:ok, nil}
  defp parse_optional_time(v), do: parse_time(v)

  # From a datetime-local input (UTC) or ISO 8601.
  defp parse_time(v) when is_binary(v) do
    v = if String.length(v) == 16, do: v <> ":00Z", else: v
    v = if String.ends_with?(v, "Z") or String.contains?(v, "+"), do: v, else: v <> "Z"

    case DateTime.from_iso8601(v) do
      {:ok, at, _} -> {:ok, at}
      _ -> {:error, "invalid time"}
    end
  end

  defp parse_time(_), do: {:error, "time is required"}
end
