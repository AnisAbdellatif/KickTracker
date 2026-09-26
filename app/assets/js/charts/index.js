// The fixed set of chart kinds (project.md §13.7). The server sends data and
// a kind, never ECharts options. Loaded only on pages with charts.
// Only the parts of ECharts these kinds use, to keep the chunk small.
import * as echarts from "echarts/core"
import {LineChart, BarChart, PieChart, HeatmapChart} from "echarts/charts"
import {GridComponent, TooltipComponent, LegendComponent, DataZoomComponent, MarkAreaComponent,
  MarkLineComponent, MarkPointComponent, VisualMapComponent, AxisPointerComponent} from "echarts/components"
import {CanvasRenderer} from "echarts/renderers"

echarts.use([LineChart, BarChart, PieChart, HeatmapChart, GridComponent, TooltipComponent, LegendComponent,
  DataZoomComponent, MarkAreaComponent, MarkLineComponent, MarkPointComponent, VisualMapComponent,
  AxisPointerComponent, CanvasRenderer])
import * as timeseries from "./timeseries"
import * as stream from "./stream"
import * as share from "./share"
import * as heatmap from "./heatmap"
import * as bars from "./bars"
import * as sparkline from "./sparkline"

export const kinds = {timeseries, stream, share, heatmap, bars, sparkline}
export {echarts}
export {tokens} from "./theme"
export {fitYAxes} from "./yfit"
