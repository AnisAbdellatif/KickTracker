// The value axes fitted to the zoom window (project.md §13.7): when the
// reader zooms or pans a time chart, each value axis spans what is visible,
// not the whole period. ECharts' own way (dataZoom filterMode "filter")
// cuts every line at the first and last point inside the window; the
// charts keep filterMode "none", and this computes the axes instead.
//
// Pure: it reads the option a chart kind built (series of [ms, value]
// points) and returns yAxis settings to merge into it. Unknown values
// (null) are skipped, never counted as zero; stacked series are summed.

// fitYAxes(option, [from, to] ms, hidden series names) -> [{min, max}, ...],
// one per value axis, in order; an axis with nothing visible gets null
// bounds (ECharts' own, from all its data).
export function fitYAxes(option, window, hidden = new Set()) {
  const axes = [].concat(option.yAxis || [])
  const [from, to] = window
  const lo = axes.map(() => Infinity), hi = axes.map(() => -Infinity)

  for (const values of stacks(option.series || [], hidden)) {
    const {axis, points} = values
    if (!axes[axis]) continue
    // The points inside, and one either side where a line crosses the
    // window's edge (drawn from outside it, it must not be clipped). A
    // window before or after all the points shows none of them.
    let first = points.findIndex(([x]) => x >= from)
    if (first === -1) first = points.length
    let last = first
    while (last < points.length && points[last][0] <= to) last++
    const start = first > 0 && first < points.length ? first - 1 : first
    const end = last > 0 && last < points.length ? last : last - 1
    for (let i = start; i <= end; i++) {
      const v = points[i][1]
      if (v == null || Number.isNaN(v)) continue
      if (v < lo[axis]) lo[axis] = v
      if (v > hi[axis]) hi[axis] = v
    }
  }

  return axes.map((a, i) => {
    if (hi[i] === -Infinity) return {min: a.min ?? null, max: null}
    const zero = a.min === 0
    return nice(zero ? Math.min(0, lo[i]) : lo[i], hi[i], a.splitNumber || 5, zero)
  })
}

// The series as drawn on each axis: a stack's members added up point by
// point (the peak band: average plus peak-minus-average; stacked bars),
// the others as they are. Hidden series (off in the legend) don't count.
function stacks(series, hidden) {
  const out = [], byStack = new Map()
  for (const s of series) {
    if (!Array.isArray(s.data) || !s.data.length) continue
    if (hidden.has(s.name)) continue
    const axis = s.yAxisIndex || 0
    if (!s.stack) {
      out.push({axis, points: s.data})
      continue
    }
    const key = `${axis}:${s.stack}`
    const acc = byStack.get(key)
    if (!acc) {
      const entry = {axis, points: s.data.map(([x, v]) => [x, v])}
      byStack.set(key, entry)
      out.push(entry)
    } else {
      // Members of a stack share their times (one column each of the same rows).
      acc.points.forEach((p, j) => {
        const v = s.data[j] && s.data[j][1]
        if (v != null) p[1] = p[1] == null ? v : p[1] + v
      })
    }
  }
  return out
}

// Bounds on round steps, as ECharts would choose them: min on a step below
// the lowest value (or zero), max on a step above the highest.
function nice(lo, hi, parts, zero) {
  let span = hi - lo
  if (span <= 0) span = Math.abs(hi) * 0.1 || 1
  const raw = span / parts
  const mag = 10 ** Math.floor(Math.log10(raw))
  const f = raw / mag
  const step = (f <= 1 ? 1 : f <= 2 ? 2 : f <= 2.5 ? 2.5 : f <= 5 ? 5 : 10) * mag
  const max = Math.ceil(hi / step) * step
  const min = zero ? 0 : Math.floor(lo / step) * step
  return {min, max: max > min ? max : min + step}
}
