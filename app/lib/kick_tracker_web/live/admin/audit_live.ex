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
    {:noreply, assign(socket, action: action, entries: Audit.recent(300, action: action))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_admin={@current_admin} active={:audit}>
      <div id="audit-page" phx-hook="Format">
        <.header>
          {gettext("Audit log")}
          <:subtitle :if={@action}>
            {@action} · <.link patch={~p"/admin/audit"} class="link">{gettext("all")}</.link>
          </:subtitle>
        </.header>
        <table id="audit" class="table table-xs">
          <thead>
            <tr>
              <th>{gettext("When")}</th><th>{gettext("Who")}</th><th>{gettext("Action")}</th><th>
                {gettext("Target")}
              </th><th>{gettext("Details")}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={e <- @entries}>
              <td class="whitespace-nowrap"><.time at={e.at} /></td>
              <td>{e.admin_email || gettext("command line")}</td>
              <td>
                <.link patch={~p"/admin/audit?action=#{e.action}"} class="link">{e.action}</.link>
              </td>
              <td>{e.target}</td>
              <td class="max-w-md truncate font-mono text-xs" title={Jason.encode!(e.details)}>
                {if e.details != %{}, do: Jason.encode!(e.details)}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.admin>
    """
  end
end
