// The stream page (project.md §13.3): one time axis, stacked panels sharing
// zoom and crosshair. Viewers at 60s with category bands, title ticks,
// markers and "no data" shading; chat (messages and active chatters); support.
import {baseOption, tooltip, timeAxis, valueAxis, gapAreas, zip, line, bar, alpha, fmt, escapeHtml} from "./theme"
import {annotationAreas} from "./timeseries"


export function option(data, opts, t) {
  const o = baseOption(t)
  const L = opts.labels || {}
  const P = t.palette
  const hosts = hostLines(data, L, t)
  o.grid = [
    // Room above the viewer panel for the hosts' labels, one row per level.
    {left: 8, right: 8, top: 30 + hosts.rows * 22, height: "44%", containLabel: true},
    {left: 8, right: 8, top: "58%", height: "18%", containLabel: true},
    {left: 8, right: 8, top: "82%", height: "13%", containLabel: true},
  ]
  o.axisPointer = {link: [{xAxisIndex: "all"}]}
  // The crosshair's tooltip also names what happened near that minute (a
  // title change, a raid, a gift burst) and the category: the ticks and
  // markers themselves are too small to point at.
  o.tooltip = tooltip(t, {formatter: (ps) => axisTooltip(ps, data, L)})
  // Category bands: very light washes of the later palette slots, so they
  // never compete with the viewer line (slot 1).
  const bandColors = [alpha(P[2], 0.08), alpha(P[4], 0.08), alpha(P[6], 0.08), alpha(P[3], 0.08)]
  const min = data.stream.started_at * 1000
  const max = (data.stream.ended_at || Date.now() / 1000) * 1000
  o.xAxis = [0, 1, 2].map(i => timeAxis(t, {gridIndex: i, min, max, axisLabel: {show: i === 2, color: t.muted, hideOverlap: true}}))
  o.yAxis = [0, 1, 2].map(i => valueAxis(t, {gridIndex: i, min: 0, splitNumber: i === 0 ? 4 : 2}))
  o.dataZoom = [{type: "inside", xAxisIndex: [0, 1, 2], filterMode: "none"},
    {type: "slider", xAxisIndex: [0, 1, 2], bottom: 0, height: 14, showDetail: false, borderColor: t.grid,
      fillerColor: alpha(P[0], 0.12), handleStyle: {color: t.surface, borderColor: t.axis},
      dataBackground: {lineStyle: {color: t.axis}, areaStyle: {color: alpha(t.axis, 0.3)}}}]

  const segments = (data.segments || []).map((s, i) => [
    {xAxis: s.from * 1000, name: s.name, itemStyle: {color: bandColors[i % bandColors.length]},
      label: {show: true, position: "insideTopLeft", color: t.muted, fontSize: 10}},
    {xAxis: s.to * 1000},
  ])
  const gaps = gapAreas(data.viewers.gaps, t)
  const titles = (data.titles || []).slice(1).map(x => ({xAxis: x.at * 1000, name: x.title,
    label: {show: false}, lineStyle: {color: t.muted, type: "dotted", width: 1}}))
  const markerColor = (k) => (k === "gift" ? P[4] : k === "kicks" ? P[2] : k === "flagged" ? t.muted : P[1])
  const markers = (data.markers || []).filter(m => !HOSTS.has(m.kind)).map(m => ({
    coord: [m.at * 1000, m.kind === "flagged" ? m.value : nearest(data.viewers, m.at)],
    value: m.value, name: markerName(m, L),
    symbol: m.kind === "gift" ? "diamond" : m.kind === "kicks" ? "triangle" : m.kind === "flagged" ? "emptyCircle" : "pin",
    symbolSize: m.kind === "gift" || m.kind === "kicks" || m.kind === "flagged" ? 9 : 22,
    itemStyle: {color: markerColor(m.kind), borderColor: t.surface, borderWidth: 2},
    label: {show: false},
  }))

  o.series = [
    line(L.viewers || "Viewers", zip(data.viewers.t, data.viewers.avg), P[0], {
      xAxisIndex: 0, yAxisIndex: 0, areaStyle: {color: alpha(P[0], 0.1)},
      markArea: {silent: true, data: segments.concat(gaps).concat(annotationAreas(data.annotations, t))},
      markLine: {silent: true, symbol: "none", data: titles},
      markPoint: {silent: true, data: markers}}),
    bar(L.messages || "Messages / min", zip(data.chat.t, data.chat.messages), alpha(P[0], 0.35), {
      xAxisIndex: 1, yAxisIndex: 1, barMaxWidth: 4, itemStyle: {color: alpha(P[0], 0.35), borderRadius: [2, 2, 0, 0]},
      markArea: {silent: true, data: gapAreas(data.chat.gaps, t)}}),
    // Hosts as their own series on the viewer panel: a legend entry that
    // explains the lines and can hide them. No data, only the lines.
    ...(hosts.lines.length ? [line(L.hosts?.legend || "Hosts", [], hostColor(t), {
      xAxisIndex: 0, yAxisIndex: 0,
      markLine: {silent: true, symbol: "none", data: hosts.lines}})] : []),
    line(L.chatters || "Active chatters", data.chatters ? zip(data.chatters.t, data.chatters.chatters) : [], P[1], {xAxisIndex: 1, yAxisIndex: 1}),
    bar(L.subs || "Subs", zip(data.support.t, data.support.subs), P[2], {stack: "support", xAxisIndex: 2, yAxisIndex: 2, barMaxWidth: 4}),
    bar(L.gifts || "Gifted subs", zip(data.support.t, data.support.gifts), P[4], {stack: "support", xAxisIndex: 2, yAxisIndex: 2, barMaxWidth: 4}),
  ]
  o.legend.data = o.series.map((s) => s.name)
  return o
}

// Hosts (Kick's raids, project.md §16): `hosted_by` brought viewers in,
// `hosting` took this stream's viewers elsewhere.
const HOSTS = new Set(["hosted_by", "hosting"])
const hostColor = (t) => t.palette[6]

// A vertical line per host across the viewer panel, solid coming in and
// dashed going out, labelled above the panel: "← other · 542" (viewers
// from them), "→ other · 542" (viewers to them). Hosts close together
// alternate between two rows so their labels don't cover each other.
function hostLines(data, L, t) {
  const list = (data.markers || []).filter(m => HOSTS.has(m.kind)).sort((a, b) => a.at - b.at)
  const span = Math.max(1, (data.stream.ended_at || Date.now() / 1000) - data.stream.started_at)
  const color = hostColor(t)
  let prev = null, row = 0, rows = 0
  const lines = list.map((m) => {
    row = prev != null && (m.at - prev) / span < 0.12 ? (row + 1) % 2 : 0
    prev = m.at
    rows = Math.max(rows, row + 1)
    // A function, so a name is shown as is (a string would be read as an
    // ECharts template, "{b}" and the like).
    const text = hostShort(m, L)
    // Near either end the label runs inwards from its line, not off the chart.
    const f = (m.at - data.stream.started_at) / span
    const align = f > 0.85 ? "right" : f < 0.15 ? "left" : "center"
    return {
      xAxis: m.at * 1000,
      lineStyle: {color, width: 1.5, type: m.kind === "hosting" ? [4, 3] : "solid", opacity: 0.9},
      label: {
        show: true, position: "end", distance: 6 + row * 22, align, formatter: () => text,
        color: t.text, fontSize: 10, fontWeight: 600, padding: [3, 7], borderRadius: 999,
        backgroundColor: alpha(color, 0.16), borderColor: alpha(color, 0.7), borderWidth: 1,
      },
    }
  })
  return {lines, rows}
}

function hostShort(m, L) {
  const other = m.other || L.hosts?.someone || "?"
  return `${m.kind === "hosting" ? "→" : "←"} ${other}${m.value != null ? " · " + fmt(m.value) : ""}`
}

const fill = (template, values) =>
  String(template).replace(/%\{(\w+)\}/g, (_, k) => values[k] ?? "")

// The tooltip's line for a host: who, how many, and for an incoming one
// what the viewer count did in the 5 minutes after.
function hostTooltip(m, data, L) {
  const H = L.hosts || {}
  const other = escapeHtml(m.other || H.someone || "?")
  const template = m.kind === "hosting" ? H.hosting || "Hosting %{other}" : H.hosted_by || "Hosted by %{other}"
  let html = `<b>${fill(escapeHtml(template), {other})}</b>`
  if (m.value != null) html += ` · ${fmt(m.value)} ${escapeHtml(H.viewers || "viewers")}`
  if (m.kind === "hosted_by") {
    const before = readingAt(data.viewers, m.at), after = peakWithin(data.viewers, m.at, 300)
    if (before != null && after != null)
      html += `<div>${escapeHtml(fill(H.after || "%{before} → %{after} viewers within 5 minutes", {before: fmt(before), after: fmt(after)}))}</div>`
  }
  return `<div>${html}</div>`
}

// The last reading at or before `at`.
function readingAt(v, at) {
  let best = null
  for (let i = 0; i < v.t.length && v.t[i] <= at; i++) if (v.avg[i] != null) best = v.avg[i]
  return best
}

// The highest reading in (at, at + s]; unknown when there is none.
function peakWithin(v, at, s) {
  let best = null
  for (let i = 0; i < v.t.length; i++)
    if (v.t[i] > at && v.t[i] <= at + s && v.avg[i] != null && (best == null || v.avg[i] > best)) best = v.avg[i]
  return best
}

function nearest(v, at) {
  let best = null, dist = Infinity
  for (let i = 0; i < v.t.length; i++) {
    const d = Math.abs(v.t[i] - at)
    if (d < dist && v.avg[i] != null) { dist = d; best = v.avg[i] }
  }
  return best
}

function markerName(m, L) {
  if (m.kind === "flagged") return `${fmt(m.value)}: ${L.flagged || "flagged reading, not counted as a peak"}`
  if (m.kind === "gift") return `${fmt(m.value)} ${L.gifted || "gifted subs"}`
  if (m.kind === "kicks") return `${fmt(m.value)} ${L.kicks || "Kicks"}`
  const kind = (L.kinds || {})[m.kind] || L.event || m.kind
  return `${kind}${m.other ? " · " + m.other : ""}${m.value ? " · " + fmt(m.value) : ""}`
}

// Within half a reading of the hovered minute.
const NEAR_S = 45

function axisTooltip(ps, data, L) {
  const list = Array.isArray(ps) ? ps : [ps]
  if (!list.length) return ""
  const at = list[0].axisValue / 1000
  const lines = [`<div>${escapeHtml(list[0].axisValueLabel)}</div>`]
  const segment = (data.segments || []).find((s) => s.from <= at && at < s.to)
  if (segment) lines.push(`<div>${escapeHtml(L.category || "")}${L.category ? ": " : ""}<b>${escapeHtml(segment.name)}</b></div>`)
  for (const p of list) {
    const v = Array.isArray(p.value) ? p.value[1] : p.value
    if (v == null) continue
    lines.push(`<div>${p.marker}${escapeHtml(p.seriesName)} <b>${fmt(v)}</b></div>`)
  }
  const near = (x) => Math.abs(x - at) <= NEAR_S
  for (const x of (data.titles || []).slice(1)) {
    if (near(x.at)) lines.push(`<div>${escapeHtml(L.title || "")}${L.title ? ": " : ""}${escapeHtml(x.title)}</div>`)
  }
  for (const m of data.markers || []) {
    if (!near(m.at)) continue
    lines.push(HOSTS.has(m.kind) ? hostTooltip(m, data, L) : `<div><b>${escapeHtml(markerName(m, L))}</b></div>`)
  }
  return lines.join("")
}

export function table(data, opts) {
  const L = opts.labels || {}
  const chat = new Map(data.chat.t.map((x, i) => [x, data.chat.messages[i]]))
  return {
    cols: ["time", L.viewers || "viewers", L.messages || "messages"],
    rows: data.viewers.t.filter((x, i) => data.viewers.avg[i] != null).map((x) => {
      const i = data.viewers.t.indexOf(x)
      return [x, data.viewers.avg[i], chat.get(Math.floor(x / 60) * 60) ?? null]
    }),
  }
}
