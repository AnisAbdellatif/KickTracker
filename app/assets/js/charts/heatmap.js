// Weekday × hour (project.md §13.7), in the channel's timezone: average
// viewers in each hour of the week, on one blue ramp (magnitude is
// sequential: one hue, light to dark); empty where the channel was never live.
// Rows are Monday first; their names come from the visitor's locale
// (§13.6), and the unit in the tooltip from the page (opts.unit).
import {baseOption, tooltip, fmt, escapeHtml} from "./theme"

// 2024-01-01 was a Monday.
const days = () => {
  const f = new Intl.DateTimeFormat(undefined, {weekday: "short", timeZone: "UTC"})
  return [...Array(7).keys()].map((i) => f.format(new Date(Date.UTC(2024, 0, 1 + i))))
}

export function option(data, opts, t) {
  const o = baseOption(t)
  const names = days()
  const cells = []
  let max = 0
  data.values.forEach((row, d) => row.forEach((v, h) => {
    if (v != null) { cells.push([h, d, v]); max = Math.max(max, v) }
  }))
  delete o.legend
  o.grid = {left: 4, right: 4, top: 4, bottom: 36, containLabel: true}
  o.tooltip = tooltip(t, {trigger: "item",
    formatter: (p) => `${escapeHtml(names[p.value[1]])} ${String(p.value[0]).padStart(2, "0")}:00<br><b>${fmt(p.value[2])}</b> ${escapeHtml(opts.unit || "")}`})
  o.xAxis = {type: "category", data: [...Array(24).keys()].map((h) => String(h).padStart(2, "0")),
    axisLabel: {color: t.muted, interval: 2}, axisLine: {show: false}, axisTick: {show: false}, splitArea: {show: false}}
  o.yAxis = {type: "category", data: names, inverse: true, axisLabel: {color: t.muted}, axisLine: {show: false}, axisTick: {show: false}}
  o.visualMap = {min: 0, max: max || 1, calculable: false, orient: "horizontal", left: "center", bottom: 0,
    itemHeight: 140, itemWidth: 8, textStyle: {color: t.muted, fontSize: 10}, formatter: (v) => fmt(v),
    inRange: {color: t.sequential}}
  o.series = [{type: "heatmap", data: cells, itemStyle: {borderColor: t.surface, borderWidth: 2, borderRadius: 3},
    emphasis: {itemStyle: {borderColor: t.text, borderWidth: 1}}}]
  return o
}

export function table(data) {
  const names = days()
  return {cols: ["day", ...[...Array(24).keys()].map((h) => `${h}h`)], rows: data.values.map((row, d) => [names[d], ...row])}
}
