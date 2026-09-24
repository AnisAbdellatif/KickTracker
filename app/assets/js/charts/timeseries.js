// Time series (project.md §13.7): a line per column, a peak band above an
// average, bars, or one line per channel (compare). Gaps break the line
// (nulls) and coverage gaps are shaded "no data"; never drawn as zero.
import {baseOption, timeAxis, valueAxis, gapAreas, dayFormatter, zip, line, bar, alpha, fmt} from "./theme"

export function option(data, opts, t) {
  const o = baseOption(t)
  const xFmt = data.res === "1d" ? {axisLabel: {color: t.muted, hideOverlap: true, formatter: dayFormatter(data.tz)}} : {}
  o.xAxis = timeAxis(t, xFmt)
  // Counts start at zero; totals (followers) show their movement.
  o.yAxis = valueAxis(t, opts.zero === false ? {scale: true} : {min: 0})
  o.dataZoom = [{type: "inside", filterMode: "none"}]
  o.series = []

  if (data.series) {
    // Compare: one line per channel, colours in fixed order by position.
    data.series.forEach((s, i) => o.series.push(line(s.name, zip(s.t, s.v), t.palette[i])))
    o.legend.data = data.series.map((s) => s.name)
    return o
  }

  const cols = opts.columns || [{key: "v", label: opts.label || "", style: "line"}]
  const main = cols.find((c) => c.style === "line")
  let slot = 0

  cols.forEach((c) => {
    if (c.style === "band" && main) {
      // The peak as a light band above the average, in the average's hue:
      // downsampling never hides a peak.
      const color = t.palette[0]
      const lower = zip(data.t, data[main.key])
      const upper = data.t.map((x, j) => {
        const a = data[main.key][j], m = data[c.key][j]
        return [x * 1000, a == null || m == null ? null : m - a]
      })
      o.series.push({name: "__base", type: "line", stack: "band", data: lower, lineStyle: {opacity: 0},
        showSymbol: false, silent: true, tooltip: {show: false}})
      o.series.push({name: c.label, type: "line", stack: "band", data: upper, lineStyle: {opacity: 0},
        showSymbol: false, itemStyle: {color: alpha(color, 0.35)}, areaStyle: {color: alpha(color, 0.14)},
        // The band is drawn as peak minus average, stacked on the average;
        // the tooltip shows the peak itself.
        tooltip: {valueFormatter: (_v, i) => fmt(data[c.key][i])}})
    } else if (c.style === "bar") {
      o.series.push(bar(c.label, zip(data.t, data[c.key]), t.palette[slot++], {stack: c.stack}))
    } else {
      const color = t.palette[slot++]
      o.series.push(line(c.label, zip(data.t, data[c.key]), color, {
        z: 3,
        areaStyle: c.style === "area" || cols.length === 1 ? {color: alpha(color, 0.1)} : undefined,
      }))
    }
  })

  // A legend only for two or more series; one series is named by the title.
  const named = o.series.filter((s) => s.name !== "__base")
  if (named.length < 2) delete o.legend
  else o.legend.data = named.map((s) => s.name)
  if (!o.legend) o.grid.top = 12

  const areas = gapAreas(data.gaps, t).concat(annotationAreas(data.annotations, t))
  if (areas.length && o.series.length) o.series[o.series.length - 1].markArea = {silent: false, data: areas}
  return o
}

export function annotationAreas(list, t) {
  return (list || []).map((a) => [
    {xAxis: a.from * 1000, itemStyle: {color: alpha(t.palette[4], 0.12)},
      label: {show: true, formatter: a.text, color: t.text2, fontSize: 10}},
    {xAxis: (a.to || a.from + 60) * 1000},
  ])
}

export function table(data, opts) {
  if (data.series) {
    const times = [...new Set(data.series.flatMap((s) => s.t))].sort((a, b) => a - b)
    const cols = ["time", ...data.series.map((s) => s.name)]
    const maps = data.series.map((s) => new Map(s.t.map((x, i) => [x, s.v[i]])))
    return {cols, rows: times.map((x) => [x, ...maps.map((m) => m.get(x) ?? null)])}
  }
  const cols = opts.columns || [{key: "v", label: "value"}]
  return {cols: ["time", ...cols.map((c) => c.label)], rows: data.t.map((x, i) => [x, ...cols.map((c) => data[c.key][i])])}
}
