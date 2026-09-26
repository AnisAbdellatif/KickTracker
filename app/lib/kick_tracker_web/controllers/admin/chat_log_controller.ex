defmodule KickTrackerWeb.Admin.ChatLogController do
  @moduledoc """
  The chat log as CSV (project.md §12.8), for the filters in the query
  string (see `ChatLogFilters`): channels or users, over a period, oldest
  first, streamed so a large selection isn't held in memory. Audited.
  """

  use KickTrackerWeb, :controller

  alias KickTracker.{ChatLog, Repo}
  alias KickTrackerWeb.Admin.{ChatLogFilters, ChatLogLive}

  @columns ~w(sent_at channel user_id username type message_id reply_to_message_id reply_to_user_id content)

  def export(conn, params) do
    {filters, _form} = ChatLogFilters.parse(params)
    ChatLogLive.audit_view(conn.assigns.current_admin, "chat_log.export", filters)
    name = "chat-log-#{Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M")}.csv"

    conn =
      conn
      |> put_resp_content_type("text/csv")
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{name}"))
      |> send_chunked(200)

    {:ok, conn} =
      Repo.transaction(
        fn ->
          {:ok, conn} = chunk(conn, line(@columns))

          filters
          |> ChatLog.stream_messages()
          |> Stream.chunk_every(500)
          |> Enum.reduce_while(conn, fn batch, conn ->
            case chunk(conn, Enum.map(batch, &row/1)) do
              {:ok, conn} -> {:cont, conn}
              {:error, _closed} -> {:halt, conn}
            end
          end)
          |> then(&{:ok, &1})
        end,
        timeout: :infinity
      )
      |> elem(1)

    conn
  end

  defp row(m) do
    line([
      DateTime.to_iso8601(m.sent_at),
      m.slug,
      m.user_id,
      m.username,
      m.type,
      m.message_id,
      m.reply_to_message_id,
      m.reply_to_user_id,
      m.content
    ])
  end

  @doc false
  # One CSV line (RFC 4180). A text field a spreadsheet would read as a
  # formula (=, +, -, @, tab, carriage return at the start) gets a leading
  # apostrophe: chat text is written by anyone.
  def line(fields), do: [Enum.map_join(fields, ",", &field/1), "\r\n"]

  defp field(nil), do: ""
  defp field(n) when is_integer(n), do: Integer.to_string(n)

  defp field(text) when is_binary(text) do
    text = if String.match?(text, ~r/\A[=+\-@\t\r]/), do: "'" <> text, else: text

    if String.contains?(text, [",", "\"", "\n", "\r"]),
      do: ~s(") <> String.replace(text, ~s("), ~s("")) <> ~s("),
      else: text
  end
end
