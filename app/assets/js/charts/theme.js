// Theme tokens shared by every chart kind (project.md §13.7): a
// colorblind-safe palette (Okabe–Ito), and text/grid colours read from the
// page's CSS so dark and light themes come from the same tokens.

export const palette = [
  "#E69F00", // orange
  "#56B4E9", // sky blue
  "#009E73", // green
  "#CC79A7", // purple
  "#0072B2", // blue
  "#D55E00", // vermilion
  "#F0E442", // yellow
  "#999999", // grey
]

function cssVar(name, fallback) {
  const v = getComputedStyle(document.documentElement).getPropertyValue(name).trim()
  return v || fallback
}

export function tokens() {
  const dark = document.documentElement.getAttribute("data-theme") === "dark"
  return {
    dark,
    text: cssVar("--color-base-content", dark ? "#e5e7eb" : "#1f2937"),
    muted: dark ? "rgba(229,231,235,0.55)" : "rgba(31,41,55,0.55)",
    grid: dark ? "rgba(255,255,255,0.08)" : "rgba(0,0,0,0.08)",
    noData: dark ? "rgba(255,255,255,0.06)" : "rgba(0,0,0,0.06)",
    band: dark ? 0.16 : 0.12,
    bg: "transparent",
  }
}

export function baseOption(t) {
  return {
    backgroundColor: t.bg,
    color: palette,
    textStyle: {color: t.text, fontFamily: "inherit"},
    animation: false,
    grid: {left: 8, right: 8, top: 28, bottom: 8, containLabel: true},
    tooltip: {trigger: "axis", confine: true},
    legend: {top: 0, textStyle: {color: t.muted}, itemWidth: 14, itemHeight: 8},
  }
}

// Numbers in the visitor's locale (§13.6).
const exact = new Intl.NumberFormat()
const compact = new Intl.NumberFormat(undefined, {notation: "compact", maximumFractionDigits: 1})
export const fmt = (v) => (v == null ? "–" : exact.format(v))
export const fmtCompact = (v) => (v == null ? "–" : compact.format(v))

export function timeAxis(t, extra = {}) {
  return {
    type: "time",
    axisLine: {lineStyle: {color: t.grid}},
    axisLabel: {color: t.muted, hideOverlap: true},
    splitLine: {show: false},
    ...extra,
  }
}

export function valueAxis(t, extra = {}) {
  return {
    type: "value",
    axisLabel: {color: t.muted, formatter: fmtCompact},
    splitLine: {lineStyle: {color: t.grid}},
    ...extra,
  }
}

// "No data" shading from coverage gaps ([from, to] unix seconds pairs).
export function gapAreas(gaps, t, label = "no data") {
  return (gaps || []).map(([a, b]) => [
    {xAxis: a * 1000, itemStyle: {color: t.noData}, label: {show: false, formatter: label}},
    {xAxis: b * 1000},
  ])
}

// Days drawn in the channel's timezone (§13.6), when the data says so.
export function dayFormatter(tz) {
  const f = new Intl.DateTimeFormat(undefined, {month: "short", day: "numeric", timeZone: tz || undefined})
  return (v) => f.format(new Date(v))
}

export function zip(t, v) {
  const out = new Array(t.length)
  for (let i = 0; i < t.length; i++) out[i] = [t[i] * 1000, v ? v[i] : null]
  return out
}
