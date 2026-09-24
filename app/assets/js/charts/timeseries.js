// Time series (project.md §13.7): a line per column, a peak band above an
// average, bars, or one line per channel (compare). Gaps break the line
// (nulls) and coverage gaps are shaded "no data"; never drawn as zero.
import {baseOption, timeAxis, valueAxis, gapAreas, dayFormatter, zip, fmt, palette} from "./theme"

export function option(data, opts, t) {
  const o = baseOption(t)
  const xFmt = data.res === "1d" ? {axisLabel: {color: t.muted, hideOverlap: true, formatter: dayFormatter(data.tz)}} : {}
  o.xAxis = timeAxis(t, xFmt)
  // Counts start at zero; totals (followers) show their movement.
  o.yAxis = valueAxis(t, opts.zero === false ? {scale: true} : {min: 0})
  o.dataZoom = [{type: "inside", filterMode: "none"}]
  o.tooltip.valueFormatter = fmt
  o.series = []

  if (data.series) {
    // Compare: one line per channel.
    data.series.forEach((s, i) => {
      o.series.push({name: s.name, type: "line", showSymbol: false, connectNulls: false, data: zip(s.t, s.v),
        lineStyle: {width: 1.6, color: palette[i]}, itemStyle: {color: palette[i]}})
    })
    return o
  }

  const cols = opts.columns || [{key: "v", label: opts.label || "", style: "line"}]
  const avg = cols.find(c => c.style === "line")
  cols.forEach((c, i) => {
    const color = palette[i % palette.length]
    if (c.style === "band" && avg) {
      // The peak as a light band above the average (downsampling never hides a peak).
      const lower = zip(data.t, data[avg.key])
      const upper = data.t.map((x, j) => {
        const a = data[avg.key][j], m = data[c.key][j]
        return [x * 1000, a == null || m == null ? null : m - a]
      })
      o.series.push({name: "__base", type: "line", stack: "band", data: lower, lineStyle: {opacity: 0}, showSymbol: false, silent: true, tooltip: {show: false}})
      o.series.push({name: c.label, type: "line", stack: "band", data: upper, lineStyle: {opacity: 0}, showSymbol: false,
        areaStyle: {color: palette[0], opacity: t.band}, tooltip: {valueFormatter: (v) => fmt(v)}})
    } else if (c.style === "bar") {
      o.series.push({name: c.label, type: "bar", data: zip(data.t, data[c.key]), itemStyle: {color}, barMaxWidth: 8, stack: c.stack})
    } else {
      o.series.push({name: c.label, type: "line", showSymbol: false, connectNulls: false, data: zip(data.t, data[c.key]),
        lineStyle: {width: 1.6, color}, itemStyle: {color}, areaStyle: c.style === "area" ? {opacity: 0.15} : undefined, z: 3})
    }
  })
  o.legend.data = cols.map(c => c.label)

  const areas = gapAreas(data.gaps, t).concat(annotationAreas(data.annotations, t))
  if (areas.length && o.series.length) {
    const last = o.series[o.series.length - 1]
    last.markArea = {silent: false, data: areas}
  }
  return o
}

export function annotationAreas(list, t) {
  return (list || []).map(a => [
    {xAxis: a.from * 1000, itemStyle: {color: "rgba(204,121,167,0.12)"}, label: {show: true, formatter: a.text, color: t.muted, fontSize: 10}},
    {xAxis: (a.to || a.from + 60) * 1000},
  ])
}

export function table(data, opts) {
  if (data.series) {
    const times = [...new Set(data.series.flatMap(s => s.t))].sort((a, b) => a - b)
    const cols = ["time", ...data.series.map(s => s.name)]
    const maps = data.series.map(s => new Map(s.t.map((x, i) => [x, s.v[i]])))
    return {cols, rows: times.map(x => [x, ...maps.map(m => m.get(x) ?? null)])}
  }
  const cols = opts.columns || [{key: "v", label: "value"}]
  return {cols: ["time", ...cols.map(c => c.label)], rows: data.t.map((x, i) => [x, ...cols.map(c => data[c.key][i])])}
}
