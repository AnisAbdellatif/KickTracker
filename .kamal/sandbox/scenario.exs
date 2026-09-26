# The fake Kick for the sandbox (and the deploy rehearsal): three channels
# live the whole time, with chat, follows and support, so every kind of
# data flows. The seed hook tracks every slug here.
[
  seed: 11,
  channels: [
    [slug: "sandboxbig", peak_viewers: 5_000, schedule: :always],
    [slug: "sandboxmid", peak_viewers: 400, schedule: :always],
    [slug: "sandboxsmall", peak_viewers: 30, schedule: :always]
  ]
]
