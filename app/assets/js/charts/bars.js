// Bars (project.md §13.7): counts per bucket, stacked when asked, with a
// 2px surface gap between stacked segments.
import {baseOption, timeAxis, valueAxis, dayFormatter, zip, bar} from "./theme"

export function option(data, opts, t) {
  const o = baseOption(t)
  const xFmt = (data.res === "1d" || data.res === "1w") ? {axisLabel: {color: t.muted, formatter: dayFormatter(data.tz)}} : {}
  o.xAxis = timeAxis(t, xFmt)
  o.yAxis = valueAxis(t, {min: 0})
  o.dataZoom = [{type: "inside", filterMode: "none"}]
  const cols = opts.columns || []
  o.series = cols.map((c, i) => {
    const s = bar(c.label, zip(data.t, data[c.key]), t.palette[i], {stack: c.stack})
    if (c.stack) s.itemStyle = {...s.itemStyle, borderColor: t.surface, borderWidth: 1}
    return s
  })
  if (cols.length < 2) {
    delete o.legend
    o.grid.top = 12
  } else {
    o.legend.data = cols.map((c) => c.label)
  }
  return o
}

export function table(data, opts) {
  const cols = opts.columns || []
  return {cols: ["time", ...cols.map((c) => c.label)], rows: data.t.map((x, i) => [x, ...cols.map((c) => data[c.key][i])])}
}
