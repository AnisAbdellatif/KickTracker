defmodule KickTracker.Alerts.Notifier do
  @moduledoc """
  Sends alerts where someone will see them (project.md §18.2):

    * `ALERT_WEBHOOK_URL`: a Discord or Slack incoming webhook (the body
      carries both `content` and `text`);
    * `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID`: a Telegram bot;
    * `NTFY_URL` (a topic's URL, `https://<ntfy host>/<topic>`) and,
      for a server that requires one, `NTFY_TOKEN`: ntfy, with the
      message's priority (the others have none).

  With none set, alerts are only logged and shown on the health page.
  """

  require Logger

  @typedoc "`:high` for a new problem, `:default` for a reminder, `:low` when it is over."
  @type priority :: :high | :default | :low

  @doc "Sends a message to every configured target. Never raises."
  @spec send(String.t(), priority()) :: :ok
  def send(text, priority \\ :default) when priority in [:high, :default, :low] do
    config = Application.get_env(:kick_tracker, :alerts, [])
    site = KickTrackerWeb.Layouts.site_name()
    prefixed = "[#{site}] " <> text
    Logger.warning("alert: " <> prefixed)

    if url = config[:webhook_url] do
      post(url, json: %{"content" => prefixed, "text" => prefixed})
    end

    with token when is_binary(token) <- config[:telegram_bot_token],
         chat when is_binary(chat) <- config[:telegram_chat_id] do
      post("https://api.telegram.org/bot#{token}/sendMessage",
        json: %{"chat_id" => chat, "text" => prefixed}
      )
    end

    if url = config[:ntfy_url] do
      # The site as the title, in the query rather than a header, which
      # would need encoding for anything but ASCII.
      post(url,
        body: text,
        params: [title: site, priority: priority],
        auth: if(token = config[:ntfy_token], do: {:bearer, token})
      )
    end

    :ok
  end

  @doc "Pings the heartbeat URL (a dead man's switch: its service alerts when the pings stop)."
  @spec heartbeat() :: :ok
  def heartbeat do
    if url = Application.get_env(:kick_tracker, :alerts, [])[:heartbeat_url] do
      case Req.get(url, retry: false, receive_timeout: 10_000) do
        {:ok, %{status: s}} when s in 200..299 -> :ok
        other -> Logger.warning("heartbeat failed: #{inspect(other)}")
      end
    end

    :ok
  end

  defp post(url, options) do
    case Req.post(url, [retry: :transient, max_retries: 2, receive_timeout: 10_000] ++ options) do
      {:ok, %{status: s}} when s in 200..299 -> :ok
      other -> Logger.error("could not send an alert: #{inspect(other, limit: 5)}")
    end
  rescue
    error -> Logger.error("could not send an alert: #{Exception.message(error)}")
  end
end
