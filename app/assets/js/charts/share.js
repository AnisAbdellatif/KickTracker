// Shares (project.md §13.7): a donut, e.g. hours watched per category.
import {baseOption, fmt} from "./theme"

export function option(data, opts, t) {
  const o = baseOption(t)
  o.tooltip = {trigger: "item", valueFormatter: fmt}
  o.legend = {type: "scroll", orient: "vertical", right: 0, top: "middle", textStyle: {color: t.muted}}
  o.series = [{type: "pie", radius: ["45%", "72%"], center: ["35%", "50%"], avoidLabelOverlap: true,
    label: {show: false}, data: data.labels.map((name, i) => ({name, value: data.values[i]}))}]
  return o
}

export function table(data, opts) {
  return {cols: [opts.label || "name", opts.valueLabel || "value"], rows: data.labels.map((n, i) => [n, data.values[i]])}
}
