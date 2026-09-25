// Theme tokens shared by every chart kind (project.md §13.7). Colours come
// from CSS custom properties (assets/css/app.css), so dark and light are the
// same tokens: a colour-blind-checked categorical palette used in a fixed
// order, one blue ramp for magnitudes, and quiet chrome around the data.
// A series that is one of the site's metrics takes that metric's hue
// (`metric` on its column), the same hue as its stat card and icon.

const METRICS = ["hw", "avg", "peak", "airtime", "followers", "chat", "subs"]

function cssVar(name, fallback) {
  const v = getComputedStyle(document.documentElement).getPropertyValue(name).trim()
  return v || fallback
}

export function tokens() {
  const dark = document.documentElement.getAttribute("data-theme") === "dark"
  const palette = [1, 2, 3, 4, 5, 6, 7, 8].map((i) => cssVar(`--viz-${i}`, "#3fa2ff"))
  const metric = Object.fromEntries(METRICS.map((m) => [m, cssVar(`--metric-${m}`, palette[0])]))
  return {
    dark,
    palette,
    metric,
    sequential: cssVar("--viz-seq", "#cde2fb, #3987e5, #0d366b").split(",").map((s) => s.trim()),
    surface: cssVar("--viz-surface", dark ? "#17171c" : "#ffffff"),
    text: cssVar("--viz-ink", dark ? "#f4f4f6" : "#0c0c10"),
    text2: cssVar("--viz-ink-2", dark ? "#a3a3ae" : "#555663"),
    muted: cssVar("--viz-muted", "#8a8a96"),
    grid: cssVar("--viz-grid", dark ? "#26262e" : "#e6e8ee"),
    axis: cssVar("--viz-axis", dark ? "#3a3a44" : "#c9ccd5"),
    noData: cssVar("--viz-nodata", "rgba(0,0,0,0.05)"),
  }
}

// A column's colour: its metric's hue when it names one, else the next
// free palette slot (`slot` is a counter object shared across columns).
export function columnColor(t, c, slot) {
  if (c.metric && t.metric[c.metric]) return t.metric[c.metric]
  return t.palette[slot.i++ % t.palette.length]
}

// A colour with an alpha, for area washes (~10%) and bands.
export function alpha(hex, a) {
  const h = hex.replace("#", "")
  const n = parseInt(h.length === 3 ? h.split("").map((c) => c + c).join("") : h, 16)
  return `rgba(${(n >> 16) & 255}, ${(n >> 8) & 255}, ${n & 255}, ${a})`
}

export function baseOption(t) {
  return {
    backgroundColor: "transparent",
    color: t.palette,
    textStyle: {color: t.text2, fontFamily: "system-ui, -apple-system, 'Segoe UI', sans-serif", fontSize: 11},
    animation: false,
    grid: {left: 4, right: 12, top: 28, bottom: 4, containLabel: true},
    tooltip: tooltip(t),
    legend: legend(t),
  }
}

export function tooltip(t, extra = {}) {
  return {
    trigger: "axis",
    confine: true,
    backgroundColor: t.surface,
    borderColor: t.grid,
    borderWidth: 1,
    padding: [6, 10],
    textStyle: {color: t.text, fontSize: 12},
    extraCssText: "border-radius: 10px; box-shadow: 0 12px 32px -8px rgba(0,0,0,.35);",
    axisPointer: {type: "line", lineStyle: {color: t.axis, width: 1}},
    valueFormatter: fmt,
    ...extra,
  }
}

export function legend(t) {
  return {top: 0, left: 0, icon: "roundRect", itemWidth: 10, itemHeight: 10, itemGap: 14,
    textStyle: {color: t.text2, fontSize: 11}}
}

// Numbers in the visitor's locale (§13.6).
const exact = new Intl.NumberFormat()
// Axis ticks are ECharts' round steps, so every significant digit is kept:
// a tight range (25,990 to 26,020 followers) needs "25.99K" and "26.01K",
// which one fraction digit would all turn into "26K".
const compact = new Intl.NumberFormat(undefined, {notation: "compact", maximumSignificantDigits: 21})
export const fmt = (v) => (v == null ? "–" : exact.format(Math.abs(v) >= 10 ? Math.round(v) : Math.round(v * 10) / 10))
export const fmtCompact = (v) => (v == null ? "–" : compact.format(v))

export function timeAxis(t, extra = {}) {
  return {
    type: "time",
    axisLine: {lineStyle: {color: t.axis}},
    axisTick: {show: false},
    axisLabel: {color: t.muted, hideOverlap: true},
    splitLine: {show: false},
    ...extra,
  }
}

export function valueAxis(t, extra = {}) {
  return {
    type: "value",
    axisLabel: {color: t.muted, formatter: fmtCompact},
    splitLine: {lineStyle: {color: t.grid, width: 1, type: "solid"}},
    splitNumber: 4,
    ...extra,
  }
}

// "No data" shading from coverage gaps ([from, to] unix seconds pairs).
export function gapAreas(gaps, t) {
  return (gaps || []).map(([a, b]) => [
    {xAxis: a * 1000, itemStyle: {color: t.noData}},
    {xAxis: b * 1000},
  ])
}

// Streamer-controlled text (titles, categories, raiders) put into a
// tooltip's HTML is escaped, so it shows as text and never as markup.
export function escapeHtml(s) {
  return String(s ?? "").replace(/[&<>"']/g, (c) => ({"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"})[c])
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

// A line: 2px, round joins, an optional ~10% area wash beneath.
export function line(name, data, color, extra = {}) {
  return {
    name, type: "line", data, showSymbol: false, connectNulls: false, symbolSize: 8,
    lineStyle: {width: 2.5, color, cap: "round", join: "round"},
    itemStyle: {color},
    emphasis: {focus: "none", scale: false},
    ...extra,
  }
}

// Bars: capped width, 4px rounded data end, square at the baseline.
export function bar(name, data, color, extra = {}) {
  return {
    name, type: "bar", data, barMaxWidth: 24, barMinWidth: 1,
    itemStyle: {color, borderRadius: extra.stack ? 0 : [4, 4, 0, 0]},
    ...extra,
  }
}
