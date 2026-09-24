defmodule KickTracker.Alerts.Notifier do
  @moduledoc """
  Sends alerts where someone will see them (project.md §18.2):

    * `ALERT_WEBHOOK_URL`: a Discord or Slack incoming webhook (the body
      carries both `content` and `text`);
    * `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID`: a Telegram bot.

  With neither set, alerts are only logged and shown on the health page.
  """

  require Logger

  @doc "Sends a message to every configured target. Never raises."
  @spec send(String.t()) :: :ok
  def send(text) do
    config = Application.get_env(:kick_tracker, :alerts, [])
    text = "[#{KickTrackerWeb.Layouts.site_name()}] " <> text
    Logger.warning("alert: " <> text)

    if url = config[:webhook_url] do
      post(url, %{"content" => text, "text" => text})
    end

    with token when is_binary(token) <- config[:telegram_bot_token],
         chat when is_binary(chat) <- config[:telegram_chat_id] do
      post("https://api.telegram.org/bot#{token}/sendMessage", %{
        "chat_id" => chat,
        "text" => text
      })
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

  defp post(url, body) do
    case Req.post(url, json: body, retry: :transient, max_retries: 2, receive_timeout: 10_000) do
      {:ok, %{status: s}} when s in 200..299 -> :ok
      other -> Logger.error("could not send an alert: #{inspect(other, limit: 5)}")
    end
  rescue
    error -> Logger.error("could not send an alert: #{Exception.message(error)}")
  end
end
