# Dialyzer findings checked and judged false (project.md §19.1). Each entry
# says why; remove it when the cause goes away.
[
  # Dialyzer infers the upgrade accumulator's status too narrowly and
  # concludes Mint.WebSocket.new/4 can only fail; the chat socket's tests
  # (pipeline_sim_test, against the fake Pusher) take the success path.
  {"lib/kick_tracker/tracking/chat_socket.ex", :pattern_match}
]
