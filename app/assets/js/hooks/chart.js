// The one chart hook (project.md §13.7). The element says what to draw:
//
//   data-kind     one of the chart kinds (charts/index.js)
//   data-src      a /data/v1 URL returning the series (history is cacheable
//                 JSON, never LiveView assigns: §13.5)
//   data-values   inline data instead of data-src
//   data-opts     labels and which columns to draw (never ECharts options)
//   data-refresh  seconds: fetch data-src again this often, for a chart
//                 whose range ends now (a rolling period, a live stream);
//                 paused while the page is hidden, caught up on return
//   data-error    the (translated) text shown when the data can't be loaded
//
// Only the latest request draws: a response to an older one (the period
// changed again meanwhile, or a slow refresh) is dropped. An open table
// view is rebuilt whenever the data changes.
//
// A LiveView appends live points with push_event("chart:append", {id, t, values}).
// Inside the element's <figure>, buttons with data-chart-action="table" or
// "csv" switch to a table view or download the same data (§13.7).
//
// Zoom: a time chart opens on the stretch that has data (not the whole
// requested period, which may be mostly empty before a channel was
// tracked), and the reader zooms from there: wheel or pinch, drag to pan,
// zoom out to the whole period. Their zoom survives live points and theme
// changes; double-click, or data-chart-action="fit", goes back to all
// the data.

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
      if (btn.dataset.chartAction === "fit") this.fit()
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
      // Only the reader's own zooming fires this (setOption doesn't).
      this.chart.on("datazoom", () => this.keepZoom())
      this.chart.getZr().on("dblclick", () => this.fit())
      this.resize = new ResizeObserver(() => this.chart && this.chart.resize())
      this.resize.observe(this.el)
      this.fetch()
      this.schedule()
    })

    this.onVisible = () => {
      if (!document.hidden && this.refreshMs && Date.now() - (this.fetchedAt || 0) >= this.refreshMs) this.fetch({quiet: true})
    }
    document.addEventListener("visibilitychange", this.onVisible)
  },

  updated() {
    // A new data-src (the period changed; a sparkline's minute moved) or
    // new inline values: draw again. A sparkline moves quietly.
    if (this.el.dataset.src && this.el.dataset.src !== this.src) this.fetch({quiet: !!this.data && this.el.dataset.kind === "sparkline"})
    else if (this.el.dataset.values && this.el.dataset.values !== this.values) this.fetch()
    // A stream that ended stops refreshing (after one last fetch, which
    // draws its end); one that started, starts.
    const refreshMs = Number(this.el.dataset.refresh || 0) * 1000
    if (refreshMs !== (this.refreshMs || 0)) {
      const stopped = this.refreshMs && !refreshMs
      this.schedule()
      if (stopped && this.el.dataset.src) this.fetch({quiet: true})
    }
  },

  // Fetch again every data-refresh seconds, while the page is visible.
  schedule() {
    clearInterval(this.timer)
    this.refreshMs = Number(this.el.dataset.refresh || 0) * 1000
    if (this.refreshMs && this.el.dataset.src) {
      this.timer = setInterval(() => document.hidden || this.fetch({quiet: true}), this.refreshMs)
    }
  },

  destroyed() {
    clearInterval(this.timer)
    document.removeEventListener("visibilitychange", this.onVisible)
    this.figure && this.figure.removeEventListener("click", this.onAction)
    this.figure && this.figure.removeEventListener("change", this.onWindow)
    this.themeObserver && this.themeObserver.disconnect()
    this.resize && this.resize.disconnect()
    this.chart && this.chart.dispose()
  },

  // A quiet fetch is a refresh: no loading state, and on failure the chart
  // keeps what it has (the next refresh tries again).
  fetch({quiet = false} = {}) {
    if (this.el.dataset.values) {
      this.values = this.el.dataset.values
      this.data = {values: JSON.parse(this.values)}
      return this.render()
    }
    const src = (this.src = this.el.dataset.src)
    const seq = (this.seq = (this.seq || 0) + 1)
    if (!quiet) this.el.classList.add("chart-loading")
    fetch(src, {headers: {accept: "application/json"}})
      .then((r) => (r.ok ? r.json() : Promise.reject(r.status)))
      .then((data) => {
        // A newer request was made while this was on its way: it draws.
        if (seq !== this.seq) return
        this.fetchedAt = Date.now()
        const chatters = this.data && this.data.chatters
        this.data = data
        if (chatters) this.data.chatters = chatters
        this.el.classList.remove("chart-loading", "chart-error")
        this.showNote(data.note)
        this.render()
        if (this.el.dataset.chattersSrc) this.loadChatters(this.chattersWindow || this.opts.window || 5)
      })
      .catch(() => {
        if (seq !== this.seq) return
        this.el.classList.remove("chart-loading")
        if (!quiet) this.el.classList.add("chart-error")
      })
  },

  // Active chatters in the chosen window. Before the chart's own data has
  // arrived, the window is only remembered: fetch() loads it afterwards.
  loadChatters(window) {
    this.chattersWindow = window
    if (!this.data || !this.el.dataset.chattersSrc) return
    const url = new URL(this.el.dataset.chattersSrc, location.href)
    url.searchParams.set("window", window)
    const seq = (this.chattersSeq = (this.chattersSeq || 0) + 1)
    fetch(url, {headers: {accept: "application/json"}})
      .then((r) => (r.ok ? r.json() : Promise.reject(r.status)))
      .then((c) => {
        if (seq !== this.chattersSeq || !this.data) return
        this.data.chatters = c
        this.render()
      })
      // The chatters line stays as it was; the next refresh tries again.
      .catch(() => {})
  },

  render() {
    if (!this.chart || !this.kind || !this.data) return
    load().then(({tokens}) => {
      const option = this.kind.option(this.data, this.opts, tokens())
      const window = option.dataZoom && (this.zoom || dataExtent(this.data, this.opts))
      if (window) {
        option.dataZoom = option.dataZoom.map((z) => ({...z, startValue: window[0], endValue: window[1]}))
      }
      this.chart.setOption(option, true)
      if (this.tableEl) this.fillTable()
    })
  },

  // The window the reader zoomed to, as axis values (ms).
  keepZoom() {
    const z = (this.chart.getOption().dataZoom || [])[0]
    if (z && z.startValue != null && z.endValue != null) this.zoom = [z.startValue, z.endValue]
  },

  // Back to all the data.
  fit() {
    this.zoom = null
    this.render()
  },

  append(t, values) {
    const d = this.data.viewers || this.data
    if (d.t.length && d.t[d.t.length - 1] >= t) return
    d.t.push(t)
    for (const [k, v] of Object.entries(values)) (d[k] ||= []).push(v)
    this.render()
  },

  // A caveat the server attaches to the data (already translated), e.g.
  // days drawn in whole hours for a half-hour timezone.
  showNote(note) {
    const el = this.figure && this.figure.querySelector("[data-chart-note]")
    if (!el) return
    el.textContent = note || ""
    el.hidden = !note
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
    const wrap = document.createElement("div")
    wrap.className = "chart-table overflow-auto h-full text-xs"
    this.canvas.style.display = "none"
    this.el.appendChild(wrap)
    this.tableEl = wrap
    this.fillTable()
    btn.setAttribute("aria-pressed", "true")
  },

  // The table view, from the data as it is now (again after each fetch or
  // live point, so it never shows stale rows).
  fillTable() {
    const {cols, rows} = this.rows()
    const fmtCell = (c, i) => (i === 0 && cols[0] === "time" && typeof c === "number" ? new Date(c * 1000).toLocaleString() : c == null ? "–" : typeof c === "number" ? c.toLocaleString() : c)
    const table = document.createElement("table")
    table.className = "table table-xs"
    table.innerHTML = `<thead><tr>${cols.map((c) => `<th>${escape(c)}</th>`).join("")}</tr></thead>`
    const body = document.createElement("tbody")
    body.innerHTML = rows.slice(0, 5000).map((r) => `<tr>${r.map((c, i) => `<td>${escape(fmtCell(c, i))}</td>`).join("")}</tr>`).join("")
    table.appendChild(body)
    this.tableEl.replaceChildren(table)
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

// The stretch of a time chart that has data: first to last time where any
// drawn column has a value, and a little room either side (2%, at least a
// minute). Null when there is nothing: the whole axis is shown (the
// period, or a stream from Kick's start to its end).

export function dataExtent(data, opts) {
  const spans = data.series
    ? data.series.map((s) => span(s.t, [s.v]))
    : data.stream
      ? [span(data.viewers.t, [data.viewers.avg]), span(data.chat.t, [data.chat.messages])]
      : data.t
        ? [span(data.t, (opts.columns || [{key: "v"}]).map((c) => data[c.key]).filter(Boolean))]
        : []
  const found = spans.filter(Boolean)
  if (!found.length) return null
  const first = Math.min(...found.map((s) => s[0]))
  const last = Math.max(...found.map((s) => s[1]))
  const room = Math.max((last - first) * 0.02, 60)
  return [(first - room) * 1000, (last + room) * 1000]
}

function span(t, columns) {
  let first = null, last = null
  for (let i = 0; i < t.length; i++) {
    if (columns.some((c) => c[i] != null)) {
      if (first == null) first = t[i]
      last = t[i]
    }
  }
  return first == null ? null : [first, last]
}

const escape = (s) => String(s).replace(/[&<>"]/g, (c) => ({"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;"})[c])
const csvCell = (s) => (/[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s)
