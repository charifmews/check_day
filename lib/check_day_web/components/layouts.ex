defmodule CheckDayWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use CheckDayWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_user, :map,
    default: nil,
    doc: "the currently authenticated user, if any"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header
      class="w-full px-6 sm:px-10 py-6 flex items-center justify-between relative z-50"
      id="main-header"
    >
      <a href="/" class="flex items-center gap-3 group" id="header-logo-link">
        <div class="relative flex items-center justify-center p-2 rounded-xl bg-white dark:bg-gray-900 border border-gray-200 dark:border-gray-800 shadow-sm group-hover:shadow-md transition-all duration-300 group-hover:border-[oklch(70%_0.213_47.604)]/30">
          <img
            src={~p"/images/logo.svg"}
            alt="Check.Day logo"
            class="w-7 h-7 transition-all duration-300 group-hover:scale-110"
          />
        </div>
        <span class="text-xl font-bold text-gray-900 dark:text-white tracking-tight">
          Check<span class="text-[oklch(70%_0.213_47.604)]">.</span>Day
        </span>
      </a>

      <div class="flex-none flex items-center gap-4">
        <.theme_toggle />

        <%= if @current_user do %>
          <a
            href="/dashboard"
            class={[
              "hidden sm:inline-flex items-center gap-2 px-5 py-2.5 rounded-full text-sm font-semibold",
              "text-gray-700 bg-white/50 dark:text-gray-200 dark:bg-gray-800/50 backdrop-blur-md",
              "border border-gray-200/50 dark:border-gray-700/50 shadow-sm",
              "hover:bg-white hover:border-gray-300 dark:hover:bg-gray-800 dark:hover:border-gray-600",
              "transition-all duration-300 hover:shadow-md hover:-translate-y-0.5"
            ]}
          >
            Dashboard
          </a>
          <a
            href="/sign-out"
            class={[
              "inline-flex items-center gap-1.5 px-5 py-2.5 rounded-full text-sm font-medium",
              "text-gray-600 border border-gray-200/80 bg-white/80 dark:bg-gray-800/80 dark:border-gray-700/80 dark:text-gray-300 backdrop-blur-md",
              "hover:bg-red-50 hover:border-red-200 hover:text-red-600 dark:hover:bg-red-950/30 dark:hover:border-red-800 dark:hover:text-red-400",
              "transition-all duration-300 hover:shadow-sm hover:-translate-y-0.5"
            ]}
            id="header-sign-out"
          >
            <.icon name="hero-arrow-right-start-on-rectangle-mini" class="w-4 h-4" /> Sign out
          </a>
        <% else %>
          <a
            href="/sign-in"
            class={[
              "inline-flex items-center gap-2 px-6 py-2.5 rounded-full text-sm font-semibold",
              "text-gray-700 bg-white/80 dark:text-gray-200 dark:bg-gray-800/80 backdrop-blur-md",
              "border border-gray-200/50 dark:border-gray-700/50 shadow-sm",
              "hover:bg-gray-50 hover:border-gray-300 dark:hover:bg-gray-700 dark:hover:border-gray-600",
              "transition-all duration-300 hover:shadow-md hover:-translate-y-0.5"
            ]}
            id="header-sign-in"
          >
            Sign in
          </a>
        <% end %>
      </div>
    </header>

    <main class="flex-1 w-full max-w-[1600px] mx-auto relative z-10 px-4 sm:px-6 lg:px-10 pb-16">
      {render_slot(@inner_block)}
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme-mode=light]_&]:left-1/3 [[data-theme-mode=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
