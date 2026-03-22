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
       |> stream(:digest_blocks, blocks)
       |> assign(:blocks_empty?, blocks == [])}
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
  def handle_info({:digest_update, {:block_added, block}}, socket) do
    {:noreply,
     socket
     |> stream_insert(:digest_blocks, block)
     |> assign(:blocks_empty?, false)}
  end

  def handle_info({:digest_update, {:block_removed, block}}, socket) do
    blocks = load_user_blocks(socket.assigns.current_user.id)

    {:noreply,
     socket
     |> stream_delete(:digest_blocks, block)
     |> assign(:blocks_empty?, blocks == [])}
  end

  def handle_info({:digest_update, _}, socket), do: {:noreply, socket}

  defp load_user_blocks(user_id) do
    DigestBlock
    |> Ash.Query.filter(user_id == ^user_id)
    |> Ash.Query.sort(position: :asc)
    |> Ash.read!()
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

  defp type_color(type) do
    case type do
      :weather -> "bg-sky-100 text-sky-700 border-sky-200"
      :news -> "bg-purple-100 text-purple-700 border-purple-200"
      :interest -> "bg-amber-100 text-amber-700 border-amber-200"
      :competitor -> "bg-red-100 text-red-700 border-red-200"
      :stock -> "bg-emerald-100 text-emerald-700 border-emerald-200"
      :agenda -> "bg-blue-100 text-blue-700 border-blue-200"
      :habit -> "bg-green-100 text-green-700 border-green-200"
      :custom -> "bg-gray-100 text-gray-700 border-gray-200"
      _ -> "bg-gray-100 text-gray-700 border-gray-200"
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :days, week_days(assigns.week_start))

    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="max-w-7xl mx-auto px-4 py-8">
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

        <div class="grid grid-cols-1 lg:grid-cols-4 gap-6">
          <%!-- Left: Week Calendar (3 cols) --%>
          <div class="lg:col-span-3">
            <div class="grid grid-cols-7 gap-2" id="week-grid">
              <%= for day <- @days do %>
                <div
                  class={[
                    "rounded-xl border min-h-[180px] transition-all duration-200",
                    if(day == @today,
                      do: "border-indigo-300 bg-indigo-50/30 shadow-sm",
                      else: "border-gray-200 bg-white hover:border-gray-300"
                    )
                  ]}
                  id={"day-#{day}"}
                >
                  <%!-- Day Header --%>
                  <div class={[
                    "px-3 py-2 border-b text-center",
                    if(day == @today,
                      do: "border-indigo-100",
                      else: "border-gray-100"
                    )
                  ]}>
                    <p class={[
                      "text-xs font-medium uppercase tracking-wide",
                      if(day == @today, do: "text-indigo-600", else: "text-gray-400")
                    ]}>
                      {day_name(day)}
                    </p>
                    <p class={[
                      "text-lg font-bold",
                      if(day == @today, do: "text-indigo-700", else: "text-gray-800")
                    ]}>
                      {day_number(day)}
                    </p>
                  </div>

                  <%!-- Placeholder for day content (future: day-specific events) --%>
                  <div class="p-2">
                    <p class="text-xs text-gray-300 text-center mt-4">
                      {if day == @today, do: "Today", else: ""}
                    </p>
                  </div>
                </div>
              <% end %>
            </div>
          </div>

          <%!-- Right: Digest Blocks Sidebar (1 col) --%>
          <div class="lg:col-span-1">
            <div
              class="rounded-2xl border border-gray-200 bg-white p-4 sticky top-4"
              id="digest-sidebar"
            >
              <h3 class="text-sm font-semibold text-gray-500 uppercase tracking-wide mb-4">
                Daily Digest
              </h3>

              <div id="digest-blocks" phx-update="stream">
                <div
                  id="empty-blocks"
                  class="hidden only:flex flex-col items-center justify-center py-8 text-gray-400"
                >
                  <.icon name="hero-inbox" class="w-10 h-10 mb-2 opacity-50" />
                  <p class="text-xs text-center">No blocks yet</p>
                </div>

                <div
                  :for={{id, block} <- @streams.digest_blocks}
                  id={id}
                  class={[
                    "flex items-center gap-2.5 p-3 rounded-xl border mb-2",
                    "hover:shadow-sm transition-all duration-200",
                    "animate-[slideIn_0.3s_ease-out]",
                    type_color(block.type)
                  ]}
                >
                  <div class="w-8 h-8 rounded-lg flex items-center justify-center bg-white/60">
                    <.icon name={type_icon(block.type)} class="w-4 h-4" />
                  </div>
                  <div class="flex-1 min-w-0">
                    <p class="font-medium text-sm truncate">{block.label}</p>
                    <p class="text-[10px] uppercase tracking-wide opacity-70">{block.type}</p>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>

        <%!-- Empty State --%>
        <%= if @blocks_empty? do %>
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
