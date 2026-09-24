// Shares (project.md §13.7): a donut, e.g. hours watched per category.
// Fixed colour order; past seven slices the rest fold into "Other".
import {baseOption, tooltip, fmt, escapeHtml} from "./theme"

const MAX = 7

export function option(data, opts, t) {
  const o = baseOption(t)
  let items = data.labels.map((name, i) => ({name, value: data.values[i]}))
  if (items.length > MAX) {
    const rest = items.slice(MAX - 1).reduce((s, x) => s + (x.value || 0), 0)
    items = items.slice(0, MAX - 1).concat([{name: opts.otherLabel || "Other", value: rest}])
  }
  const total = items.reduce((s, x) => s + (x.value || 0), 0)
  o.tooltip = tooltip(t, {trigger: "item", formatter: (p) => `${p.marker} ${escapeHtml(p.name)}<br><b>${fmt(p.value)}</b> · ${p.percent}%`})
  o.legend = {type: "scroll", orient: "vertical", right: 0, top: "middle", icon: "roundRect", itemWidth: 10, itemHeight: 10,
    textStyle: {color: t.text2, fontSize: 11},
    formatter: (name) => {
      const it = items.find((x) => x.name === name)
      return total > 0 && it ? `${name}  ${Math.round((it.value / total) * 100)}%` : name
    }}
  o.series = [{type: "pie", radius: ["52%", "78%"], center: ["30%", "50%"], avoidLabelOverlap: true,
    itemStyle: {borderColor: t.surface, borderWidth: 2, borderRadius: 4},
    label: {show: false}, emphasis: {scale: false},
    data: items.map((x, i) => ({...x, itemStyle: {color: t.palette[i]}}))}]
  return o
}

export function table(data, opts) {
  return {cols: [opts.label || "name", opts.valueLabel || "value"], rows: data.labels.map((n, i) => [n, data.values[i]])}
}
