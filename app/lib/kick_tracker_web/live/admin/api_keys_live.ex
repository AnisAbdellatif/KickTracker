defmodule KickTrackerWeb.Admin.ApiKeysLive do
  @moduledoc """
  Keys to the public read API (project.md §13.10): issued here by hand,
  each with the channels and kinds of data it reaches and its limits. A
  key is shown once, when it is created; after that only its first
  characters. Editing a key changes what it reaches, not the key.
  """

  use KickTrackerWeb, :live_view

  alias KickTracker.{ApiKeys, Audit, Channels, Groups}
  alias KickTracker.ApiKeys.Access

  @resolutions [{"raw", "1 min"}, {"5m", "5 min"}, {"15m", "15 min"}, {"1h", "1 h"}] ++
                 [{"6h", "6 h"}, {"1d", "1 day"}, {"1w", "1 week"}]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: gettext("API keys"),
       channels: Channels.list_all() |> Enum.sort_by(& &1.slug),
       groups: Groups.list(),
       editing: nil,
       form: nil,
       created: nil,
       channel_q: ""
     )
     |> load()}
  end

  defp load(socket), do: assign(socket, keys: ApiKeys.list())

  @impl true
  def handle_event("new", _params, socket),
    do: {:noreply, edit(socket, :new, ApiKeys.change())}

  def handle_event("edit", %{"id" => id}, socket) do
    key = ApiKeys.get!(String.to_integer(id))
    {:noreply, edit(socket, key.id, ApiKeys.change(key))}
  end

  def handle_event("cancel", _params, socket),
    do: {:noreply, assign(socket, editing: nil, form: nil)}

  def handle_event("validate", %{"api_key" => params} = all, socket) do
    changeset =
      socket
      |> editing_key()
      |> ApiKeys.change(normalize(params))
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset), channel_q: all["channel_q"] || "")}
  end

  def handle_event("save", %{"api_key" => params}, socket) do
    admin = socket.assigns.current_admin
    attrs = normalize(params)

    result =
      case socket.assigns.editing do
        :new -> ApiKeys.create(admin, attrs)
        _id -> ApiKeys.update(editing_key(socket), attrs)
      end

    case result do
      {:ok, key, raw} ->
        Audit.log(admin, "api_key.create", key.name, summary(key))

        {:noreply,
         socket
         |> assign(editing: nil, form: nil, created: %{name: key.name, key: raw})
         |> load()}

      {:ok, key} ->
        Audit.log(admin, "api_key.update", key.name, summary(key))
        {:noreply, socket |> assign(editing: nil, form: nil) |> load()}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(Map.put(changeset, :action, :insert)))}
    end
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    key = ApiKeys.get!(String.to_integer(id))
    {:ok, key} = ApiKeys.revoke(key)
    Audit.log(socket.assigns.current_admin, "api_key.revoke", key.name, %{"id" => key.id})
    {:noreply, load(socket)}
  end

  def handle_event("dismiss", _params, socket), do: {:noreply, assign(socket, created: nil)}

  defp edit(socket, editing, changeset),
    do: assign(socket, editing: editing, form: to_form(changeset), created: nil, channel_q: "")

  defp editing_key(%{assigns: %{editing: :new}}), do: %KickTracker.ApiKeys.ApiKey{}
  defp editing_key(%{assigns: %{editing: id}}), do: ApiKeys.get!(id)

  # Checkbox lists arrive with a blank entry (so none ticked still sends
  # the field); addresses come one per line.
  defp normalize(params) do
    list = fn field -> params |> Map.get(field, []) |> List.wrap() |> Enum.reject(&(&1 == "")) end

    params
    |> Map.merge(%{
      "admin" => params["admin"] == "true",
      "per_address" => params["per_address"] == "true",
      "all_channels" => params["all_channels"] != "false",
      "scopes" => list.("scopes"),
      "channel_ids" => list.("channel_ids"),
      "group_ids" => list.("group_ids"),
      "allowed_cidrs" => String.split(params["allowed_cidrs"] || "", ~r/[\s,]+/, trim: true),
      "expires_at" => expiry(params["expires_at"])
    })
  end

  # A date: the key works until the end of that day, UTC.
  defp expiry(date) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, d} -> DateTime.new!(Date.add(d, 1), ~T[00:00:00], "Etc/UTC")
      _ -> nil
    end
  end

  defp expiry(_), do: nil

  defp summary(key),
    do: %{
      "id" => key.id,
      "admin" => key.admin,
      "all_channels" => key.all_channels,
      "channel_ids" => key.channel_ids,
      "group_ids" => key.group_ids,
      "scopes" => key.scopes,
      "rate_limit" => key.rate_limit,
      "per_address" => key.per_address,
      "history_days" => key.history_days,
      "min_res" => key.min_res,
      "allowed_cidrs" => key.allowed_cidrs,
      "expires_at" => key.expires_at && DateTime.to_iso8601(key.expires_at)
    }

  ## Render

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} current_admin={@current_admin} active={:api_keys}>
      <.page_header title={gettext("API keys")} icon="hero-key">
        <:subtitle>
          {gettext(
            "Keys to the read API (/api/v1) for other applications. Each key reaches the channels and kinds of data you choose; send it to its holder yourself, with API.md."
          )}
        </:subtitle>
        <:actions>
          <button :if={!@form} id="new-key" phx-click="new" class="btn btn-primary btn-sm gap-1">
            <.icon name="hero-plus" class="size-4" />{gettext("New key")}
          </button>
        </:actions>
      </.page_header>

      <div
        :if={@created}
        id="created-key"
        role="alert"
        class="mb-6 space-y-2 rounded-box border border-warning/50 bg-warning/10 p-4 text-sm"
      >
        <p class="flex items-center gap-2 font-medium">
          <.icon name="hero-exclamation-triangle" class="size-4 text-warning" />
          {gettext("The key for %{name}. Copy it now: it won't be shown again.",
            name: @created.name
          )}
        </p>
        <input
          value={@created.key}
          readonly
          class="input input-sm w-full font-mono"
          aria-label={gettext("API key")}
        />
        <button phx-click="dismiss" class="btn btn-sm">{gettext("Done")}</button>
      </div>

      <.panel
        :if={@form}
        id="key-form-panel"
        title={if @editing == :new, do: gettext("New key"), else: gettext("Edit key")}
        icon="hero-key"
        class="mb-6"
      >
        {key_form(assigns)}
      </.panel>

      <.panel title={gettext("Keys")} icon="hero-key" flush>
        <div class="overflow-x-auto">
          <table id="api-keys" class="table table-sm">
            <thead>
              <tr>
                <th>{gettext("Name")}</th>
                <th>{gettext("Key")}</th>
                <th>{gettext("Reaches")}</th>
                <th>{gettext("Limits")}</th>
                <th>{gettext("Last used")}</th>
                <th>{gettext("Status")}</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={k <- @keys} id={"api-key-#{k.id}"} class={!ApiKeys.usable?(k) && "opacity-60"}>
                <td>
                  <p class="font-medium">{k.name}</p>
                  <p :if={k.contact} class="text-muted text-xs">{k.contact}</p>
                </td>
                <td class="font-mono text-xs">{k.prefix}…</td>
                <td class="text-sm">
                  <%= if k.admin do %>
                    <.status_pill tone={:warn}>{gettext("admin key: everything")}</.status_pill>
                  <% else %>
                    <p>{channels_summary(k, @channels, @groups)}</p>
                    <p class="text-muted text-xs">{Enum.join(k.scopes, ", ")}</p>
                  <% end %>
                </td>
                <td class="text-muted text-xs">
                  <p>
                    {if k.per_address,
                      do: gettext("%{n}/min per address", n: k.rate_limit),
                      else: gettext("%{n}/min", n: k.rate_limit)}
                  </p>
                  <p :if={k.history_days}>{gettext("last %{n} days", n: k.history_days)}</p>
                  <p :if={k.min_res}>{gettext("resolution ≥ %{res}", res: k.min_res)}</p>
                  <p :if={k.allowed_cidrs != []}>{Enum.join(k.allowed_cidrs, ", ")}</p>
                </td>
                <td class="text-sm tabular-nums">
                  {if k.last_used_at,
                    do: Calendar.strftime(k.last_used_at, "%Y-%m-%d %H:%M"),
                    else: "–"}
                </td>
                <td>
                  <.status_pill tone={status_tone(k)}>{status(k)}</.status_pill>
                  <p :if={k.expires_at && !k.revoked_at} class="text-muted mt-1 text-xs">
                    {gettext("until %{date}",
                      date: Calendar.strftime(DateTime.add(k.expires_at, -1), "%Y-%m-%d")
                    )}
                  </p>
                </td>
                <td>
                  <div :if={!k.revoked_at} class="flex justify-end gap-0.5">
                    <.icon_button
                      id={"edit-key-#{k.id}"}
                      icon="hero-pencil-square"
                      label={gettext("Edit")}
                      phx-click="edit"
                      phx-value-id={k.id}
                    />
                    <.icon_button
                      id={"revoke-key-#{k.id}"}
                      icon="hero-no-symbol"
                      label={gettext("Revoke")}
                      tone={:danger}
                      phx-click="revoke"
                      phx-value-id={k.id}
                      data-confirm={
                        gettext("Revoke the key for %{name}? It stops working within 30 seconds.",
                          name: k.name
                        )
                      }
                    />
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
          <.empty_state :if={@keys == []} icon="hero-key" title={gettext("No keys yet.")}>
            {gettext("Create one for each application that reads our data.")}
          </.empty_state>
        </div>
      </.panel>
    </Layouts.admin>
    """
  end

  defp key_form(assigns) do
    assigns =
      assign(assigns,
        admin?: assigns.form[:admin].value in [true, "true"],
        all?: assigns.form[:all_channels].value not in [false, "false"],
        scopes: Enum.map(assigns.form[:scopes].value || [], &to_string/1),
        channel_ids: ids(assigns.form[:channel_ids].value),
        group_ids: ids(assigns.form[:group_ids].value),
        resolutions: @resolutions
      )

    ~H"""
    <.form for={@form} id="key-form" phx-change="validate" phx-submit="save" class="space-y-5">
      <div class="grid gap-3 sm:grid-cols-2">
        <.input
          field={@form[:name]}
          label={gettext("Name")}
          placeholder={gettext("Who or what it's for")}
        />
        <.input field={@form[:contact]} label={gettext("Contact (optional)")} />
      </div>

      <label class="flex items-center gap-2 text-sm">
        <input type="hidden" name="api_key[admin]" value="false" />
        <input
          type="checkbox"
          name="api_key[admin]"
          value="true"
          checked={@admin?}
          class="toggle toggle-sm toggle-warning"
        />
        {gettext("Admin key")}
      </label>
      <div :if={@admin?} id="admin-key-warning" class="alert alert-warning text-sm">
        {gettext(
          "An admin key reaches every channel, hidden ones included, and every kind of data, logged chat included. Keep it to people you would make admins, and limit the addresses it works from."
        )}
      </div>

      <fieldset :if={!@admin?} class="space-y-2">
        <legend class="text-sm font-medium">{gettext("Channels")}</legend>
        <div class="flex flex-wrap gap-4 text-sm">
          <label class="flex items-center gap-2">
            <input
              type="radio"
              name="api_key[all_channels]"
              value="true"
              checked={@all?}
              class="radio radio-xs radio-primary"
            />
            {gettext("Every channel, now and later")}
          </label>
          <label class="flex items-center gap-2">
            <input
              type="radio"
              name="api_key[all_channels]"
              value="false"
              checked={!@all?}
              class="radio radio-xs radio-primary"
            />
            {gettext("Only these")}
          </label>
        </div>
        <p class="text-muted text-xs">
          {gettext(
            "Hidden channels are never reached by a regular key; channels shown only while live, only through \"live\"."
          )}
        </p>
        <div :if={!@all?} id="key-channels" class="space-y-2">
          <input type="hidden" name="api_key[group_ids][]" value="" />
          <input type="hidden" name="api_key[channel_ids][]" value="" />
          <div :if={@groups != []} class="flex flex-wrap gap-3 text-sm">
            <label :for={g <- @groups} class="flex items-center gap-2">
              <input
                type="checkbox"
                name="api_key[group_ids][]"
                value={g.id}
                checked={g.id in @group_ids}
                class="checkbox checkbox-xs checkbox-primary"
              />
              {gettext("group")} {g.name}
            </label>
          </div>
          <label class="input input-sm w-full sm:w-64">
            <.icon name="hero-magnifying-glass" class="text-muted size-4" />
            <input
              type="search"
              name="channel_q"
              value={@channel_q}
              placeholder={gettext("Search channels")}
              phx-debounce="150"
              autocomplete="off"
            />
          </label>
          <div class="scroll-panel inset-well max-h-60 overflow-y-auto p-2">
            <div class="grid grid-cols-1 gap-0.5 sm:grid-cols-2 lg:grid-cols-3">
              <label
                :for={c <- @channels}
                class={[
                  "flex cursor-pointer items-center gap-2 rounded-[var(--radius-field)] px-2 py-1 text-sm hover:bg-[var(--surface-hover)]",
                  !matches?(c, @channel_q) && "hidden"
                ]}
              >
                <input
                  type="checkbox"
                  name="api_key[channel_ids][]"
                  value={c.id}
                  checked={c.id in @channel_ids}
                  class="checkbox checkbox-xs checkbox-primary"
                />
                <span class="truncate">{c.slug}</span>
                <span :if={c.visibility != :public} class="text-muted text-xs">
                  {visibility_label(c.visibility)}
                </span>
              </label>
            </div>
          </div>
        </div>
      </fieldset>

      <fieldset :if={!@admin?} class="space-y-2">
        <legend class="text-sm font-medium">{gettext("Data")}</legend>
        <input type="hidden" name="api_key[scopes][]" value="" />
        <div class="flex flex-wrap gap-x-4 gap-y-2 text-sm">
          <label :for={s <- Access.scopes()} class="flex items-center gap-2" title={scope_hint(s)}>
            <input
              type="checkbox"
              name="api_key[scopes][]"
              value={s}
              checked={s in @scopes}
              class="checkbox checkbox-xs checkbox-primary"
            />
            {s}
          </label>
        </div>
        <p :for={e <- @form[:scopes].errors} class="text-error text-sm">{translate_error(e)}</p>
      </fieldset>

      <fieldset class="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <legend class="mb-2 text-sm font-medium">{gettext("Limits")}</legend>
        <.input field={@form[:rate_limit]} type="number" label={gettext("Requests a minute")} />
        <.input
          field={@form[:history_days]}
          type="number"
          label={gettext("Days back (empty: all)")}
        />
        <.input
          field={@form[:min_res]}
          type="select"
          label={gettext("Finest resolution")}
          prompt={gettext("Any")}
          options={Enum.map(@resolutions, fn {v, l} -> {l, v} end)}
        />
        <.input
          name="api_key[expires_at]"
          type="date"
          label={gettext("Works until (empty: no end)")}
          value={expiry_date(@form[:expires_at].value)}
        />
      </fieldset>
      <label class="flex items-center gap-2 text-sm">
        <input type="hidden" name="api_key[per_address]" value="false" />
        <input
          type="checkbox"
          name="api_key[per_address]"
          value="true"
          checked={@form[:per_address].value in [true, "true"]}
          class="checkbox checkbox-xs checkbox-primary"
        />
        {gettext(
          "Shared key: count the limit per address (for a key many people use, such as one built into an app)"
        )}
      </label>
      <.input
        name="api_key[allowed_cidrs]"
        type="textarea"
        label={gettext("Only from these addresses (one address or CIDR a line; empty: anywhere)")}
        value={Enum.join(@form[:allowed_cidrs].value || [], "\n")}
        errors={Enum.map(@form[:allowed_cidrs].errors, &translate_error/1)}
      />

      <div class="flex justify-end gap-2">
        <button type="button" phx-click="cancel" class="btn btn-ghost btn-sm">{gettext("Cancel")}</button>
        <button class="btn btn-primary btn-sm">
          {if @editing == :new, do: gettext("Create key"), else: gettext("Save")}
        </button>
      </div>
    </.form>
    """
  end

  defp ids(values),
    do: values |> List.wrap() |> Enum.reject(&(&1 in [nil, ""])) |> Enum.map(&to_int/1)

  defp to_int(v) when is_integer(v), do: v
  defp to_int(v), do: String.to_integer(v)

  defp expiry_date(%DateTime{} = at),
    do: at |> DateTime.add(-1) |> DateTime.to_date() |> Date.to_iso8601()

  defp expiry_date(_), do: nil

  defp matches?(_channel, q) when q in [nil, ""], do: true

  defp matches?(channel, q),
    do: String.contains?(String.downcase(channel.slug), String.downcase(String.trim(q)))

  defp visibility_label(:live_only), do: gettext("live only")
  defp visibility_label(:hidden), do: gettext("hidden")

  defp scope_hint("channels"), do: gettext("The list of channels and their streams")
  defp scope_hint("live"), do: gettext("Who is live now: viewers and active chatters")
  defp scope_hint("viewers"), do: gettext("Viewers over time, and the weekday × hour heatmap")
  defp scope_hint("chat"), do: gettext("Messages and chatters over time")
  defp scope_hint("followers"), do: gettext("Follower totals over time")
  defp scope_hint("support"), do: gettext("Subs, gifted subs and Kicks")
  defp scope_hint("categories"), do: gettext("Hours watched per category")

  defp channels_summary(%{all_channels: true}, _channels, _groups), do: gettext("every channel")

  defp channels_summary(key, channels, groups) do
    names =
      Enum.flat_map(
        groups,
        &if(&1.id in key.group_ids, do: [gettext("group") <> " " <> &1.name], else: [])
      ) ++
        Enum.flat_map(channels, &if(&1.id in key.channel_ids, do: [&1.slug], else: []))

    case names do
      [] ->
        gettext("no channel")

      names when length(names) <= 4 ->
        Enum.join(names, ", ")

      names ->
        Enum.join(Enum.take(names, 3), ", ") <>
          " " <> gettext("and %{n} more", n: length(names) - 3)
    end
  end

  defp status(k) do
    cond do
      k.revoked_at -> gettext("revoked")
      !ApiKeys.usable?(k) -> gettext("expired")
      true -> gettext("active")
    end
  end

  defp status_tone(k) do
    cond do
      k.revoked_at -> :neutral
      !ApiKeys.usable?(k) -> :warn
      true -> :ok
    end
  end
end
