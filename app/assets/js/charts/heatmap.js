// Weekday × hour (project.md §13.7), in the channel's timezone: the average
// viewers in each hour of the week; empty where the channel was never live.
import {baseOption, fmt} from "./theme"

export function option(data, opts, t) {
  const o = baseOption(t)
  const cells = []
  let max = 0
  data.values.forEach((row, d) => row.forEach((v, h) => {
    if (v != null) { cells.push([h, d, v]); max = Math.max(max, v) }
  }))
  o.grid = {left: 8, right: 8, top: 8, bottom: 40, containLabel: true}
  o.tooltip = {trigger: "item", formatter: (p) => `${data.days[p.value[1]]} ${String(p.value[0]).padStart(2, "0")}:00 · ${fmt(p.value[2])}`}
  o.xAxis = {type: "category", data: [...Array(24).keys()].map(h => String(h).padStart(2, "0")), axisLabel: {color: t.muted}, splitArea: {show: false}}
  o.yAxis = {type: "category", data: data.days, inverse: true, axisLabel: {color: t.muted}}
  o.visualMap = {min: 0, max: max || 1, calculable: false, orient: "horizontal", left: "center", bottom: 0, itemHeight: 120, itemWidth: 10,
    textStyle: {color: t.muted}, inRange: {color: t.dark ? ["#1e293b", "#56B4E9", "#E69F00"] : ["#eef6fb", "#56B4E9", "#D55E00"]}}
  o.series = [{type: "heatmap", data: cells, emphasis: {itemStyle: {borderColor: t.text}}}]
  delete o.legend
  return o
}

export function table(data) {
  return {cols: ["day", ...[...Array(24).keys()].map(h => `${h}h`)], rows: data.values.map((row, d) => [data.days[d], ...row])}
}
