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
       |> assign(:blocks, blocks)
       |> assign(:user_active_days, user.active_days || [1, 2, 3, 4, 5, 6, 7])
       |> assign(:skipped_dates, user.skipped_dates || [])
       |> assign(:digest_times, user.digest_times || default_digest_times())
       |> assign(:open_day_menu, nil)}
    end
  end

  @impl true
  def handle_event("prev_week", _params, socket) do
    new_start = Date.add(socket.assigns.week_start, -7)
    {:noreply, assign(socket, week_start: new_start, open_day_menu: nil)}
  end

  def handle_event("next_week", _params, socket) do
    new_start = Date.add(socket.assigns.week_start, 7)
    {:noreply, assign(socket, week_start: new_start, open_day_menu: nil)}
  end

  def handle_event("this_week", _params, socket) do
    today = Date.utc_today()

    {:noreply,
     assign(socket,
       week_start: Date.beginning_of_week(today, :monday),
       open_day_menu: nil
     )}
  end

  def handle_event("toggle_day_menu", %{"date" => date_str}, socket) do
    date = Date.from_iso8601!(date_str)

    new_menu =
      if socket.assigns.open_day_menu == date, do: nil, else: date

    {:noreply, assign(socket, :open_day_menu, new_menu)}
  end

  def handle_event("close_day_menu", _params, socket) do
    {:noreply, assign(socket, :open_day_menu, nil)}
  end

  def handle_event("skip_date", %{"date" => date_str}, socket) do
    date = Date.from_iso8601!(date_str)
    user = socket.assigns.current_user
    current = socket.assigns.skipped_dates

    new_skipped =
      if date in current do
        List.delete(current, date)
      else
        [date | current]
      end

    case Ash.update(user, %{skipped_dates: new_skipped},
           action: :update_profile,
           authorize?: false
         ) do
      {:ok, _} ->
        {:noreply, assign(socket, skipped_dates: new_skipped, open_day_menu: nil)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update")}
    end
  end

  def handle_event("toggle_weekly_day", %{"day" => day_str}, socket) do
    day_num = String.to_integer(day_str)
    user = socket.assigns.current_user
    current_days = socket.assigns.user_active_days

    new_days =
      if day_num in current_days do
        List.delete(current_days, day_num)
      else
        Enum.sort([day_num | current_days])
      end

    case Ash.update(user, %{active_days: new_days},
           action: :update_profile,
           authorize?: false
         ) do
      {:ok, _} ->
        {:noreply, assign(socket, user_active_days: new_days, open_day_menu: nil)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update")}
    end
  end

  def handle_event("toggle_block_day", %{"block-id" => block_id, "day" => day_str}, socket) do
    day_num = String.to_integer(day_str)
    block = Enum.find(socket.assigns.blocks, &(&1.id == block_id))

    if block do
      current_days = block.active_days || [1, 2, 3, 4, 5, 6, 7]

      new_days =
        if day_num in current_days do
          List.delete(current_days, day_num)
        else
          Enum.sort([day_num | current_days])
        end

      case Ash.update(block, %{active_days: new_days},
             action: :update_days,
             authorize?: false
           ) do
        {:ok, _} ->
          blocks = load_user_blocks(socket.assigns.current_user.id)
          {:noreply, assign(socket, :blocks, blocks)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to update block")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("update_digest_time", %{"day" => day_str, "time" => time_str}, socket) do
    user = socket.assigns.current_user
    current_times = socket.assigns.digest_times
    new_times = Map.put(current_times, day_str, time_str)

    case Ash.update(user, %{digest_times: new_times},
           action: :update_profile,
           authorize?: false
         ) do
      {:ok, _} -> {:noreply, assign(socket, :digest_times, new_times)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to update time")}
    end
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

  def handle_info({:digest_update, {:digest_times_changed, times}}, socket) do
    {:noreply, assign(socket, :digest_times, times)}
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

  defp day_name(date), do: Calendar.strftime(date, "%a")
  defp day_number(date), do: Calendar.strftime(date, "%d")
  defp full_day_name(date), do: Calendar.strftime(date, "%A")

  defp default_digest_times do
    %{
      "1" => "07:00",
      "2" => "07:00",
      "3" => "07:00",
      "4" => "07:00",
      "5" => "07:00",
      "6" => "07:00",
      "7" => "07:00"
    }
  end

  defp get_day_time(digest_times, day) do
    key = Integer.to_string(Date.day_of_week(day))
    Map.get(digest_times, key, "07:00")
  end

  defp month_label(week_start) do
    week_end = Date.add(week_start, 6)

    if week_start.month == week_end.month do
      Calendar.strftime(week_start, "%B %Y")
    else
      "#{Calendar.strftime(week_start, "%b")} – #{Calendar.strftime(week_end, "%b %Y")}"
    end
  end

  defp day_disabled?(day, user_active_days, skipped_dates) do
    Date.day_of_week(day) not in user_active_days or day in skipped_dates
  end

  defp day_weekly_off?(day, user_active_days) do
    Date.day_of_week(day) not in user_active_days
  end

  defp day_date_skipped?(day, skipped_dates) do
    day in skipped_dates
  end

  defp block_active_on_day?(block, day) do
    day_num = Date.day_of_week(day)
    days = block.active_days || [1, 2, 3, 4, 5, 6, 7]
    day_num in days
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
            <div class="flex items-center gap-3 mt-1">
              <p class="text-gray-500" id="dashboard-subtitle">
                {month_label(@week_start)}
              </p>
            </div>
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

        <%!-- 7-Day Grid --%>
        <div class="grid grid-cols-7 gap-3" id="week-grid">
          <%= for day <- @days do %>
            <% is_disabled = day_disabled?(day, @user_active_days, @skipped_dates) %>
            <% is_weekly_off = day_weekly_off?(day, @user_active_days) %>
            <% is_date_skipped = day_date_skipped?(day, @skipped_dates) %>
            <div
              class={[
                "rounded-xl border flex flex-col min-h-[420px] transition-all duration-200 relative",
                cond do
                  is_disabled ->
                    "border-gray-200 bg-gray-50/80 opacity-50"

                  day == @today ->
                    "border-indigo-300 bg-indigo-50/20 shadow-md ring-1 ring-indigo-200/50"

                  true ->
                    "border-gray-200 bg-white hover:border-gray-300 hover:shadow-sm"
                end
              ]}
              id={"day-#{day}"}
            >
              <%!-- Day Header --%>
              <div
                class={[
                  "px-3 py-3 border-b shrink-0 rounded-t-xl relative",
                  "transition-all duration-200",
                  cond do
                    is_disabled ->
                      "border-gray-200 bg-gray-100/50"

                    day == @today ->
                      "border-indigo-200/60 bg-indigo-50/50"

                    true ->
                      "border-gray-100"
                  end
                ]}
                id={"day-header-#{day}"}
              >
                <%!-- Menu icon button --%>
                <button
                  phx-click="toggle_day_menu"
                  phx-value-date={Date.to_iso8601(day)}
                  class={[
                    "absolute top-2 right-2 p-1 rounded-md cursor-pointer",
                    "hover:bg-gray-200/60 transition-all duration-150",
                    "text-gray-300 hover:text-gray-500"
                  ]}
                  id={"day-menu-btn-#{day}"}
                >
                  <.icon name="hero-no-symbol-mini" class="w-4 h-4" />
                </button>

                <%!-- Centered day name + number --%>
                <div class="text-center">
                  <p class={[
                    "text-xs font-semibold uppercase tracking-wider",
                    cond do
                      is_disabled -> "text-gray-400 line-through"
                      day == @today -> "text-indigo-600"
                      true -> "text-gray-400"
                    end
                  ]}>
                    {day_name(day)}
                  </p>
                  <p class={[
                    "text-xl font-bold",
                    cond do
                      is_disabled -> "text-gray-400"
                      day == @today -> "text-indigo-700"
                      true -> "text-gray-800"
                    end
                  ]}>
                    {day_number(day)}
                  </p>
                  <%= unless is_disabled do %>
                    <form
                      phx-change="update_digest_time"
                      id={"time-form-#{day}"}
                      class="flex items-center justify-center mt-1.5"
                    >
                      <input type="hidden" name="day" value={Integer.to_string(Date.day_of_week(day))} />
                      <input
                        type="time"
                        value={get_day_time(@digest_times, day)}
                        phx-debounce="500"
                        name="time"
                        id={"time-#{day}"}
                        phx-hook=".TimePicker"
                        class="text-xs font-medium text-indigo-600 bg-indigo-50/50 border border-indigo-100 rounded-md px-1.5 py-0.5 cursor-pointer focus:ring-1 focus:ring-indigo-300 focus:border-indigo-300 w-[85px] text-center"
                      />
                    </form>
                  <% end %>
                </div>

                <%!-- Status badge below number --%>
                <%= cond do %>
                  <% is_weekly_off -> %>
                    <div class="text-center mt-1">
                      <span class="text-[9px] px-1.5 py-0.5 rounded-full bg-orange-100 text-orange-600 font-medium">
                        Every {day_name(day)}
                      </span>
                    </div>
                  <% is_date_skipped -> %>
                    <div class="text-center mt-1">
                      <span class="text-[9px] px-1.5 py-0.5 rounded-full bg-red-100 text-red-600 font-medium">
                        Skipped
                      </span>
                    </div>
                  <% true -> %>
                <% end %>
              </div>

              <%!-- Day Menu Popover --%>
              <%= if @open_day_menu == day do %>
                <div
                  class={[
                    "absolute top-8 right-0 z-20",
                    "bg-white rounded-xl shadow-xl border border-gray-200 p-1.5 w-48",
                    "animate-[slideIn_0.15s_ease-out]"
                  ]}
                  id={"day-menu-#{day}"}
                  phx-click-away="close_day_menu"
                >
                  <%!-- Skip this specific date --%>
                  <button
                    phx-click="skip_date"
                    phx-value-date={Date.to_iso8601(day)}
                    class={[
                      "flex items-center gap-2.5 w-full px-3 py-2.5 rounded-lg text-left text-sm cursor-pointer",
                      "transition-all duration-150",
                      if(is_date_skipped,
                        do: "bg-red-50 text-red-700 hover:bg-red-100",
                        else: "text-gray-700 hover:bg-gray-50"
                      )
                    ]}
                    id={"skip-date-#{day}"}
                  >
                    <.icon
                      name={if(is_date_skipped, do: "hero-arrow-uturn-left", else: "hero-calendar")}
                      class="w-4 h-4 shrink-0"
                    />
                    <div>
                      <p class="font-medium leading-tight">
                        {if is_date_skipped, do: "Unskip this date", else: "Skip this date"}
                      </p>
                      <p class="text-[10px] opacity-60 leading-tight mt-0.5">
                        {Calendar.strftime(day, "%b %d")} only
                      </p>
                    </div>
                  </button>

                  <div class="h-px bg-gray-100 mx-2 my-1" />

                  <%!-- Toggle this day every week --%>
                  <button
                    phx-click="toggle_weekly_day"
                    phx-value-day={Date.day_of_week(day)}
                    class={[
                      "flex items-center gap-2.5 w-full px-3 py-2.5 rounded-lg text-left text-sm cursor-pointer",
                      "transition-all duration-150",
                      if(is_weekly_off,
                        do: "bg-orange-50 text-orange-700 hover:bg-orange-100",
                        else: "text-gray-700 hover:bg-gray-50"
                      )
                    ]}
                    id={"toggle-weekly-#{day}"}
                  >
                    <.icon
                      name={if(is_weekly_off, do: "hero-arrow-uturn-left", else: "hero-arrow-path")}
                      class="w-4 h-4 shrink-0"
                    />
                    <div>
                      <p class="font-medium leading-tight">
                        {if is_weekly_off,
                          do: "Enable #{full_day_name(day)}s",
                          else: "Skip every #{full_day_name(day)}"}
                      </p>
                      <p class="text-[10px] opacity-60 leading-tight mt-0.5">
                        Recurring weekly
                      </p>
                    </div>
                  </button>
                </div>
              <% end %>

              <%!-- Digest Blocks --%>
              <div class="p-2 flex-1 space-y-1.5 overflow-y-auto" id={"day-blocks-#{day}"}>
                <%= if is_disabled do %>
                  <div class="flex flex-col items-center justify-center h-full text-gray-300">
                    <.icon name="hero-no-symbol" class="w-6 h-6 mb-1 opacity-40" />
                    <p class="text-[10px]">Day off</p>
                  </div>
                <% else %>
                  <%= if @blocks == [] do %>
                    <div class="flex flex-col items-center justify-center h-full text-gray-300">
                      <.icon name="hero-inbox" class="w-6 h-6 mb-1 opacity-40" />
                      <p class="text-[10px]">No blocks</p>
                    </div>
                  <% else %>
                    <%= for block <- @blocks do %>
                      <% is_block_active = block_active_on_day?(block, day) %>
                      <button
                        phx-click="toggle_block_day"
                        phx-value-block-id={block.id}
                        phx-value-day={Date.day_of_week(day)}
                        class={[
                          "flex items-center gap-2 p-2 rounded-lg border w-full text-left",
                          "transition-all duration-200 group/block cursor-pointer",
                          if(is_block_active,
                            do: ["hover:shadow-sm", type_bg(block.type)],
                            else: "bg-gray-50 border-gray-200 opacity-40 hover:opacity-60"
                          )
                        ]}
                        id={"block-#{block.id}-#{day}"}
                      >
                        <div class={[
                          "shrink-0",
                          if(is_block_active,
                            do: type_icon_color(block.type),
                            else: "text-gray-400"
                          )
                        ]}>
                          <.icon name={type_icon(block.type)} class="w-4 h-4" />
                        </div>
                        <span class={[
                          "text-xs font-medium truncate flex-1",
                          if(is_block_active,
                            do: type_label_color(block.type),
                            else: "text-gray-400 line-through"
                          )
                        ]}>
                          {block.label}
                        </span>
                      </button>
                    <% end %>
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
    <script :type={Phoenix.LiveView.ColocatedHook} name=".TimePicker">
      export default {
        mounted() {
          this.el.addEventListener("click", (e) => {
            if (this.el.showPicker) {
              try { this.el.showPicker() } catch(_) {}
            }
          })
        }
      }
    </script>
    """
  end
end
