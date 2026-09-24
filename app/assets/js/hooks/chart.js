// The one chart hook (project.md §13.7). The element says what to draw:
//
//   data-kind     one of the chart kinds (charts/index.js)
//   data-src      a /data/v1 URL returning the series (history is cacheable
//                 JSON, never LiveView assigns: §13.5)
//   data-values   inline data instead of data-src (sparklines)
//   data-opts     labels and which columns to draw (never ECharts options)
//
// A LiveView appends live points with push_event("chart:append", {id, t, values}).
// Inside the element's <figure>, buttons with data-chart-action="table" or
// "csv" switch to a table view or download the same data (§13.7).

let loading = null
const load = () => (loading ||= import("../charts/index.js"))

export const Chart = {
  mounted() {
    this.opts = JSON.parse(this.el.dataset.opts || "{}")
    this.canvas = document.createElement("div")
    this.canvas.className = "chart-canvas"
    this.canvas.style.width = "100%"
    this.canvas.style.height = "100%"
    this.el.appendChild(this.canvas)
    this.figure = this.el.closest("figure") || this.el.parentElement

    this.onAction = (e) => {
      const btn = e.target.closest("[data-chart-action]")
      if (!btn || !this.data) return
      if (btn.dataset.chartAction === "table") this.toggleTable(btn)
      if (btn.dataset.chartAction === "csv") this.downloadCsv()
    }
    this.figure.addEventListener("click", this.onAction)

    this.onWindow = (e) => {
      if (e.target.matches("[data-chart-window]")) this.loadChatters(e.target.value)
    }
    this.figure.addEventListener("change", this.onWindow)

    this.handleEvent("chart:append", ({id, t, values}) => {
      if (id === this.el.id && this.data) this.append(t, values)
    })

    this.themeObserver = new MutationObserver(() => this.render())
    this.themeObserver.observe(document.documentElement, {attributes: true, attributeFilter: ["data-theme"]})

    load().then(({echarts, kinds}) => {
      this.echarts = echarts
      this.kind = kinds[this.el.dataset.kind]
      this.chart = echarts.init(this.canvas, null, {renderer: "canvas"})
      this.resize = new ResizeObserver(() => this.chart && this.chart.resize())
      this.resize.observe(this.el)
      this.fetch()
    })
  },

  updated() {
    // A new data-src (the period changed): fetch again.
    if (this.el.dataset.src && this.el.dataset.src !== this.src) this.fetch()
  },

  destroyed() {
    this.figure && this.figure.removeEventListener("click", this.onAction)
    this.figure && this.figure.removeEventListener("change", this.onWindow)
    this.themeObserver && this.themeObserver.disconnect()
    this.resize && this.resize.disconnect()
    this.chart && this.chart.dispose()
  },

  fetch() {
    if (this.el.dataset.values) {
      this.data = {values: JSON.parse(this.el.dataset.values)}
      return this.render()
    }
    this.src = this.el.dataset.src
    this.el.classList.add("chart-loading")
    fetch(this.src, {headers: {accept: "application/json"}})
      .then((r) => (r.ok ? r.json() : Promise.reject(r.status)))
      .then((data) => {
        this.data = data
        this.el.classList.remove("chart-loading")
        this.render()
        if (this.el.dataset.chattersSrc) this.loadChatters(this.opts.window || 5)
      })
      .catch(() => {
        this.el.classList.remove("chart-loading")
        this.el.classList.add("chart-error")
      })
  },

  loadChatters(window) {
    const url = new URL(this.el.dataset.chattersSrc, location.href)
    url.searchParams.set("window", window)
    fetch(url).then((r) => r.json()).then((c) => {
      this.data.chatters = c
      this.render()
    })
  },

  render() {
    if (!this.chart || !this.kind || !this.data) return
    load().then(({tokens}) => {
      this.chart.setOption(this.kind.option(this.data, this.opts, tokens()), true)
    })
  },

  append(t, values) {
    const d = this.data.viewers || this.data
    if (d.t.length && d.t[d.t.length - 1] >= t) return
    d.t.push(t)
    for (const [k, v] of Object.entries(values)) (d[k] ||= []).push(v)
    if (this.data.stream) {
      this.data.stream.ended_at = null
    }
    this.render()
  },

  rows() {
    return this.kind.table(this.data, this.opts)
  },

  toggleTable(btn) {
    if (this.tableEl) {
      this.tableEl.remove()
      this.tableEl = null
      this.canvas.style.display = ""
      btn.setAttribute("aria-pressed", "false")
      return
    }
    const {cols, rows} = this.rows()
    const fmtCell = (c, i) => (i === 0 && cols[0] === "time" && typeof c === "number" ? new Date(c * 1000).toLocaleString() : c == null ? "–" : typeof c === "number" ? c.toLocaleString() : c)
    const wrap = document.createElement("div")
    wrap.className = "chart-table overflow-auto h-full text-xs"
    const table = document.createElement("table")
    table.className = "table table-xs"
    table.innerHTML = `<thead><tr>${cols.map((c) => `<th>${escape(c)}</th>`).join("")}</tr></thead>`
    const body = document.createElement("tbody")
    body.innerHTML = rows.slice(0, 5000).map((r) => `<tr>${r.map((c, i) => `<td>${escape(fmtCell(c, i))}</td>`).join("")}</tr>`).join("")
    table.appendChild(body)
    wrap.appendChild(table)
    this.canvas.style.display = "none"
    this.el.appendChild(wrap)
    this.tableEl = wrap
    btn.setAttribute("aria-pressed", "true")
  },

  downloadCsv() {
    const {cols, rows} = this.rows()
    const cell = (c, i) => (i === 0 && cols[0] === "time" && typeof c === "number" ? new Date(c * 1000).toISOString() : c == null ? "" : String(c))
    const csv = [cols, ...rows].map((r, n) => r.map((c, i) => csvCell(n === 0 ? c : cell(c, i))).join(",")).join("\n")
    const a = document.createElement("a")
    a.href = URL.createObjectURL(new Blob([csv], {type: "text/csv"}))
    a.download = (this.el.dataset.filename || this.el.id) + ".csv"
    a.click()
    URL.revokeObjectURL(a.href)
  },
}

const escape = (s) => String(s).replace(/[&<>"]/g, (c) => ({"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;"})[c])
const csvCell = (s) => (/[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s)
