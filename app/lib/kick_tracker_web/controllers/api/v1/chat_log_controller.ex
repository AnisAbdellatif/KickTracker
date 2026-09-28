defmodule KickTrackerWeb.Api.V1.ChatLogController do
  @moduledoc """
  A channel's logged chat (project.md §12.8), for admin keys only
  (§13.10): messages as sent, and the chat feed's other events, newest
  first, a page at a time. Only what chat logging kept, for the channel's
  retention; privacy deletions apply here as everywhere.
  """

  use KickTrackerWeb, :controller

  alias KickTracker.{ApiKeys, ChatLog}
  alias KickTracker.ApiKeys.Access
  alias KickTrackerWeb.Api.V1.JSON
  alias KickTrackerWeb.Period

  def messages(conn, params) do
    with_range(conn, params, fn c, filters ->
      rows = ChatLog.messages(Map.put(filters, :before, cursor(params["before"])))

      next =
        if length(rows) == filters.limit,
          do: rows |> List.last() |> then(&encode_cursor(&1.sent_at, &1.message_id))

      %{
        messages:
          Enum.map(rows, fn m ->
            %{
              sent_at: JSON.time(m.sent_at),
              message_id: m.message_id,
              user_id: m.user_id,
              username: m.username,
              type: m.type,
              content: m.content,
              reply_to:
                m.reply_to_message_id &&
                  %{
                    message_id: m.reply_to_message_id,
                    user_id: m.reply_to_user_id,
                    username: m.reply_to_username,
                    content: m.reply_to_content
                  }
            }
          end),
        next: next,
        channel: c.slug
      }
    end)
  end

  def events(conn, params) do
    with_range(conn, params, fn c, filters ->
      rows = ChatLog.events(Map.put(filters, :before, cursor(params["before"])))

      next =
        if length(rows) == filters.limit,
          do: rows |> List.last() |> then(&encode_cursor(&1.occurred_at, &1.id))

      %{
        events:
          Enum.map(rows, fn e ->
            %{occurred_at: JSON.time(e.occurred_at), event: e.event, payload: e.payload}
          end),
        next: next,
        channel: c.slug
      }
    end)
  end

  # The last 24 hours unless `period` or `from`/`to` say otherwise, as far
  # back as the key reads.
  defp with_range(conn, %{"slug" => slug} = params, fun) do
    key = conn.assigns.api_key

    with {:ok, c, access} <- ApiKeys.channel(key, slug),
         {:scope, true} <- {:scope, Access.can?(key, access, "chat_log")} do
      period = Period.parse(params, default: "24h", since: c.tracked_since)
      {from, to, clamped} = Access.clamp(key, period.from, period.to, DateTime.utc_now())
      filters = %{channel_ids: [c.id], from: from, to: to, limit: limit(params["limit"])}

      data =
        fun.(c, filters)
        |> Map.merge(%{from: DateTime.to_unix(from), to: DateTime.to_unix(to), clamped: clamped})

      JSON.send(conn, data, to)
    else
      :error -> JSON.not_found(conn)
      {:scope, false} -> JSON.out_of_scope(conn, "chat_log")
    end
  end

  defp limit(param) do
    case Integer.parse(param || "") do
      {n, ""} when n in 1..1000 -> n
      _ -> 200
    end
  end

  # A page's cursor: the last row's time (microseconds) and id, opaque to
  # the client.
  defp encode_cursor(%DateTime{} = at, id),
    do: Base.url_encode64(Jason.encode!([DateTime.to_unix(at, :microsecond), id]), padding: false)

  defp cursor(nil), do: nil

  defp cursor(param) do
    with {:ok, json} <- Base.url_decode64(param, padding: false),
         {:ok, [us, id]} when is_integer(us) and (is_binary(id) or is_integer(id)) <-
           Jason.decode(json),
         {:ok, at} <- DateTime.from_unix(us, :microsecond) do
      {at, id}
    else
      _ -> nil
    end
  end
end
