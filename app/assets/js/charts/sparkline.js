// Sparklines (project.md §13.7): a tiny line without axes, from values
// embedded in the page (no request).
import {palette} from "./theme"

export function option(data) {
  return {
    animation: false,
    grid: {left: 0, right: 0, top: 2, bottom: 2},
    xAxis: {type: "category", show: false, data: data.values.map((_, i) => i)},
    yAxis: {type: "value", show: false, min: 0},
    series: [{type: "line", data: data.values, showSymbol: false, connectNulls: false,
      lineStyle: {width: 1.4, color: palette[0]}, areaStyle: {color: palette[0], opacity: 0.12}}],
  }
}

export function table(data) {
  return {cols: ["i", "value"], rows: data.values.map((v, i) => [i, v])}
}
