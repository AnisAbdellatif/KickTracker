// Sparklines (project.md §13.7): a tiny line without axes, from values
// embedded in the page (no request). A single reading shows as a dot.
import {alpha} from "./theme"

export function option(data, opts, t) {
  const color = t.palette[0]
  const values = data.values
  const points = values.filter((v) => v != null).length
  return {
    animation: false,
    grid: {left: 2, right: 6, top: 4, bottom: 2},
    xAxis: {type: "category", show: false, boundaryGap: false, data: values.map((_, i) => i)},
    yAxis: {type: "value", show: false, min: 0},
    tooltip: {show: false},
    series: [{type: "line", data: values, connectNulls: false, smooth: 0.3,
      showSymbol: points <= 1, symbolSize: 6,
      // The latest reading gets a dot.
      markPoint: points > 1 ? {symbol: "circle", symbolSize: 6, itemStyle: {color, borderColor: t.surface, borderWidth: 2},
        label: {show: false}, data: [{coord: [lastIndex(values), values[lastIndex(values)]]}]} : undefined,
      lineStyle: {width: 2, color}, itemStyle: {color}, areaStyle: {color: alpha(color, 0.12)}}],
  }
}

function lastIndex(values) {
  for (let i = values.length - 1; i >= 0; i--) if (values[i] != null) return i
  return 0
}

export function table(data) {
  return {cols: ["i", "value"], rows: data.values.map((v, i) => [i, v])}
}
