defmodule CheckDayWeb.DashboardLive do
  use CheckDayWeb, :live_view

  alias CheckDay.Digests.DigestBlock

  require Ash.Query

  on_mount {CheckDayWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    # Redirect to onboarding if not completed
    if not user.onboarding_completed do
      {:ok, push_navigate(socket, to: ~p"/onboarding")}
    else
      if connected?(socket) do
        Phoenix.PubSub.subscribe(CheckDay.PubSub, "user:#{user.id}")
      end

      blocks = load_user_blocks(user.id)
      today = Date.utc_today()
      week_start = Date.beginning_of_week(today, :monday)

      {:ok,
       socket
       |> assign(:week_start, week_start)
       |> assign(:today, today)
       |> assign(:blocks, blocks)}
    end
  end

  @impl true
  def handle_event("prev_week", _params, socket) do
    new_start = Date.add(socket.assigns.week_start, -7)
    {:noreply, assign(socket, :week_start, new_start)}
  end

  def handle_event("next_week", _params, socket) do
    new_start = Date.add(socket.assigns.week_start, 7)
    {:noreply, assign(socket, :week_start, new_start)}
  end

  def handle_event("this_week", _params, socket) do
    today = Date.utc_today()
    {:noreply, assign(socket, :week_start, Date.beginning_of_week(today, :monday))}
  end

  # PubSub handlers
  @impl true
  def handle_info({:digest_update, {:block_added, _block}}, socket) do
    blocks = load_user_blocks(socket.assigns.current_user.id)
    {:noreply, assign(socket, :blocks, blocks)}
  end

  def handle_info({:digest_update, {:block_removed, _block}}, socket) do
    blocks = load_user_blocks(socket.assigns.current_user.id)
    {:noreply, assign(socket, :blocks, blocks)}
  end

  def handle_info({:digest_update, _}, socket), do: {:noreply, socket}

  defp load_user_blocks(user_id) do
    DigestBlock
    |> Ash.Query.filter(user_id == ^user_id)
    |> Ash.Query.sort(position: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp week_days(week_start) do
    Enum.map(0..6, fn offset -> Date.add(week_start, offset) end)
  end

  defp day_name(date) do
    Calendar.strftime(date, "%a")
  end

  defp day_number(date) do
    Calendar.strftime(date, "%d")
  end

  defp month_label(week_start) do
    week_end = Date.add(week_start, 6)

    if week_start.month == week_end.month do
      Calendar.strftime(week_start, "%B %Y")
    else
      "#{Calendar.strftime(week_start, "%b")} – #{Calendar.strftime(week_end, "%b %Y")}"
    end
  end

  defp type_icon(type) do
    case type do
      :weather -> "hero-sun"
      :news -> "hero-newspaper"
      :interest -> "hero-sparkles"
      :competitor -> "hero-building-office-2"
      :stock -> "hero-chart-bar"
      :agenda -> "hero-calendar-days"
      :habit -> "hero-check-circle"
      :custom -> "hero-puzzle-piece"
      _ -> "hero-square-3-stack-3d"
    end
  end

  defp type_bg(type) do
    case type do
      :weather -> "bg-sky-50 border-sky-200"
      :news -> "bg-purple-50 border-purple-200"
      :interest -> "bg-amber-50 border-amber-200"
      :competitor -> "bg-red-50 border-red-200"
      :stock -> "bg-emerald-50 border-emerald-200"
      :agenda -> "bg-blue-50 border-blue-200"
      :habit -> "bg-green-50 border-green-200"
      :custom -> "bg-gray-50 border-gray-200"
      _ -> "bg-gray-50 border-gray-200"
    end
  end

  defp type_icon_color(type) do
    case type do
      :weather -> "text-sky-600"
      :news -> "text-purple-600"
      :interest -> "text-amber-600"
      :competitor -> "text-red-600"
      :stock -> "text-emerald-600"
      :agenda -> "text-blue-600"
      :habit -> "text-green-600"
      :custom -> "text-gray-600"
      _ -> "text-gray-600"
    end
  end

  defp type_label_color(type) do
    case type do
      :weather -> "text-sky-800"
      :news -> "text-purple-800"
      :interest -> "text-amber-800"
      :competitor -> "text-red-800"
      :stock -> "text-emerald-800"
      :agenda -> "text-blue-800"
      :habit -> "text-green-800"
      :custom -> "text-gray-800"
      _ -> "text-gray-800"
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :days, week_days(assigns.week_start))

    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="w-full max-w-[1600px] mx-auto px-6 lg:px-10 py-8">
        <%!-- Header --%>
        <div class="flex items-center justify-between mb-8">
          <div>
            <h1 class="text-3xl font-bold text-gray-900" id="dashboard-title">
              Your Week
            </h1>
            <p class="text-gray-500 mt-1" id="dashboard-subtitle">
              {month_label(@week_start)}
            </p>
          </div>

          <div class="flex items-center gap-2">
            <button
              phx-click="prev_week"
              class={[
                "p-2 rounded-lg border border-gray-200 bg-white",
                "hover:bg-gray-50 hover:border-gray-300",
                "transition-all duration-200"
              ]}
              id="prev-week-btn"
            >
              <.icon name="hero-chevron-left" class="w-5 h-5 text-gray-600" />
            </button>

            <button
              phx-click="this_week"
              class={[
                "px-4 py-2 rounded-lg border border-gray-200 bg-white text-sm font-medium text-gray-600",
                "hover:bg-gray-50 hover:border-gray-300",
                "transition-all duration-200"
              ]}
              id="this-week-btn"
            >
              Today
            </button>

            <button
              phx-click="next_week"
              class={[
                "p-2 rounded-lg border border-gray-200 bg-white",
                "hover:bg-gray-50 hover:border-gray-300",
                "transition-all duration-200"
              ]}
              id="next-week-btn"
            >
              <.icon name="hero-chevron-right" class="w-5 h-5 text-gray-600" />
            </button>

            <div class="w-px h-8 bg-gray-200 mx-2" />

            <.link
              navigate={~p"/onboarding"}
              class={[
                "inline-flex items-center gap-1.5 px-4 py-2 rounded-lg text-sm font-medium",
                "bg-indigo-50 text-indigo-700 border border-indigo-200",
                "hover:bg-indigo-100 hover:border-indigo-300",
                "transition-all duration-200"
              ]}
              id="rerun-onboarding-btn"
            >
              <.icon name="hero-microphone" class="w-4 h-4" /> Voice Setup
            </.link>
          </div>
        </div>

        <%!-- 7-Day Grid with Digest Blocks --%>
        <div class="grid grid-cols-7 gap-3" id="week-grid">
          <%= for day <- @days do %>
            <div
              class={[
                "rounded-xl border flex flex-col min-h-[420px] transition-all duration-200",
                if(day == @today,
                  do: "border-indigo-300 bg-indigo-50/20 shadow-md ring-1 ring-indigo-200/50",
                  else: "border-gray-200 bg-white hover:border-gray-300 hover:shadow-sm"
                )
              ]}
              id={"day-#{day}"}
            >
              <%!-- Day Header --%>
              <div class={[
                "px-3 py-3 border-b text-center shrink-0",
                if(day == @today,
                  do: "border-indigo-200/60 bg-indigo-50/50",
                  else: "border-gray-100"
                )
              ]}>
                <p class={[
                  "text-xs font-semibold uppercase tracking-wider",
                  if(day == @today, do: "text-indigo-600", else: "text-gray-400")
                ]}>
                  {day_name(day)}
                </p>
                <p class={[
                  "text-xl font-bold mt-0.5",
                  if(day == @today, do: "text-indigo-700", else: "text-gray-800")
                ]}>
                  {day_number(day)}
                </p>
              </div>

              <%!-- Digest Blocks for this day --%>
              <div class="p-2 flex-1 space-y-1.5 overflow-y-auto" id={"day-blocks-#{day}"}>
                <%= if @blocks == [] do %>
                  <div class="flex flex-col items-center justify-center h-full text-gray-300">
                    <.icon name="hero-inbox" class="w-6 h-6 mb-1 opacity-40" />
                    <p class="text-[10px]">No blocks</p>
                  </div>
                <% else %>
                  <%= for block <- @blocks do %>
                    <div
                      class={[
                        "flex items-center gap-2 p-2 rounded-lg border",
                        "transition-all duration-200 hover:shadow-sm",
                        type_bg(block.type)
                      ]}
                      id={"block-#{block.id}-#{day}"}
                    >
                      <div class={["shrink-0", type_icon_color(block.type)]}>
                        <.icon name={type_icon(block.type)} class="w-4 h-4" />
                      </div>
                      <span class={["text-xs font-medium truncate", type_label_color(block.type)]}>
                        {block.label}
                      </span>
                    </div>
                  <% end %>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>

        <%!-- Empty State --%>
        <%= if @blocks == [] do %>
          <div
            class="mt-8 text-center py-12 rounded-2xl border-2 border-dashed border-gray-200"
            id="empty-state"
          >
            <.icon name="hero-inbox" class="w-12 h-12 text-gray-300 mx-auto mb-4" />
            <h3 class="text-lg font-semibold text-gray-600 mb-2">No digest blocks yet</h3>
            <p class="text-gray-400 mb-4">Set up your daily digest with a voice conversation</p>
            <.link
              navigate={~p"/onboarding"}
              class={[
                "inline-flex items-center gap-2 px-6 py-3 rounded-full text-sm font-medium",
                "bg-gradient-to-r from-indigo-500 to-purple-600 text-white",
                "hover:from-indigo-600 hover:to-purple-700",
                "shadow-lg shadow-indigo-200 transition-all duration-200"
              ]}
              id="start-onboarding-btn"
            >
              <.icon name="hero-microphone" class="w-5 h-5" /> Start Voice Setup
            </.link>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
