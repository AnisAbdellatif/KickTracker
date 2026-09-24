defmodule KickTrackerWeb.SiteComponents do
  @moduledoc """
  Pieces shared by the public pages (project.md §13): the period picker,
  KPI cards, the chart figure, numbers and times formatted in the
  visitor's locale and timezone (§13.6), coverage and estimate labels.
  """

  use Phoenix.Component
  use Gettext, backend: KickTrackerWeb.Gettext

  use Phoenix.VerifiedRoutes,
    endpoint: KickTrackerWeb.Endpoint,
    router: KickTrackerWeb.Router,
    statics: KickTrackerWeb.static_paths()

  alias KickTrackerWeb.Period

  @doc "A number, formatted in the browser (compact forms only where asked, exact on hover)."
  attr :value, :any, required: true
  attr :compact, :boolean, default: false
  attr :class, :any, default: nil

  def num(assigns) do
    ~H"""
    <span :if={is_nil(@value)} class={@class}>–</span>
    <span
      :if={!is_nil(@value)}
      class={["tabular-nums", @class]}
      data-num={to_num(@value)}
      data-compact={@compact}
    >{plain(@value)}</span>
    """
  end

  defp to_num(%Decimal{} = d), do: Decimal.to_string(d)
  defp to_num(v) when is_float(v), do: Float.round(v, 1)
  defp to_num(v), do: v

  defp plain(v) when is_float(v), do: round(v)
  defp plain(%Decimal{} = d), do: Decimal.round(d) |> Decimal.to_string()
  defp plain(v), do: v

  @doc "A moment, shown in the visitor's timezone (or the channel's, when chosen)."
  attr :at, :any, required: true
  attr :fmt, :string, default: "datetime"
  attr :tz, :string, default: nil

  def time(assigns) do
    ~H"""
    <time :if={@at} datetime={DateTime.to_iso8601(@at)} data-fmt={@fmt} data-tz={@tz}>{Calendar.strftime(
      @at,
      "%Y-%m-%d %H:%M"
    )} UTC</time>
    """
  end

  @doc "A duration: 3h 20m."
  attr :seconds, :any, required: true

  def duration(assigns) do
    ~H"""
    <span class="tabular-nums">{format_duration(@seconds)}</span>
    """
  end

  @doc false
  def format_duration(nil), do: "–"

  def format_duration(s) do
    s = round(s)
    h = div(s, 3600)
    m = div(rem(s, 3600), 60)

    cond do
      h >= 48 -> "#{div(h, 24)}d #{rem(h, 24)}h"
      h > 0 -> "#{h}h #{m}m"
      true -> "#{m}m"
    end
  end

  @doc "The period picker; keeps the other query params."
  attr :period, Period, required: true
  attr :path, :string, required: true
  attr :params, :map, default: %{}

  def period_picker(assigns) do
    ~H"""
    <nav class="join" aria-label={gettext("Period")}>
      <.link
        :for={key <- Period.presets()}
        patch={@path <> "?" <> URI.encode_query(Map.merge(Map.drop(@params, ["from", "to"]), %{"period" => key}))}
        class={["join-item btn btn-xs", @period.key == key && "btn-active"]}
        aria-current={@period.key == key && "true"}
      >
        {preset_label(key)}
      </.link>
      <span :if={@period.key == "custom"} class="join-item btn btn-xs btn-active no-animation">{gettext(
        "custom"
      )}</span>
    </nav>
    """
  end

  defp preset_label("all"), do: gettext("all")
  defp preset_label(key), do: key

  @doc "A KPI card with the change against the previous period."
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :previous, :any, default: nil
  attr :kind, :atom, default: :number, values: [:number, :duration, :decimal]
  attr :hint, :string, default: nil
  attr :id, :string, default: nil

  def kpi(assigns) do
    ~H"""
    <div id={@id} class="rounded-box border border-base-300 p-3">
      <div class="text-xs opacity-70" title={@hint}>{@label}</div>
      <div class="mt-1 text-xl font-semibold">
        <%= case @kind do %>
          <% :duration -> %>
            <.duration seconds={@value} />
          <% _ -> %>
            <.num value={@value} compact />
        <% end %>
      </div>
      <.change value={@value} previous={@previous} />
    </div>
    """
  end

  attr :value, :any
  attr :previous, :any

  defp change(assigns) do
    assigns = assign(assigns, :pct, pct_change(assigns.value, assigns.previous))

    ~H"""
    <div
      :if={@pct}
      class={["text-xs tabular-nums", @pct >= 0 && "text-success", @pct < 0 && "text-error"]}
    >
      {if @pct >= 0, do: "▲", else: "▼"} {:erlang.float_to_binary(abs(@pct), decimals: 1)}%
      <span class="opacity-60">{gettext("vs previous")}</span>
    </div>
    <div :if={!@pct} class="text-xs opacity-40">&nbsp;</div>
    """
  end

  defp pct_change(v, p) when is_number(v) and is_number(p) and p != 0, do: (v - p) / abs(p) * 100
  defp pct_change(%Decimal{} = v, p), do: pct_change(Decimal.to_float(v), p)
  defp pct_change(v, %Decimal{} = p), do: pct_change(v, Decimal.to_float(p))
  defp pct_change(_, _), do: nil

  @doc """
  A chart: a figure with a title, the chart hook, and buttons for the
  table view and a CSV download of the same data (§13.7).
  """
  attr :id, :string, required: true
  attr :kind, :string, required: true
  attr :src, :string, default: nil
  attr :values, :any, default: nil
  attr :opts, :map, default: %{}
  attr :title, :string, default: nil
  attr :class, :any, default: "h-64"
  attr :chatters_src, :string, default: nil
  slot :controls
  slot :note

  def chart(assigns) do
    ~H"""
    <figure class="rounded-box border border-base-300 p-3">
      <figcaption :if={@title || @controls != []} class="mb-2 flex flex-wrap items-center gap-2">
        <span class="font-medium">{@title}</span>
        <span class="flex-1"></span>
        {render_slot(@controls)}
        <button
          type="button"
          class="btn btn-ghost btn-xs"
          data-chart-action="table"
          aria-pressed="false"
        >
          {gettext("Table")}
        </button>
        <button type="button" class="btn btn-ghost btn-xs" data-chart-action="csv">CSV</button>
      </figcaption>
      <div
        id={@id}
        phx-hook="Chart"
        phx-update="ignore"
        data-kind={@kind}
        data-src={@src}
        data-values={@values && Jason.encode!(@values)}
        data-opts={Jason.encode!(@opts)}
        data-chatters-src={@chatters_src}
        data-filename={@id}
        class={["relative", @class]}
      >
      </div>
      <p :if={@note != []} class="mt-2 text-xs opacity-60">{render_slot(@note)}</p>
    </figure>
    """
  end

  @doc "How much of a period a source covered, with a link to what that means."
  attr :fraction, :float, required: true
  attr :label, :string, default: nil

  def coverage_badge(assigns) do
    ~H"""
    <.link
      navigate={~p"/about/methodology" <> "#coverage"}
      class={[
        "badge badge-sm tabular-nums",
        @fraction >= 0.98 && "badge-success badge-outline",
        @fraction < 0.98 && @fraction >= 0.9 && "badge-warning badge-outline",
        @fraction < 0.9 && "badge-error badge-outline"
      ]}
      title={gettext("Share of the period our collection was running")}
    >
      {@label || gettext("coverage")} {:erlang.float_to_binary(@fraction * 100, decimals: 1)}%
    </.link>
    """
  end

  @doc "Marks a figure as an estimate, linking to how it is made (§13.1)."
  def estimate(assigns) do
    ~H"""
    <.link
      navigate={~p"/about/methodology" <> "#estimates"}
      class="badge badge-ghost badge-xs"
      title={gettext("Modeled, not measured")}
    >
      {gettext("estimate")}
    </.link>
    """
  end

  def live_badge(assigns) do
    ~H"""
    <span class="badge badge-error badge-sm gap-1 font-medium">
      <span class="inline-block size-1.5 rounded-full bg-current motion-safe:animate-pulse"></span>{gettext(
        "LIVE"
      )}
    </span>
    """
  end
end
