defmodule KickTrackerWeb.SiteComponents do
  @moduledoc """
  Pieces shared by the public pages (project.md §13): the period picker,
  KPI cards, the chart figure, numbers and times formatted in the
  visitor's locale and timezone (§13.6), coverage and estimate labels.
  """

  use Phoenix.Component
  import KickTrackerWeb.CoreComponents, only: [icon: 1]
  use Gettext, backend: KickTrackerWeb.Gettext

  use Phoenix.VerifiedRoutes,
    endpoint: KickTrackerWeb.Endpoint,
    router: KickTrackerWeb.Router,
    statics: KickTrackerWeb.static_paths()

  alias KickTrackerWeb.Period
  alias Phoenix.LiveView.JS

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
  defp to_num(v) when is_float(v) and abs(v) >= 10, do: round(v)
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

  @doc """
  The period picker; keeps the other query params. "custom" opens two
  date inputs (days in `tz`, the channel's timezone on a channel's pages)
  that the page turns into `from`/`to` with a `"custom_range"` event
  (`KickTrackerWeb.PageParams.custom_range/3`).
  """
  attr :period, Period, required: true
  attr :path, :string, required: true
  attr :params, :map, default: %{}
  attr :tz, :string, default: "Etc/UTC"

  def period_picker(assigns) do
    custom? = assigns.period.key == "custom"

    {from, to} =
      if custom?,
        do: KickTrackerWeb.PageParams.dates(assigns.period, assigns.tz),
        else: {nil, nil}

    assigns = assign(assigns, custom?: custom?, from: from, to: to)

    ~H"""
    <div class="flex flex-wrap items-center gap-2">
      <nav class="segmented" aria-label={gettext("Period")}>
        <.link
          :for={key <- Period.presets()}
          patch={@path <> "?" <> URI.encode_query(Map.merge(Map.drop(@params, ["from", "to"]), %{"period" => key}))}
          class={["segmented-item", @period.key == key && "is-active"]}
          aria-current={@period.key == key && "true"}
        >
          {preset_label(key)}
        </.link>
        <button
          id="custom-range-toggle"
          type="button"
          class={["segmented-item", @custom? && "is-active"]}
          aria-controls="custom-range"
          aria-expanded={to_string(@custom?)}
          phx-click={
            JS.toggle(to: "#custom-range", display: "flex")
            |> JS.toggle_attribute({"aria-expanded", "true", "false"})
          }
        >
          {gettext("custom")}
        </button>
      </nav>
      <form
        id="custom-range"
        phx-submit="custom_range"
        class={["items-center gap-1.5 text-xs", if(@custom?, do: "flex", else: "hidden")]}
        title={gettext("Days in %{tz} time", tz: @tz)}
      >
        <input
          type="date"
          name="from"
          value={@from}
          required
          class="input input-xs w-36"
          aria-label={gettext("First day")}
        />
        <span aria-hidden="true">–</span>
        <input
          type="date"
          name="to"
          value={@to}
          required
          class="input input-xs w-36"
          aria-label={gettext("Last day")}
        />
        <button class="btn btn-xs">{gettext("Apply")}</button>
      </form>
    </div>
    """
  end

  defp preset_label("all"), do: gettext("all")
  defp preset_label(key), do: key

  @doc "What a raid or host event is called (`channel_events.kind`, project.md §12.5)."
  def event_label("raid_in"), do: gettext("Raid in")
  def event_label("raid_out"), do: gettext("Raid out")
  def event_label("host"), do: gettext("Host")
  def event_label("host_in"), do: gettext("Hosted by")
  def event_label("host_out"), do: gettext("Hosting")
  def event_label(_), do: gettext("Event")

  @doc "Labels for every event kind, for charts that name them (§13.6)."
  def event_labels,
    do: Map.new(~w(raid_in raid_out host host_in host_out), &{&1, event_label(&1)})

  @doc """
  The sum of figures that may be unknown (`nil`): unknown if any part is,
  never a partial sum passed off as the whole (webhook counts are `nil`
  where we weren't receiving events).

      iex> KickTrackerWeb.SiteComponents.known_sum([1, 2, 3])
      6
      iex> KickTrackerWeb.SiteComponents.known_sum([1, nil, 3])
      nil
      iex> KickTrackerWeb.SiteComponents.known_sum([])
      0
  """
  @spec known_sum([number() | nil]) :: number() | nil
  def known_sum(values) do
    if Enum.any?(values, &is_nil/1), do: nil, else: Enum.sum(values)
  end

  @metrics ~w(hw avg peak airtime followers chat subs)a

  @doc """
  The site's metrics, each with one hue and one icon used wherever it
  appears: stat cards, chart headers, bars and lines (project.md §13.7).
  """
  def metrics, do: @metrics

  @doc "A metric's Heroicon."
  def metric_icon(:hw), do: "hero-clock"
  def metric_icon(:avg), do: "hero-eye"
  def metric_icon(:peak), do: "hero-arrow-trending-up"
  def metric_icon(:airtime), do: "hero-signal"
  def metric_icon(:followers), do: "hero-heart"
  def metric_icon(:chat), do: "hero-chat-bubble-left-right"
  def metric_icon(:subs), do: "hero-gift"

  @doc "A metric's icon on its soft ground; neutral with no metric."
  attr :metric, :atom, default: nil, values: [nil | @metrics]
  attr :icon, :string, default: nil, doc: "overrides the metric's icon"
  attr :size, :atom, default: :md, values: [:sm, :md]

  def icon_tile(assigns) do
    ~H"""
    <span
      class={["icon-tile", @metric && "m-#{@metric}", @size == :sm && "is-sm"]}
      aria-hidden="true"
    >
      <.icon
        name={@icon || metric_icon(@metric || :hw)}
        class={if @size == :sm, do: "size-4", else: "size-5"}
      />
    </span>
    """
  end

  @doc "A KPI card with the change against the previous period."
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :previous, :any, default: nil
  attr :kind, :atom, default: :number, values: [:number, :duration, :decimal]
  attr :metric, :atom, default: nil, values: [nil | @metrics]
  attr :icon, :string, default: nil, doc: "an icon for a card with no metric"
  attr :hint, :string, default: nil
  attr :id, :string, default: nil
  attr :note, :string, default: nil, doc: "a qualifier shown under the value (e.g. since when)"
  slot :badge, doc: "shown after the label (e.g. the estimate pill)"

  def kpi(assigns) do
    ~H"""
    <div id={@id} class={["card-surface stat-card p-4 sm:px-5", @metric && "m-#{@metric}"]}>
      <div class="flex items-center gap-2">
        <.icon_tile :if={@metric || @icon} metric={@metric} icon={@icon} size={:sm} />
        <span class="truncate text-[0.8125rem] font-medium text-muted" title={@hint || @label}>
          {@label}
        </span>
        {render_slot(@badge)}
      </div>
      <div class={[
        "mt-3 text-2xl font-bold tracking-tight tabular-nums sm:text-[1.75rem] sm:leading-8",
        is_nil(@value) && "text-subtle"
      ]}>
        <%= case @kind do %>
          <% :duration -> %>
            <.duration seconds={@value} />
          <% _ -> %>
            <.num value={@value} compact />
        <% end %>
      </div>
      <div :if={@note} class="mt-2 text-xs text-muted">{@note}</div>
      <.change :if={!@note} value={@value} previous={@previous} />
    </div>
    """
  end

  attr :value, :any
  attr :previous, :any

  defp change(assigns) do
    pct = pct_change(assigns.value, assigns.previous)

    dir =
      cond do
        is_nil(pct) -> nil
        abs(pct) < 0.05 -> :flat
        pct > 0 -> :up
        true -> :down
      end

    assigns = assign(assigns, pct: pct, dir: dir)

    ~H"""
    <div
      :if={@dir}
      class="mt-2 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs"
      title={gettext("Change against the previous period of the same length")}
    >
      <span class={["delta", "is-#{@dir}"]}>
        <.icon :if={@dir == :up} name="hero-arrow-trending-up-micro" class="size-3.5" />
        <.icon :if={@dir == :down} name="hero-arrow-trending-down-micro" class="size-3.5" />
        <.icon :if={@dir == :flat} name="hero-minus-micro" class="size-3.5" />
        <span :if={@dir != :flat}>{:erlang.float_to_binary(abs(@pct), decimals: 1)}%</span>
        <span :if={@dir == :flat}>{gettext("no change")}</span>
      </span>
      <span class="hidden whitespace-nowrap text-subtle sm:inline">{gettext("vs previous")}</span>
    </div>
    <div :if={!@dir and !is_nil(@previous)} class="mt-2 h-5"></div>
    """
  end

  defp pct_change(v, p) when is_number(v) and is_number(p) and p != 0, do: (v - p) / abs(p) * 100
  defp pct_change(%Decimal{} = v, p), do: pct_change(Decimal.to_float(v), p)
  defp pct_change(v, %Decimal{} = p), do: pct_change(v, Decimal.to_float(p))
  defp pct_change(_, _), do: nil

  @doc """
  A chart: a figure with a title, the chart hook, and buttons for the
  table view and a CSV download of the same data (§13.7), and, on time
  charts, one that zooms back out to all the data.
  """
  attr :id, :string, required: true
  attr :kind, :string, required: true
  attr :src, :string, default: nil
  attr :values, :any, default: nil
  attr :opts, :map, default: %{}
  attr :title, :string, default: nil
  attr :class, :any, default: "h-64"
  attr :chatters_src, :string, default: nil
  attr :metric, :atom, default: nil, values: [nil | @metrics], doc: "the header's icon tile"
  attr :icon, :string, default: nil, doc: "a header icon for a chart of no one metric"

  attr :refresh, :integer,
    default: nil,
    doc: "seconds between fetches of `src`, for a range that ends now"

  slot :controls
  slot :note

  def chart(assigns) do
    ~H"""
    <figure class="card-surface p-4 sm:p-5">
      <figcaption class="mb-3 flex flex-wrap items-center gap-x-3 gap-y-2">
        <.icon_tile :if={@metric || @icon} metric={@metric} icon={@icon} />
        <span :if={@title} class="text-[0.9375rem] font-semibold leading-5">{@title}</span>
        <span class="flex-1"></span>
        {render_slot(@controls)}
        <div class="flex items-center">
          <button
            :if={@kind in ~w(timeseries bars stream)}
            type="button"
            class="btn btn-ghost btn-xs btn-square"
            data-chart-action="fit"
            aria-label={gettext("Show all the data (or double-click the chart)")}
            title={gettext("Show all the data (or double-click the chart)")}
          >
            <.icon name="hero-arrows-pointing-out-micro" class="size-4" />
          </button>
          <button
            type="button"
            class="btn btn-ghost btn-xs btn-square"
            data-chart-action="table"
            aria-pressed="false"
            aria-label={gettext("Show as a table")}
            title={gettext("Show as a table")}
          >
            <.icon name="hero-table-cells-micro" class="size-4" />
          </button>
          <button
            type="button"
            class="btn btn-ghost btn-xs btn-square"
            data-chart-action="csv"
            aria-label={gettext("Download CSV")}
            title={gettext("Download CSV")}
          >
            <.icon name="hero-arrow-down-tray-micro" class="size-4" />
          </button>
        </div>
      </figcaption>
      <div class="inset-well p-2 sm:p-3">
        <div
          id={@id}
          phx-hook="Chart"
          phx-update="ignore"
          data-kind={@kind}
          data-src={@src}
          data-values={@values && Jason.encode!(@values)}
          data-opts={Jason.encode!(@opts)}
          data-chatters-src={@chatters_src}
          data-refresh={@refresh}
          data-filename={@id}
          data-error={gettext("Couldn't load this chart.")}
          class={["relative", @class]}
        >
        </div>
      </div>
      <p :if={@note != []} class="mt-3 text-xs text-base-content/70">{render_slot(@note)}</p>
      <p data-chart-note class="mt-2 text-xs text-base-content/70" hidden></p>
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
    <span class="live-pill">
      <span class="inline-block size-1.5 rounded-full bg-current motion-safe:animate-pulse"></span>{gettext(
        "LIVE"
      )}
    </span>
    """
  end

  @doc """
  An avatar. Given a `channel_id`, the channel's picture where we hold a
  copy of it (§12.9, served from our own domain; Kick is never contacted
  by the browser). Otherwise, or for a person, the name's initial on one
  of the seven metric hues, picked from the name.
  """
  attr :name, :string, required: true
  attr :channel_id, :integer, default: nil
  attr :class, :any, default: "size-10 text-base"

  def avatar(assigns) do
    version = assigns.channel_id && Map.get(KickTracker.Avatars.versions(), assigns.channel_id)
    assigns = assign(assigns, hue: :erlang.phash2(assigns.name, 7) + 1, version: version)

    ~H"""
    <span
      class={[
        "avatar-initial inline-flex shrink-0 items-center justify-center overflow-hidden rounded-full font-semibold uppercase",
        "avatar-#{@hue}",
        @class
      ]}
      aria-hidden="true"
    >
      <img
        :if={@version}
        src={~p"/img/channels/#{@channel_id}/avatar?#{[v: @version]}"}
        alt=""
        loading="lazy"
        decoding="async"
        class="size-full object-cover"
      />
      <%= if !@version do %>
        {String.first(@name || "?")}
      <% end %>
    </span>
    """
  end

  @doc "Tabs as links (underline style); each tab is `{key, label, path}`."
  attr :tabs, :list, required: true
  attr :active, :any, required: true
  attr :id, :string, default: nil
  attr :class, :any, default: nil

  def tabs(assigns) do
    ~H"""
    <nav id={@id} class={["no-scrollbar flex gap-5 overflow-x-auto border-b border-base-300", @class]}>
      <.link
        :for={{key, label, path} <- @tabs}
        patch={path}
        aria-current={@active == key && "page"}
        class={[
          "-mb-px shrink-0 border-b-2 py-2.5 text-sm font-semibold transition-colors",
          if(@active == key,
            do: "border-primary text-primary",
            else: "border-transparent text-muted hover:text-base-content"
          )
        ]}
      >
        {label}
      </.link>
    </nav>
    """
  end
end
