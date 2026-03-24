defmodule CheckDayWeb.MagicSignInLive do
  @moduledoc """
  Custom branded magic link confirmation page.
  Auto-submits the sign-in form after a brief moment.
  """
  use CheckDayWeb, :live_view

  @impl true
  def mount(_params, session, socket) do
    resource = session["resource"]
    strategy_name = session["strategy"]

    strategy = AshAuthentication.Info.strategy!(resource, strategy_name)

    socket =
      socket
      |> assign(:strategy, strategy)
      |> assign(:resource, resource)
      |> assign(:auth_routes_prefix, session["auth_routes_prefix"])
      |> assign(:current_tenant, session["tenant"])
      |> assign(:context, session["context"] || %{})
      |> assign(:trigger_action, false)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    token = params["token"] || params["magic_link"]
    {:noreply, assign(socket, :token, token)}
  end

  @impl true
  def handle_event("submit", _params, socket) do
    {:noreply, assign(socket, :trigger_action, true)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex items-center justify-center min-h-[70vh]">
      <div class="w-full max-w-md mx-auto text-center animate-[fadeIn_0.4s_ease-out]">
        <%!-- Card --%>
        <div class={[
          "rounded-3xl border p-8 sm:p-10",
          "bg-white/70 backdrop-blur-xl border-[oklch(70%_0.213_47.604)]/20 shadow-2xl shadow-[oklch(70%_0.213_47.604)]/5",
          "dark:bg-gray-900/60 dark:border-white/10 dark:shadow-none"
        ]}>
          <div class={[
            "w-16 h-16 rounded-full mx-auto mb-5 flex items-center justify-center",
            "bg-orange-50 dark:bg-orange-950/40"
          ]}>
            <.icon name="hero-finger-print" class="w-8 h-8 text-[oklch(70%_0.213_47.604)]" />
          </div>

          <h2 class="text-lg font-semibold text-gray-900 dark:text-gray-100 mb-2">
            Confirm sign-in
          </h2>
          <p class="text-sm text-gray-500 dark:text-gray-400 mb-6">
            Click below to securely sign in to your account
          </p>

          <.form
            for={%{}}
            phx-submit="submit"
            phx-trigger-action={@trigger_action}
            action={auth_path(@strategy, @auth_routes_prefix)}
            method="POST"
            id="magic-sign-in-form"
          >
            <input type="hidden" name="user[token]" value={@token} />
            <input type="hidden" name="user[remember_me]" value="false" />

            <button
              type="submit"
              id="magic-sign-in-submit"
              class={[
                "w-full flex items-center justify-center gap-2 px-6 py-3 rounded-xl",
                "text-sm font-semibold text-white cursor-pointer",
                "bg-[oklch(70%_0.213_47.604)] hover:bg-[oklch(63%_0.213_47.604)]",
                "shadow-md shadow-[oklch(70%_0.213_47.604)]/25 hover:shadow-lg",
                "transition-all duration-200 hover:-translate-y-0.5",
                "focus:outline-none focus:ring-2 focus:ring-[oklch(70%_0.213_47.604)] focus:ring-offset-2",
                "dark:focus:ring-offset-gray-900"
              ]}
            >
              <.icon name="hero-arrow-right-on-rectangle" class="w-4 h-4" /> Sign in
            </button>

            <div class="mt-4 flex flex-col items-center gap-1">
              <div class="flex items-center gap-2">
                <input
                  type="checkbox"
                  name="user[remember_me]"
                  value="true"
                  id="remember-me"
                  class="rounded border-gray-300 dark:border-gray-600 text-[oklch(70%_0.213_47.604)] focus:ring-[oklch(70%_0.213_47.604)]"
                />
                <label for="remember-me" class="text-sm text-gray-500 dark:text-gray-400">
                  Remember me
                </label>
              </div>
              <p class="text-xs text-gray-400 dark:text-gray-500">
                Stay signed in for 30 days
              </p>
            </div>
          </.form>
        </div>
      </div>
    </div>
    """
  end

  defp auth_path(strategy, auth_routes_prefix) do
    prefix = auth_routes_prefix || "/auth"
    subject = AshAuthentication.Info.authentication_subject_name!(strategy.resource)
    "#{prefix}/#{subject}/#{strategy.name}"
  end
end
