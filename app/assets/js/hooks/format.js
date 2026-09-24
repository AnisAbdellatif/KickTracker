// Numbers and times in the visitor's locale and timezone (project.md §13.6):
//
//   <span data-num="1086">1086</span>              exact, grouped
//   <span data-num="26400" data-compact>…</span>   26K, exact on hover
//   <time datetime="2026-…Z" data-fmt="datetime">  visitor's timezone
//
// With "channel time" chosen (the switch in the channel header), times
// carrying data-tz show in the channel's timezone instead.

const exact = new Intl.NumberFormat()
const compact = new Intl.NumberFormat(undefined, {notation: "compact", maximumFractionDigits: 1})

function tzMode() {
  try { return localStorage.getItem("tz-mode") || "local" } catch (_e) { return "local" }
}

export function formatAll(root) {
  root.querySelectorAll("[data-num]").forEach((el) => {
    const v = Number(el.dataset.num)
    if (el.dataset.num === "" || Number.isNaN(v)) return
    if (el.hasAttribute("data-compact") && Math.abs(v) >= 10000) {
      el.textContent = compact.format(v)
      el.title = exact.format(v)
    } else {
      el.textContent = exact.format(Math.abs(v) >= 10 ? Math.round(v) : Math.round(v * 10) / 10)
    }
  })
  const mode = tzMode()
  root.querySelectorAll("time[data-fmt]").forEach((el) => {
    const d = new Date(el.getAttribute("datetime"))
    if (Number.isNaN(d.getTime())) return
    const timeZone = mode === "channel" && el.dataset.tz ? el.dataset.tz : undefined
    const opts = {
      datetime: {dateStyle: "medium", timeStyle: "short"},
      date: {dateStyle: "medium"},
      time: {timeStyle: "short"},
      short: {month: "short", day: "numeric", hour: "numeric", minute: "2-digit"},
    }[el.dataset.fmt] || {dateStyle: "medium", timeStyle: "short"}
    el.textContent = new Intl.DateTimeFormat(undefined, {...opts, timeZone}).format(d)
    el.title = d.toISOString()
  })
}

export const Format = {
  mounted() { formatAll(this.el) },
  updated() { formatAll(this.el) },
}

export const TzSwitch = {
  mounted() {
    const sync = () => { this.el.setAttribute("aria-pressed", tzMode() === "channel" ? "true" : "false") }
    sync()
    this.el.addEventListener("click", () => {
      try { localStorage.setItem("tz-mode", tzMode() === "channel" ? "local" : "channel") } catch (_e) {}
      sync()
      formatAll(document)
    })
  },
}
