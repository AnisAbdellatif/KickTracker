defmodule KickTracker.ErrorLogger do
  @moduledoc """
  Sends crashes of any process (a channel's process, the poller, a chat
  socket) to ErrorTracker, which on its own only sees Phoenix requests,
  LiveViews and Oban jobs. An Erlang `:logger` handler: it looks at error
  events carrying a `crash_reason` and reports them from a separate task,
  so a failing report never loops back into the logger or delays anything.
  """

  @handler :kick_tracker_errors

  @doc "Installs the handler (at boot)."
  def install do
    case :logger.add_handler(@handler, __MODULE__, %{level: :error}) do
      :ok -> :ok
      {:error, {:already_exist, _}} -> :ok
      error -> error
    end
  end

  @doc false
  def log(%{level: level} = event, _config)
      when level in [:error, :critical, :alert, :emergency] do
    with nil <- Process.get(:kick_tracker_error_logger),
         {reason, stacktrace} when is_list(stacktrace) <- crash(event) do
      exception = Exception.normalize(:error, reason, stacktrace)
      meta = event[:meta] || %{}

      context = %{
        "process" => inspect(meta[:pid]),
        "registered_name" => inspect(meta[:registered_name])
      }

      Task.start(fn ->
        Process.put(:kick_tracker_error_logger, true)
        ErrorTracker.report(exception, stacktrace, context)
      end)
    end

    :ok
  rescue
    _ -> :ok
  end

  def log(_event, _config), do: :ok

  @doc """
  The `{reason, stacktrace}` of a crash report, from the shapes OTP and
  Elixir log them in, or nil. Pure.
  """
  def crash(%{meta: %{crash_reason: {reason, stack}}}), do: {reason, stack}

  # A GenServer (or :gen_statem, gen_event) that terminated.
  def crash(%{msg: {:report, %{label: {_behaviour, :terminate}, reason: {reason, stack}}}})
      when is_list(stack),
      do: {reason, stack}

  # A process started with proc_lib (spawn_link'd tasks, supervisors' children) that crashed.
  def crash(%{msg: {:report, %{label: {:proc_lib, :crash}, report: [info | _]}}})
      when is_list(info) do
    case Keyword.get(info, :error_info) do
      {_class, reason, stack} when is_list(stack) -> {reason, stack}
      _ -> nil
    end
  end

  # A Task that raised.
  def crash(%{
        msg:
          {:report, %{label: {Task.Supervisor, :terminating}, report: %{reason: {reason, stack}}}}
      })
      when is_list(stack),
      do: {reason, stack}

  def crash(_event), do: nil
end
