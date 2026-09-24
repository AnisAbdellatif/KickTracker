# The fake Kick for the deploy rehearsal: three channels live the whole
# time, with chat, follows and support, so every kind of data flows while
# the stack is upgraded under it.
[
  seed: 11,
  channels: [
    [slug: "rehearsalbig", peak_viewers: 5_000, schedule: :always],
    [slug: "rehearsalmid", peak_viewers: 400, schedule: :always],
    [slug: "rehearsalsmall", peak_viewers: 30, schedule: :always]
  ]
]
