// Theme tokens shared by every chart kind (project.md §13.7). Colours come
// from CSS custom properties (assets/css/app.css), so dark and light are the
// same tokens: a colour-blind-checked categorical palette used in a fixed
// order, one blue ramp for magnitudes, and quiet chrome around the data.

function cssVar(name, fallback) {
  const v = getComputedStyle(document.documentElement).getPropertyValue(name).trim()
  return v || fallback
}

export function tokens() {
  const dark = document.documentElement.getAttribute("data-theme") === "dark"
  const palette = [1, 2, 3, 4, 5, 6, 7, 8].map((i) => cssVar(`--viz-${i}`, "#2a78d6"))
  return {
    dark,
    palette,
    sequential: cssVar("--viz-seq", "#cde2fb, #3987e5, #0d366b").split(",").map((s) => s.trim()),
    surface: cssVar("--viz-surface", dark ? "#1a1a19" : "#fcfcfb"),
    text: cssVar("--viz-ink", dark ? "#ffffff" : "#0b0b0b"),
    text2: cssVar("--viz-ink-2", dark ? "#c3c2b7" : "#52514e"),
    muted: cssVar("--viz-muted", "#898781"),
    grid: cssVar("--viz-grid", dark ? "#2c2c2a" : "#e1e0d9"),
    axis: cssVar("--viz-axis", dark ? "#383835" : "#c3c2b7"),
    noData: cssVar("--viz-nodata", "rgba(0,0,0,0.05)"),
  }
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
    extraCssText: "border-radius: 8px; box-shadow: 0 4px 16px rgba(0,0,0,.12);",
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
const compact = new Intl.NumberFormat(undefined, {notation: "compact", maximumFractionDigits: 1})
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
    lineStyle: {width: 2, color, cap: "round", join: "round"},
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
