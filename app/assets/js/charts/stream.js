// The stream page (project.md §13.3): one time axis, stacked panels sharing
// zoom and crosshair. Viewers at 60s with category bands, title ticks,
// markers and "no data" shading; chat (messages and active chatters); support.
import {baseOption, timeAxis, valueAxis, gapAreas, zip, fmt, palette} from "./theme"
import {annotationAreas} from "./timeseries"

const bandColors = ["rgba(86,180,233,0.10)", "rgba(230,159,0,0.10)", "rgba(0,158,115,0.10)", "rgba(204,121,167,0.10)"]

export function option(data, opts, t) {
  const o = baseOption(t)
  const L = opts.labels || {}
  o.grid = [
    {left: 8, right: 8, top: 30, height: "44%", containLabel: true},
    {left: 8, right: 8, top: "58%", height: "18%", containLabel: true},
    {left: 8, right: 8, top: "82%", height: "13%", containLabel: true},
  ]
  o.axisPointer = {link: [{xAxisIndex: "all"}]}
  o.tooltip = {trigger: "axis", confine: true, valueFormatter: fmt}
  const min = data.stream.started_at * 1000
  const max = (data.stream.ended_at || Date.now() / 1000) * 1000
  o.xAxis = [0, 1, 2].map(i => timeAxis(t, {gridIndex: i, min, max, axisLabel: {show: i === 2, color: t.muted, hideOverlap: true}}))
  o.yAxis = [0, 1, 2].map(i => valueAxis(t, {gridIndex: i, min: 0, splitNumber: i === 0 ? 4 : 2}))
  o.dataZoom = [{type: "inside", xAxisIndex: [0, 1, 2], filterMode: "none"}, {type: "slider", xAxisIndex: [0, 1, 2], bottom: 0, height: 14, showDetail: false}]

  const segments = (data.segments || []).map((s, i) => [
    {xAxis: s.from * 1000, name: s.name, itemStyle: {color: bandColors[i % bandColors.length]},
      label: {show: true, position: "insideTopLeft", color: t.muted, fontSize: 10}},
    {xAxis: s.to * 1000},
  ])
  const gaps = gapAreas(data.viewers.gaps, t)
  const titles = (data.titles || []).slice(1).map(x => ({xAxis: x.at * 1000, name: x.title,
    label: {show: false}, lineStyle: {color: t.muted, type: "dotted", width: 1}}))
  const markers = (data.markers || []).map(m => ({
    coord: [m.at * 1000, nearest(data.viewers, m.at)],
    value: m.value, name: markerName(m, L),
    symbol: m.kind === "gift" ? "diamond" : m.kind === "kicks" ? "triangle" : "pin",
    symbolSize: m.kind === "gift" || m.kind === "kicks" ? 9 : 22,
    itemStyle: {color: m.kind === "gift" ? palette[3] : m.kind === "kicks" ? palette[2] : palette[5]},
    label: {show: false},
  }))

  o.series = [
    {name: L.viewers || "Viewers", type: "line", xAxisIndex: 0, yAxisIndex: 0, showSymbol: false, connectNulls: false,
      data: zip(data.viewers.t, data.viewers.avg), lineStyle: {width: 1.6, color: palette[0]}, itemStyle: {color: palette[0]},
      areaStyle: {opacity: 0.08},
      markArea: {silent: true, data: segments.concat(gaps).concat(annotationAreas(data.annotations, t))},
      markLine: {silent: false, symbol: "none", data: titles, tooltip: {formatter: (p) => p.name}},
      markPoint: {data: markers, tooltip: {formatter: (p) => p.name}}},
    {name: L.messages || "Messages / min", type: "bar", xAxisIndex: 1, yAxisIndex: 1, barMaxWidth: 4,
      data: zip(data.chat.t, data.chat.messages), itemStyle: {color: palette[1], opacity: 0.6},
      markArea: {silent: true, data: gapAreas(data.chat.gaps, t)}},
    {name: L.chatters || "Active chatters", type: "line", xAxisIndex: 1, yAxisIndex: 1, showSymbol: false, connectNulls: false,
      data: data.chatters ? zip(data.chatters.t, data.chatters.chatters) : [], lineStyle: {width: 1.4, color: palette[4]}, itemStyle: {color: palette[4]}},
    {name: L.subs || "Subs", type: "bar", stack: "support", xAxisIndex: 2, yAxisIndex: 2, barMaxWidth: 4, data: zip(data.support.t, data.support.subs), itemStyle: {color: palette[2]}},
    {name: L.gifts || "Gifted subs", type: "bar", stack: "support", xAxisIndex: 2, yAxisIndex: 2, barMaxWidth: 4, data: zip(data.support.t, data.support.gifts), itemStyle: {color: palette[3]}},
  ]
  o.legend.data = o.series.map(s => s.name)
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
