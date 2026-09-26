defmodule KickTrackerWeb.Admin.AuditLive do
  @moduledoc "The audit log (project.md §13.8): every admin action, who and when."

  use KickTrackerWeb, :live_view

  alias KickTracker.Audit

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, page_title: gettext("Audit log"))}

  @impl true
  def handle_params(params, _uri, socket) do
    action = if params["action"] in [nil, ""], do: nil, else: params["action"]

    {:noreply,
     assign(socket,
       action: action,
       actions: Audit.actions(),
       entries: Audit.recent(300, action: action)
     )}
  end

  @impl true
  def handle_event("filter", %{"action" => action}, socket),
    do:
      {:noreply,
       push_patch(socket, to: ~p"/admin/audit?#{if action == "", do: [], else: [action: action]}")}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_admin={@current_admin} active={:audit}>
      <div id="audit-page" phx-hook="Format">
        <.page_header title={gettext("Audit log")} icon="hero-clipboard-document-list">
          <:subtitle>
            {gettext("Every admin action: who, when, and on what. The latest 300 are shown.")}
          </:subtitle>
          <:actions>
            <form id="audit-filter" phx-change="filter" class="flex items-center gap-2">
              <label class="sr-only" for="audit-action">{gettext("Action")}</label>
              <select id="audit-action" name="action" class="select select-sm w-60">
                <option value="">{gettext("All actions")}</option>
                <option :for={a <- @actions} value={a} selected={a == @action}>{a}</option>
              </select>
            </form>
          </:actions>
        </.page_header>

        <.panel flush>
          <div class="overflow-x-auto">
            <table id="audit" class="table table-sm">
              <thead>
                <tr>
                  <th>{gettext("When")}</th>
                  <th>{gettext("Who")}</th>
                  <th>{gettext("Action")}</th>
                  <th>{gettext("Target")}</th>
                  <th>{gettext("Details")}</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={e <- @entries}>
                  <td class="text-muted whitespace-nowrap text-xs"><.time at={e.at} /></td>
                  <td class="text-sm">
                    <span class="flex items-center gap-2">
                      <.avatar name={e.admin_email || "?"} class="size-6 text-[0.65rem]" />
                      <span class="truncate">{e.admin_email || gettext("command line")}</span>
                    </span>
                  </td>
                  <td>
                    <.link
                      patch={~p"/admin/audit?action=#{e.action}"}
                      title={gettext("Only this action")}
                    >
                      <.status_pill tone={action_tone(e.action)}>{e.action}</.status_pill>
                    </.link>
                  </td>
                  <td class="text-sm">{e.target}</td>
                  <td class="max-w-xl" title={if e.details != %{}, do: Jason.encode!(e.details)}>
                    <div class="flex flex-wrap gap-1">
                      <span
                        :for={{k, v} <- Enum.sort(e.details || %{})}
                        :if={v not in [nil, [], %{}]}
                        class="detail-chip"
                      >
                        <span class="text-muted">{k}</span> {detail(v)}
                      </span>
                    </div>
                  </td>
                </tr>
              </tbody>
            </table>
            <.empty_state
              :if={@entries == []}
              icon="hero-clipboard-document-list"
              title={gettext("Nothing logged yet.")}
            />
          </div>
        </.panel>
      </div>
    </Layouts.admin>
    """
  end

  # A detail's value, short: lists joined, anything nested as JSON, long
  # strings cut (the whole entry is on hover).
  defp detail(v) when is_list(v), do: v |> Enum.map_join(", ", &detail/1) |> cut()
  defp detail(v) when is_map(v), do: v |> Jason.encode!() |> cut()
  defp detail(v) when is_binary(v), do: cut(v)
  defp detail(v), do: to_string(v)

  defp cut(s) when byte_size(s) > 60, do: String.slice(s, 0, 57) <> "…"
  defp cut(s), do: s

  # Coloured by what the action touches.
  defp action_tone("privacy." <> _), do: :error
  defp action_tone("channel.delete" <> _), do: :error
  defp action_tone("chat_log." <> _), do: :warn
  defp action_tone("admin." <> _), do: :info
  defp action_tone(_), do: :neutral
end
