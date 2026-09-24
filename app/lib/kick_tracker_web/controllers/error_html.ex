defmodule KickTrackerWeb.ErrorHTML do
  @moduledoc """
  Error pages for HTML requests (see `render_errors` in config/config.exs):
  the site's own layout, a short explanation in the visitor's language
  and a way back to the home page. Nothing here reads the database, so a
  page still renders when the error came from it.
  """
  use KickTrackerWeb, :html

  alias KickTrackerWeb.Layouts

  def render(template, assigns) do
    status = template |> String.split(".") |> hd()
    {title, text} = message(status)

    assigns =
      assigns
      |> Map.new()
      |> Map.merge(%{status: status, title: title, text: text, page_title: title})

    Layouts.root(Map.put(assigns, :inner_content, page(assigns)))
  end

  defp message("404"),
    do:
      {gettext("Page not found"),
       gettext(
         "There is nothing here: the channel, stream or page may not exist, or not any more."
       )}

  defp message("500"),
    do:
      {gettext("Something went wrong"),
       gettext("We couldn't show this page. Please try again in a moment.")}

  defp message(status) do
    title =
      case Integer.parse(status) do
        {code, ""} -> Plug.Conn.Status.reason_phrase(code)
        _ -> gettext("Error")
      end

    {title, gettext("We couldn't show this page.")}
  rescue
    ArgumentError -> {gettext("Error"), gettext("We couldn't show this page.")}
  end

  defp page(assigns) do
    ~H"""
    <Layouts.app flash={%{}}>
      <section id="error-page" class="card-surface mx-auto max-w-lg p-8 text-center">
        <p class="text-sm font-semibold tabular-nums text-base-content/70">{@status}</p>
        <h1 class="mt-2 text-2xl font-semibold tracking-tight">{@title}</h1>
        <p class="mt-3 text-sm text-base-content/70">{@text}</p>
        <.link navigate={~p"/"} class="btn btn-primary btn-sm mt-6">
          {gettext("Back to the home page")}
        </.link>
      </section>
    </Layouts.app>
    """
  end
end
