defmodule CheckDayWeb.SignInLive do
  use CheckDayWeb, :live_view

  on_mount {CheckDayWeb.LiveUserAuth, :live_no_user}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:email, "")
     |> assign(:state, :form)
     |> assign(:submitted_email, nil)}
  end

  @impl true
  def handle_event("update_email", %{"email" => email}, socket) do
    {:noreply, assign(socket, :email, email)}
  end

  def handle_event("request_magic_link", %{"email" => email}, socket) do
    email = String.trim(email)

    if email == "" do
      {:noreply, put_flash(socket, :error, "Please enter your email address")}
    else
      # Always show success to avoid email enumeration
      CheckDay.Accounts.User
      |> AshAuthentication.Info.strategy!(:magic_link)
      |> AshAuthentication.Strategy.action(:request, %{"email" => email})

      {:noreply,
       socket
       |> assign(:state, :success)
       |> assign(:submitted_email, email)
       |> clear_flash()}
    end
  end

  def handle_event("back_to_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:state, :form)
     |> assign(:email, "")
     |> assign(:submitted_email, nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex items-center justify-center min-h-[70vh]" id="sign-in-container">
        <div class={[
          "w-full max-w-md mx-auto",
          "animate-[fadeIn_0.4s_ease-out]"
        ]}>
          <%!-- Logo + Brand --%>
          <div class="flex flex-col items-center mb-8">
            <img
              src={~p"/images/logo.svg"}
              alt="Check.Day"
              class="w-16 h-16 mb-3"
              id="sign-in-logo"
            />
            <h1 class="text-2xl font-bold text-gray-900 dark:text-gray-100 tracking-tight" id="sign-in-title">
              Check<span class="text-[oklch(70%_0.213_47.604)]">.</span>Day
            </h1>
            <p class="text-sm text-gray-500 dark:text-gray-400 mt-1">
              Wake up to what matters
            </p>
          </div>

          <%= if @state == :form do %>
            <%!-- Sign-in Card --%>
            <div class={[
              "rounded-2xl border p-8",
              "bg-white/80 backdrop-blur-sm border-gray-200 shadow-lg shadow-gray-200/50",
              "dark:bg-gray-800/80 dark:border-gray-700 dark:shadow-gray-900/50"
            ]} id="sign-in-card">
              <div class="text-center mb-6">
                <h2 class="text-lg font-semibold text-gray-900 dark:text-gray-100">
                  Sign in or create account
                </h2>
                <p class="text-sm text-gray-500 dark:text-gray-400 mt-1">
                  We'll send you a magic link to your email
                </p>
              </div>

              <form phx-submit="request_magic_link" id="sign-in-form" class="space-y-5">
                <div>
                  <label for="email-input" class="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1.5">
                    Email address
                  </label>
                  <input
                    type="email"
                    name="email"
                    id="email-input"
                    value={@email}
                    phx-change="update_email"
                    placeholder="you@example.com"
                    required
                    autocomplete="email"
                    autofocus
                    class={[
                      "w-full px-4 py-3 rounded-xl text-sm",
                      "bg-gray-50 border border-gray-200 text-gray-900 placeholder-gray-400",
                      "dark:bg-gray-700/50 dark:border-gray-600 dark:text-gray-100 dark:placeholder-gray-500",
                      "focus:outline-none focus:ring-2 focus:ring-[oklch(70%_0.213_47.604)] focus:border-transparent",
                      "transition-all duration-200"
                    ]}
                  />
                </div>

                <button
                  type="submit"
                  id="sign-in-submit"
                  class={[
                    "w-full flex items-center justify-center gap-2 px-6 py-3 rounded-xl",
                    "text-sm font-semibold text-white",
                    "bg-[oklch(70%_0.213_47.604)] hover:bg-[oklch(63%_0.213_47.604)]",
                    "shadow-md shadow-[oklch(70%_0.213_47.604)]/25 hover:shadow-lg hover:shadow-[oklch(70%_0.213_47.604)]/30",
                    "transition-all duration-200 hover:-translate-y-0.5",
                    "focus:outline-none focus:ring-2 focus:ring-[oklch(70%_0.213_47.604)] focus:ring-offset-2",
                    "dark:focus:ring-offset-gray-900",
                    "cursor-pointer"
                  ]}
                >
                  <.icon name="hero-paper-airplane" class="w-4 h-4" />
                  Send magic link
                </button>
              </form>
            </div>
          <% else %>
            <%!-- Success State --%>
            <div class={[
              "rounded-2xl border p-8 text-center",
              "bg-white/80 backdrop-blur-sm border-gray-200 shadow-lg shadow-gray-200/50",
              "dark:bg-gray-800/80 dark:border-gray-700 dark:shadow-gray-900/50",
              "animate-[fadeIn_0.3s_ease-out]"
            ]} id="sign-in-success">
              <div class={[
                "w-16 h-16 rounded-full mx-auto mb-5 flex items-center justify-center",
                "bg-green-50 dark:bg-green-950/40"
              ]}>
                <.icon name="hero-envelope" class="w-8 h-8 text-green-600 dark:text-green-400" />
              </div>

              <h2 class="text-lg font-semibold text-gray-900 dark:text-gray-100 mb-2">
                Check your inbox
              </h2>
              <p class="text-sm text-gray-500 dark:text-gray-400 mb-1">
                We sent a magic link to
              </p>
              <p class="text-sm font-medium text-gray-900 dark:text-gray-100 mb-6">
                {@submitted_email}
              </p>
              <p class="text-xs text-gray-400 dark:text-gray-500 mb-4">
                Click the link in the email to sign in. It may take a minute to arrive.
              </p>

              <div class={[
                "rounded-xl p-4 mb-6 text-left",
                "bg-amber-50 border border-amber-200",
                "dark:bg-amber-950/30 dark:border-amber-800/50"
              ]} id="spam-warning">
                <div class="flex gap-2.5">
                  <.icon name="hero-exclamation-triangle" class="w-4 h-4 text-amber-500 dark:text-amber-400 mt-0.5 shrink-0" />
                  <div>
                    <p class="text-xs font-medium text-amber-800 dark:text-amber-300 mb-1">
                      Can't find the email?
                    </p>
                    <p class="text-xs text-amber-700 dark:text-amber-400/80 leading-relaxed">
                      Check your spam or junk folder. If you find it there,
                      please mark it as "not spam" first, then click the sign-in link.
                    </p>
                  </div>
                </div>
              </div>

              <button
                phx-click="back_to_form"
                id="try-different-email"
                class={[
                  "text-sm font-medium cursor-pointer",
                  "text-[oklch(70%_0.213_47.604)] hover:text-[oklch(63%_0.213_47.604)]",
                  "transition-colors duration-200"
                ]}
              >
                ← Use a different email
              </button>
            </div>
          <% end %>

          <%!-- Back to homepage --%>
          <div class="text-center mt-6">
            <a
              href={~p"/"}
              class={[
                "text-sm text-gray-400 dark:text-gray-500",
                "hover:text-gray-600 dark:hover:text-gray-300",
                "transition-colors duration-200"
              ]}
              id="back-to-home"
            >
              ← Back to homepage
            </a>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
