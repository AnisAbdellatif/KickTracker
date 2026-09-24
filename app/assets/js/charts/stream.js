// The stream page (project.md §13.3): one time axis, stacked panels sharing
// zoom and crosshair. Viewers at 60s with category bands, title ticks,
// markers and "no data" shading; chat (messages and active chatters); support.
import {baseOption, tooltip, timeAxis, valueAxis, gapAreas, zip, line, bar, alpha} from "./theme"
import {annotationAreas} from "./timeseries"


export function option(data, opts, t) {
  const o = baseOption(t)
  const L = opts.labels || {}
  o.grid = [
    {left: 8, right: 8, top: 30, height: "44%", containLabel: true},
    {left: 8, right: 8, top: "58%", height: "18%", containLabel: true},
    {left: 8, right: 8, top: "82%", height: "13%", containLabel: true},
  ]
  o.axisPointer = {link: [{xAxisIndex: "all"}]}
  o.tooltip = tooltip(t)
  const P = t.palette
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
  const markers = (data.markers || []).map(m => ({
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
      markLine: {silent: false, symbol: "none", data: titles, tooltip: {formatter: (p) => p.name}},
      markPoint: {data: markers, tooltip: {formatter: (p) => p.name}}}),
    bar(L.messages || "Messages / min", zip(data.chat.t, data.chat.messages), alpha(P[0], 0.35), {
      xAxisIndex: 1, yAxisIndex: 1, barMaxWidth: 4, itemStyle: {color: alpha(P[0], 0.35), borderRadius: [2, 2, 0, 0]},
      markArea: {silent: true, data: gapAreas(data.chat.gaps, t)}}),
    line(L.chatters || "Active chatters", data.chatters ? zip(data.chatters.t, data.chatters.chatters) : [], P[1], {xAxisIndex: 1, yAxisIndex: 1}),
    bar(L.subs || "Subs", zip(data.support.t, data.support.subs), P[2], {stack: "support", xAxisIndex: 2, yAxisIndex: 2, barMaxWidth: 4}),
    bar(L.gifts || "Gifted subs", zip(data.support.t, data.support.gifts), P[4], {stack: "support", xAxisIndex: 2, yAxisIndex: 2, barMaxWidth: 4}),
  ]
  o.legend.data = o.series.map((s) => s.name)
  return o
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
  if (m.kind === "flagged") return `${m.value}: ${L.flagged || "flagged reading, not counted as a peak"}`
  if (m.kind === "gift") return `${m.value} ${L.gifted || "gifted subs"}`
  if (m.kind === "kicks") return `${m.value} Kicks`
  return `${m.kind}${m.other ? " · " + m.other : ""}${m.value ? " · " + m.value : ""}`
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
