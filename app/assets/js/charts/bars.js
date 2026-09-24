// Bars (project.md §13.7): counts per bucket, stacked when asked.
import {baseOption, timeAxis, valueAxis, dayFormatter, zip, fmt, palette} from "./theme"

export function option(data, opts, t) {
  const o = baseOption(t)
  const xFmt = data.res === "1d" ? {axisLabel: {color: t.muted, formatter: dayFormatter(data.tz)}} : {}
  o.xAxis = timeAxis(t, xFmt)
  o.yAxis = valueAxis(t, {min: 0})
  o.dataZoom = [{type: "inside", filterMode: "none"}]
  o.tooltip.valueFormatter = fmt
  const cols = opts.columns || []
  o.series = cols.map((c, i) => ({name: c.label, type: "bar", stack: c.stack, barMaxWidth: 10,
    data: zip(data.t, data[c.key]), itemStyle: {color: palette[(i + 2) % palette.length]}}))
  o.legend.data = cols.map(c => c.label)
  return o
}

export function table(data, opts) {
  const cols = opts.columns || []
  return {cols: ["time", ...cols.map(c => c.label)], rows: data.t.map((x, i) => [x, ...cols.map(c => data[c.key][i])])}
}
