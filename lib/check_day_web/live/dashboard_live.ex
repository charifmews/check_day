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
      week_start = today

      {:ok,
       socket
       |> assign(:week_start, week_start)
       |> assign(:today, today)
       |> assign(:blocks, blocks)
       |> assign(:user_active_days, user.active_days || [1, 2, 3, 4, 5, 6, 7])
       |> assign(:skipped_dates, user.skipped_dates || [])
       |> assign(:digest_times, user.digest_times || default_digest_times())
       |> assign(:open_day_menu, nil)
       |> assign(:show_add_form, false)
       |> assign(:editing_block_id, nil)
       |> assign(:add_type, "weather")
       |> assign(:add_label, "")
       |> assign(:add_config_rows, [])
       |> assign(:edit_type, "weather")
       |> assign(:edit_label, "")
       |> assign(:edit_config_rows, [])
       |> assign(:conversation_status, :idle)
       |> assign(:transcript, [])
       |> assign(:show_voice_panel, false)}
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
       week_start: today,
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

  def handle_event("toggle_add_form", _params, socket) do
    {:noreply, assign(socket, :show_add_form, !socket.assigns.show_add_form)}
  end

  def handle_event("update_add_type", %{"type" => type}, socket) do
    {:noreply, assign(socket, :add_type, type)}
  end

  def handle_event("update_add_label", %{"value" => label}, socket) do
    {:noreply, assign(socket, :add_label, label)}
  end

  def handle_event("add_config_row", _params, socket) do
    rows = socket.assigns.add_config_rows ++ [%{key: "", value: ""}]
    {:noreply, assign(socket, :add_config_rows, rows)}
  end

  def handle_event("remove_add_config_row", %{"index" => idx}, socket) do
    index = String.to_integer(idx)
    rows = List.delete_at(socket.assigns.add_config_rows, index)
    {:noreply, assign(socket, :add_config_rows, rows)}
  end

  def handle_event("update_add_config_key", %{"index" => idx, "value" => val}, socket) do
    index = String.to_integer(idx)
    rows = List.update_at(socket.assigns.add_config_rows, index, &Map.put(&1, :key, val))
    {:noreply, assign(socket, :add_config_rows, rows)}
  end

  def handle_event("update_add_config_value", %{"index" => idx, "value" => val}, socket) do
    index = String.to_integer(idx)
    rows = List.update_at(socket.assigns.add_config_rows, index, &Map.put(&1, :value, val))
    {:noreply, assign(socket, :add_config_rows, rows)}
  end

  def handle_event("add_block", _params, socket) do
    user = socket.assigns.current_user
    type = String.to_existing_atom(socket.assigns.add_type)
    label = socket.assigns.add_label
    config = config_rows_to_map(socket.assigns.add_config_rows)

    attrs = %{
      type: type,
      label: label,
      config: config,
      position: length(socket.assigns.blocks),
      enabled: true,
      user_id: user.id
    }

    case Ash.create(DigestBlock, attrs, authorize?: false) do
      {:ok, _block} ->
        blocks = load_user_blocks(user.id)

        {:noreply,
         socket
         |> assign(:blocks, blocks)
         |> assign(:show_add_form, false)
         |> assign(:add_type, "weather")
         |> assign(:add_label, "")
         |> assign(:add_config_rows, [])}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to add block")}
    end
  end

  def handle_event("start_edit", %{"block-id" => block_id}, socket) do
    block = Enum.find(socket.assigns.blocks, &(&1.id == block_id))

    if block do
      config_rows = map_to_config_rows(block.config)

      {:noreply,
       socket
       |> assign(:editing_block_id, block_id)
       |> assign(:edit_type, to_string(block.type))
       |> assign(:edit_label, block.label)
       |> assign(:edit_config_rows, config_rows)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, :editing_block_id, nil)}
  end

  def handle_event("update_edit_type", %{"type" => type}, socket) do
    {:noreply, assign(socket, :edit_type, type)}
  end

  def handle_event("update_edit_label", %{"value" => label}, socket) do
    {:noreply, assign(socket, :edit_label, label)}
  end

  def handle_event("add_edit_config_row", _params, socket) do
    rows = socket.assigns.edit_config_rows ++ [%{key: "", value: ""}]
    {:noreply, assign(socket, :edit_config_rows, rows)}
  end

  def handle_event("remove_edit_config_row", %{"index" => idx}, socket) do
    index = String.to_integer(idx)
    rows = List.delete_at(socket.assigns.edit_config_rows, index)
    {:noreply, assign(socket, :edit_config_rows, rows)}
  end

  def handle_event("update_edit_config_key", %{"index" => idx, "value" => val}, socket) do
    index = String.to_integer(idx)
    rows = List.update_at(socket.assigns.edit_config_rows, index, &Map.put(&1, :key, val))
    {:noreply, assign(socket, :edit_config_rows, rows)}
  end

  def handle_event("update_edit_config_value", %{"index" => idx, "value" => val}, socket) do
    index = String.to_integer(idx)
    rows = List.update_at(socket.assigns.edit_config_rows, index, &Map.put(&1, :value, val))
    {:noreply, assign(socket, :edit_config_rows, rows)}
  end

  def handle_event("save_edit", _params, socket) do
    block = Enum.find(socket.assigns.blocks, &(&1.id == socket.assigns.editing_block_id))

    if block do
      config = config_rows_to_map(socket.assigns.edit_config_rows)

      case Ash.update(block, %{type: String.to_existing_atom(socket.assigns.edit_type), label: socket.assigns.edit_label, config: config},
             action: :update,
             authorize?: false
           ) do
        {:ok, _} ->
          blocks = load_user_blocks(socket.assigns.current_user.id)
          {:noreply, socket |> assign(:blocks, blocks) |> assign(:editing_block_id, nil)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to update block")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("delete_block", %{"block-id" => block_id}, socket) do
    block = Enum.find(socket.assigns.blocks, &(&1.id == block_id))

    if block do
      case Ash.destroy(block, authorize?: false) do
        :ok ->
          blocks = load_user_blocks(socket.assigns.current_user.id)
          {:noreply, assign(socket, :blocks, blocks)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to delete block")}
      end
    else
      {:noreply, socket}
    end
  end

  # Voice conversation events
  def handle_event("toggle_voice_panel", _params, socket) do
    {:noreply, assign(socket, :show_voice_panel, !socket.assigns.show_voice_panel)}
  end

  def handle_event("start_conversation", _params, socket) do
    agent_id = Application.get_env(:check_day, :eleven_labs_agent_id)
    user = socket.assigns.current_user
    blocks = socket.assigns.blocks
    existing_blocks = format_blocks_for_agent(blocks)

    case ElevenLabs.get_conversation_signed_link(agent_id: agent_id) do
      {:ok, %{body: %{"signed_url" => signed_url}}} ->
        {:noreply,
         socket
         |> assign(:conversation_status, :connecting)
         |> assign(:show_voice_panel, true)
         |> push_event("start_conversation", %{
           signed_url: signed_url,
           user_id: user.id,
           existing_blocks: existing_blocks,
           first_name: user.first_name || "",
           digest_time: first_digest_time(user.digest_times || default_digest_times())
         })}

      {:ok, _response} ->
        {:noreply,
         socket
         |> put_flash(:error, "Unexpected API response format")
         |> assign(:conversation_status, :error)}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to start conversation: #{inspect(reason)}")
         |> assign(:conversation_status, :error)}
    end
  end

  def handle_event("end_conversation", _params, socket) do
    {:noreply,
     socket
     |> assign(:conversation_status, :idle)
     |> push_event("end_conversation", %{})}
  end

  def handle_event("status_change", %{"status" => status}, socket) do
    {:noreply, assign(socket, :conversation_status, parse_status(status))}
  end

  def handle_event("transcript_update", %{"message" => message, "source" => source}, socket) do
    entry = %{source: source, message: message, id: System.unique_integer([:positive])}
    {:noreply, assign(socket, :transcript, socket.assigns.transcript ++ [entry])}
  end

  def handle_event("conversation_ended", _params, socket) do
    {:noreply, assign(socket, :conversation_status, :idle)}
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

  defp config_rows_to_map(rows) do
    rows
    |> Enum.reject(fn %{key: k} -> k == "" end)
    |> Map.new(fn %{key: k, value: v} -> {k, v} end)
  end

  defp map_to_config_rows(nil), do: []
  defp map_to_config_rows(config) when config == %{}, do: []

  defp map_to_config_rows(config) when is_map(config) do
    Enum.map(config, fn {k, v} -> %{key: to_string(k), value: to_string(v)} end)
  end

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

  defp format_blocks_for_agent([]), do: "None"

  defp format_blocks_for_agent(blocks) do
    blocks
    |> Enum.map(fn block -> "block_id: #{block.id}, type: #{block.type}, label: #{block.label}" end)
    |> Enum.join(", ")
  end

  defp first_digest_time(digest_times) do
    Map.get(digest_times, "1", "07:00")
  end

  @known_statuses %{
    "idle" => :idle,
    "connecting" => :connecting,
    "connected" => :connected,
    "speaking" => :speaking,
    "listening" => :listening,
    "disconnecting" => :disconnecting,
    "disconnected" => :idle,
    "error" => :error
  }

  defp parse_status(status) when is_binary(status) do
    Map.get(@known_statuses, status, :idle)
  end

  defp status_text(:idle), do: "Ready to start"
  defp status_text(:connecting), do: "Connecting..."
  defp status_text(:connected), do: "Connected — start talking!"
  defp status_text(:speaking), do: "Agent is speaking..."
  defp status_text(:listening), do: "Listening..."
  defp status_text(:disconnecting), do: "Disconnecting..."
  defp status_text(:error), do: "Connection error"
  defp status_text(_), do: ""

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
      :weather -> "bg-sky-50 border-sky-200 dark:bg-sky-950/40 dark:border-sky-800"
      :news -> "bg-purple-50 border-purple-200 dark:bg-purple-950/40 dark:border-purple-800"
      :interest -> "bg-amber-50 border-amber-200 dark:bg-amber-950/40 dark:border-amber-800"
      :competitor -> "bg-red-50 border-red-200 dark:bg-red-950/40 dark:border-red-800"
      :stock -> "bg-emerald-50 border-emerald-200 dark:bg-emerald-950/40 dark:border-emerald-800"
      :agenda -> "bg-blue-50 border-blue-200 dark:bg-blue-950/40 dark:border-blue-800"
      :habit -> "bg-green-50 border-green-200 dark:bg-green-950/40 dark:border-green-800"
      :custom -> "bg-gray-50 border-gray-200 dark:bg-gray-800/40 dark:border-gray-700"
      _ -> "bg-gray-50 border-gray-200 dark:bg-gray-800/40 dark:border-gray-700"
    end
  end

  defp type_icon_color(type) do
    case type do
      :weather -> "text-sky-600 dark:text-sky-400"
      :news -> "text-purple-600 dark:text-purple-400"
      :interest -> "text-amber-600 dark:text-amber-400"
      :competitor -> "text-red-600 dark:text-red-400"
      :stock -> "text-emerald-600 dark:text-emerald-400"
      :agenda -> "text-blue-600 dark:text-blue-400"
      :habit -> "text-green-600 dark:text-green-400"
      :custom -> "text-gray-600 dark:text-gray-400"
      _ -> "text-gray-600 dark:text-gray-400"
    end
  end

  defp type_label_color(type) do
    case type do
      :weather -> "text-sky-800 dark:text-sky-300"
      :news -> "text-purple-800 dark:text-purple-300"
      :interest -> "text-amber-800 dark:text-amber-300"
      :competitor -> "text-red-800 dark:text-red-300"
      :stock -> "text-emerald-800 dark:text-emerald-300"
      :agenda -> "text-blue-800 dark:text-blue-300"
      :habit -> "text-green-800 dark:text-green-300"
      :custom -> "text-gray-800 dark:text-gray-300"
      _ -> "text-gray-800 dark:text-gray-300"
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
            <h1 class="text-3xl font-bold text-gray-900 dark:text-gray-100" id="dashboard-title">
              Your Week
            </h1>
            <div class="flex items-center gap-3 mt-1">
              <p class="text-gray-500 dark:text-gray-400" id="dashboard-subtitle">
                {month_label(@week_start)}
              </p>
            </div>
          </div>

          <div class="flex items-center gap-2">
            <button
              phx-click="prev_week"
              class={[
                "p-2 rounded-lg border border-gray-200 bg-white dark:bg-gray-800 dark:border-gray-700",
                "hover:bg-gray-50 hover:border-gray-300 dark:hover:bg-gray-700 dark:hover:border-gray-600",
                "transition-all duration-200"
              ]}
              id="prev-week-btn"
            >
              <.icon name="hero-chevron-left" class="w-5 h-5 text-gray-600 dark:text-gray-300" />
            </button>

            <button
              phx-click="this_week"
              class={[
                "px-4 py-2 rounded-lg border border-gray-200 bg-white text-sm font-medium text-gray-600 dark:bg-gray-800 dark:border-gray-700 dark:text-gray-300",
                "hover:bg-gray-50 hover:border-gray-300 dark:hover:bg-gray-700 dark:hover:border-gray-600",
                "transition-all duration-200"
              ]}
              id="this-week-btn"
            >
              Today
            </button>

            <button
              phx-click="next_week"
              class={[
                "p-2 rounded-lg border border-gray-200 bg-white dark:bg-gray-800 dark:border-gray-700",
                "hover:bg-gray-50 hover:border-gray-300 dark:hover:bg-gray-700 dark:hover:border-gray-600",
                "transition-all duration-200"
              ]}
              id="next-week-btn"
            >
              <.icon name="hero-chevron-right" class="w-5 h-5 text-gray-600 dark:text-gray-300" />
            </button>

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
                    "border-gray-200 bg-gray-50/80 opacity-50 dark:border-gray-700 dark:bg-gray-800/50"

                  day == @today ->
                    "border-indigo-300 bg-indigo-50/20 shadow-md ring-1 ring-indigo-200/50 dark:border-indigo-700 dark:bg-indigo-950/30 dark:ring-indigo-800/50"

                  true ->
                    "border-gray-200 bg-white hover:border-gray-300 hover:shadow-sm dark:border-gray-700 dark:bg-gray-800 dark:hover:border-gray-600"
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
                      "border-gray-200 bg-gray-100/50 dark:border-gray-700 dark:bg-gray-800/50"

                    day == @today ->
                      "border-indigo-200/60 bg-indigo-50/50 dark:border-indigo-800/60 dark:bg-indigo-950/30"

                    true ->
                      "border-gray-100 dark:border-gray-700"
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
                    "hover:bg-gray-200/60 transition-all duration-150 dark:hover:bg-gray-600/40",
                    "text-gray-300 hover:text-gray-500 dark:text-gray-500 dark:hover:text-gray-300"
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
                      is_disabled -> "text-gray-400 line-through dark:text-gray-500"
                      day == @today -> "text-indigo-600 dark:text-indigo-400"
                      true -> "text-gray-400 dark:text-gray-500"
                    end
                  ]}>
                    {day_name(day)}
                  </p>
                  <p class={[
                    "text-xl font-bold",
                    cond do
                      is_disabled -> "text-gray-400 dark:text-gray-500"
                      day == @today -> "text-indigo-700 dark:text-indigo-300"
                      true -> "text-gray-800 dark:text-gray-200"
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
                        class="text-xs font-medium text-indigo-600 bg-indigo-50/50 border border-indigo-100 rounded-md px-1.5 py-0.5 cursor-pointer focus:ring-1 focus:ring-indigo-300 focus:border-indigo-300 w-[85px] text-center dark:text-indigo-400 dark:bg-indigo-950/30 dark:border-indigo-800 dark:focus:ring-indigo-700 dark:focus:border-indigo-700"
                      />
                    </form>
                  <% end %>
                </div>

                <%!-- Status badge below number --%>
                <%= cond do %>
                  <% is_weekly_off -> %>
                    <div class="text-center mt-1">
                      <span class="text-[9px] px-1.5 py-0.5 rounded-full bg-orange-100 text-orange-600 font-medium dark:bg-orange-900/40 dark:text-orange-400">
                        Every {day_name(day)}
                      </span>
                    </div>
                  <% is_date_skipped -> %>
                    <div class="text-center mt-1">
                      <span class="text-[9px] px-1.5 py-0.5 rounded-full bg-red-100 text-red-600 font-medium dark:bg-red-900/40 dark:text-red-400">
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
                    "bg-white rounded-xl shadow-xl border border-gray-200 p-1.5 w-48 dark:bg-gray-800 dark:border-gray-700",
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
                        do: "bg-red-50 text-red-700 hover:bg-red-100 dark:bg-red-950/40 dark:text-red-400 dark:hover:bg-red-900/40",
                        else: "text-gray-700 hover:bg-gray-50 dark:text-gray-300 dark:hover:bg-gray-700"
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

                  <div class="h-px bg-gray-100 dark:bg-gray-700 mx-2 my-1" />

                  <%!-- Toggle this day every week --%>
                  <button
                    phx-click="toggle_weekly_day"
                    phx-value-day={Date.day_of_week(day)}
                    class={[
                      "flex items-center gap-2.5 w-full px-3 py-2.5 rounded-lg text-left text-sm cursor-pointer",
                      "transition-all duration-150",
                      if(is_weekly_off,
                        do: "bg-orange-50 text-orange-700 hover:bg-orange-100 dark:bg-orange-950/40 dark:text-orange-400 dark:hover:bg-orange-900/40",
                        else: "text-gray-700 hover:bg-gray-50 dark:text-gray-300 dark:hover:bg-gray-700"
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
                  <div class="flex flex-col items-center justify-center h-full text-gray-300 dark:text-gray-600">
                    <.icon name="hero-no-symbol" class="w-6 h-6 mb-1 opacity-40" />
                    <p class="text-[10px]">Day off</p>
                  </div>
                <% else %>
                  <%= if @blocks == [] do %>
                    <div class="flex flex-col items-center justify-center h-full text-gray-300 dark:text-gray-600">
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
                            else: "bg-gray-50 border-gray-200 opacity-40 hover:opacity-60 dark:bg-gray-800 dark:border-gray-700"
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

        <%!-- Block Management --%>
        <div class="mt-8" id="block-management">
          <div class="flex items-center justify-between mb-4">
            <h2 class="text-xl font-bold text-gray-900 dark:text-gray-100">Digest Blocks</h2>
            <button
              phx-click="toggle_add_form"
              class={[
                "inline-flex items-center gap-1.5 px-4 py-2 rounded-lg text-sm font-medium",
                "bg-indigo-50 text-indigo-700 border border-indigo-200 dark:bg-indigo-950/50 dark:text-indigo-300 dark:border-indigo-800",
                "hover:bg-indigo-100 hover:border-indigo-300 dark:hover:bg-indigo-900/50 dark:hover:border-indigo-700",
                "transition-all duration-200"
              ]}
              id="toggle-add-form-btn"
            >
              <.icon name={if(@show_add_form, do: "hero-x-mark", else: "hero-plus")} class="w-4 h-4" />
              {if @show_add_form, do: "Cancel", else: "Add Block"}
            </button>
          </div>

          <%= if @show_add_form do %>
            <div class="mb-6 p-5 rounded-xl border border-indigo-200 bg-indigo-50/30 dark:border-indigo-800 dark:bg-indigo-950/20" id="add-block-form">
              <h3 class="text-sm font-semibold text-gray-700 dark:text-gray-300 mb-4">New Block</h3>
              <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
                <div>
                  <label class="block text-xs font-medium text-gray-500 dark:text-gray-400 mb-1">Type</label>
                  <select
                    phx-change="update_add_type"
                    name="type"
                    id="add-block-type"
                    class="w-full rounded-lg border border-gray-200 bg-white px-3 py-2 text-sm text-gray-700 focus:ring-2 focus:ring-indigo-200 focus:border-indigo-300 dark:bg-gray-800 dark:border-gray-600 dark:text-gray-200 dark:focus:ring-indigo-800 dark:focus:border-indigo-700"
                  >
                    <option value="weather" selected={@add_type == "weather"}>☀️ Weather</option>
                    <option value="news" selected={@add_type == "news"}>📰 News</option>
                    <option value="interest" selected={@add_type == "interest"}>✨ Interest</option>
                    <option value="competitor" selected={@add_type == "competitor"}>🏢 Competitor</option>
                    <option value="stock" selected={@add_type == "stock"}>📈 Stock</option>
                    <option value="agenda" selected={@add_type == "agenda"}>📅 Agenda</option>
                    <option value="habit" selected={@add_type == "habit"}>✅ Habit</option>
                    <option value="custom" selected={@add_type == "custom"}>🧩 Custom</option>
                  </select>
                </div>
                <div>
                  <label class="block text-xs font-medium text-gray-500 dark:text-gray-400 mb-1">Label</label>
                  <input
                    type="text"
                    value={@add_label}
                    phx-keyup="update_add_label"
                    phx-key=""
                    name="label"
                    id="add-block-label"
                    placeholder="e.g. Amsterdam Weather"
                    class="w-full rounded-lg border border-gray-200 bg-white px-3 py-2 text-sm text-gray-700 placeholder-gray-400 focus:ring-2 focus:ring-indigo-200 focus:border-indigo-300 dark:bg-gray-800 dark:border-gray-600 dark:text-gray-200 dark:placeholder-gray-500 dark:focus:ring-indigo-800 dark:focus:border-indigo-700"
                  />
                </div>
              </div>
              <%!-- Config Key/Value Rows --%>
              <div class="mt-4">
                <div class="flex items-center justify-between mb-2">
                  <label class="block text-xs font-medium text-gray-500 dark:text-gray-400">Config <span class="text-gray-400 dark:text-gray-500">(optional)</span></label>
                  <button phx-click="add_config_row" type="button" class="text-xs text-indigo-600 hover:text-indigo-700 font-medium dark:text-indigo-400 dark:hover:text-indigo-300" id="add-config-row-btn">
                    + Add field
                  </button>
                </div>
                <%= for {row, idx} <- Enum.with_index(@add_config_rows) do %>
                  <div class="flex items-center gap-2 mb-2" id={"add-config-row-#{idx}"}>
                    <input type="text" value={row.key} phx-keyup="update_add_config_key" phx-value-index={idx} phx-key="" placeholder="key" id={"add-config-key-#{idx}"} class="flex-1 rounded-lg border border-gray-200 bg-white px-3 py-1.5 text-sm text-gray-700 placeholder-gray-400 focus:ring-2 focus:ring-indigo-200 focus:border-indigo-300 dark:bg-gray-800 dark:border-gray-600 dark:text-gray-200 dark:placeholder-gray-500" />
                    <input type="text" value={row.value} phx-keyup="update_add_config_value" phx-value-index={idx} phx-key="" placeholder="value" id={"add-config-val-#{idx}"} class="flex-1 rounded-lg border border-gray-200 bg-white px-3 py-1.5 text-sm text-gray-700 placeholder-gray-400 focus:ring-2 focus:ring-indigo-200 focus:border-indigo-300 dark:bg-gray-800 dark:border-gray-600 dark:text-gray-200 dark:placeholder-gray-500" />
                    <button phx-click="remove_add_config_row" phx-value-index={idx} type="button" class="p-1 text-gray-400 hover:text-red-500 transition-colors" id={"remove-add-config-#{idx}"}>
                      <.icon name="hero-x-mark" class="w-4 h-4" />
                    </button>
                  </div>
                <% end %>
              </div>
              <div class="mt-4 flex justify-end">
                <button
                  phx-click="add_block"
                  disabled={@add_label == ""}
                  class={[
                    "inline-flex items-center gap-1.5 px-5 py-2 rounded-lg text-sm font-medium transition-all duration-200",
                    if(@add_label == "",
                      do: "bg-gray-100 text-gray-400 cursor-not-allowed dark:bg-gray-700 dark:text-gray-500",
                      else: "bg-indigo-600 text-white hover:bg-indigo-700 shadow-sm dark:bg-indigo-500 dark:hover:bg-indigo-600"
                    )
                  ]}
                  id="submit-add-block-btn"
                >
                  <.icon name="hero-plus" class="w-4 h-4" /> Add
                </button>
              </div>
            </div>
          <% end %>

          <%= if @blocks == [] do %>
            <div class="text-center py-12 rounded-2xl border-2 border-dashed border-gray-200 dark:border-gray-700" id="empty-state">
              <.icon name="hero-inbox" class="w-12 h-12 text-gray-300 dark:text-gray-600 mx-auto mb-4" />
              <h3 class="text-lg font-semibold text-gray-600 dark:text-gray-300 mb-2">No digest blocks yet</h3>
              <p class="text-gray-400 dark:text-gray-500">Click "Add Block" above to build your daily digest</p>
            </div>
          <% else %>
            <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-3" id="block-list">
              <%= for block <- @blocks do %>
                <%= if @editing_block_id == block.id do %>
                  <div class="rounded-xl border border-indigo-200 bg-indigo-50/30 dark:border-indigo-800 dark:bg-indigo-950/20 p-5 col-span-full" id={"manage-block-#{block.id}"}>
                    <div class="space-y-3">
                      <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
                        <div>
                          <label class="block text-xs font-medium text-gray-500 dark:text-gray-400 mb-1">Type</label>
                          <select
                            phx-change="update_edit_type"
                            name="type"
                            id={"edit-type-#{block.id}"}
                            class="w-full rounded-lg border border-gray-200 bg-white px-3 py-2 text-sm text-gray-700 focus:ring-2 focus:ring-indigo-200 focus:border-indigo-300 dark:bg-gray-800 dark:border-gray-600 dark:text-gray-200 dark:focus:ring-indigo-800 dark:focus:border-indigo-700"
                          >
                            <option value="weather" selected={@edit_type == "weather"}>☀️ Weather</option>
                            <option value="news" selected={@edit_type == "news"}>📰 News</option>
                            <option value="interest" selected={@edit_type == "interest"}>✨ Interest</option>
                            <option value="competitor" selected={@edit_type == "competitor"}>🏢 Competitor</option>
                            <option value="stock" selected={@edit_type == "stock"}>📈 Stock</option>
                            <option value="agenda" selected={@edit_type == "agenda"}>📅 Agenda</option>
                            <option value="habit" selected={@edit_type == "habit"}>✅ Habit</option>
                            <option value="custom" selected={@edit_type == "custom"}>🧩 Custom</option>
                          </select>
                        </div>
                        <div>
                          <label class="block text-xs font-medium text-gray-500 dark:text-gray-400 mb-1">Label</label>
                          <input type="text" value={@edit_label} phx-keyup="update_edit_label" phx-key="" name="label" id={"edit-label-#{block.id}"} class="w-full rounded-lg border border-gray-200 bg-white px-3 py-2 text-sm text-gray-700 focus:ring-2 focus:ring-indigo-200 focus:border-indigo-300 dark:bg-gray-800 dark:border-gray-600 dark:text-gray-200 dark:focus:ring-indigo-800 dark:focus:border-indigo-700" />
                        </div>
                      </div>
                      <div>
                        <div class="flex items-center justify-between mb-1">
                          <label class="block text-xs font-medium text-gray-500 dark:text-gray-400">Config</label>
                          <button phx-click="add_edit_config_row" type="button" class="text-xs text-indigo-600 hover:text-indigo-700 font-medium dark:text-indigo-400" id={"add-edit-config-row-#{block.id}"}>+ Add field</button>
                        </div>
                        <%= for {row, idx} <- Enum.with_index(@edit_config_rows) do %>
                          <div class="flex items-center gap-2 mb-2" id={"edit-config-row-#{block.id}-#{idx}"}>
                            <input type="text" value={row.key} phx-keyup="update_edit_config_key" phx-value-index={idx} phx-key="" placeholder="key" id={"edit-config-key-#{block.id}-#{idx}"} class="flex-1 rounded-lg border border-gray-200 bg-white px-3 py-1.5 text-sm text-gray-700 placeholder-gray-400 focus:ring-2 focus:ring-indigo-200 focus:border-indigo-300 dark:bg-gray-800 dark:border-gray-600 dark:text-gray-200 dark:placeholder-gray-500" />
                            <input type="text" value={row.value} phx-keyup="update_edit_config_value" phx-value-index={idx} phx-key="" placeholder="value" id={"edit-config-val-#{block.id}-#{idx}"} class="flex-1 rounded-lg border border-gray-200 bg-white px-3 py-1.5 text-sm text-gray-700 placeholder-gray-400 focus:ring-2 focus:ring-indigo-200 focus:border-indigo-300 dark:bg-gray-800 dark:border-gray-600 dark:text-gray-200 dark:placeholder-gray-500" />
                            <button phx-click="remove_edit_config_row" phx-value-index={idx} type="button" class="p-1 text-gray-400 hover:text-red-500 transition-colors" id={"remove-edit-config-#{block.id}-#{idx}"}>
                              <.icon name="hero-x-mark" class="w-4 h-4" />
                            </button>
                          </div>
                        <% end %>
                      </div>
                      <div class="flex gap-2 justify-end">
                        <button phx-click="cancel_edit" class="px-3 py-1.5 rounded-lg text-xs font-medium text-gray-600 bg-gray-100 hover:bg-gray-200 transition-all dark:text-gray-300 dark:bg-gray-700 dark:hover:bg-gray-600" id={"cancel-edit-#{block.id}"}>Cancel</button>
                        <button phx-click="save_edit" class="px-3 py-1.5 rounded-lg text-xs font-medium text-white bg-indigo-600 hover:bg-indigo-700 transition-all dark:bg-indigo-500 dark:hover:bg-indigo-600" id={"save-edit-#{block.id}"}>Save</button>
                      </div>
                    </div>
                  </div>
                <% else %>
                  <div class={["rounded-xl border p-4 transition-all duration-200", type_bg(block.type)]} id={"manage-block-#{block.id}"}>
                    <div class="flex items-start gap-3">
                      <div class={["shrink-0 mt-0.5", type_icon_color(block.type)]}>
                        <.icon name={type_icon(block.type)} class="w-5 h-5" />
                      </div>
                      <div class="flex-1 min-w-0">
                        <p class={["font-medium text-sm truncate", type_label_color(block.type)]}>{block.label}</p>
                        <p class="text-xs text-gray-500 dark:text-gray-400 capitalize mt-0.5">{block.type}</p>
                        <%= if block.config && block.config != %{} do %>
                          <div class="mt-1.5 flex flex-wrap gap-1">
                            <%= for {k, v} <- block.config do %>
                              <span class="inline-flex items-center px-1.5 py-0.5 rounded text-[10px] bg-gray-100 text-gray-500 dark:bg-gray-700 dark:text-gray-400">
                                {k}: {v}
                              </span>
                            <% end %>
                          </div>
                        <% end %>
                      </div>
                      <div class="flex items-center gap-1 shrink-0">
                        <button phx-click="start_edit" phx-value-block-id={block.id} class="p-1.5 rounded-lg text-gray-400 hover:text-indigo-600 hover:bg-indigo-50 transition-all dark:hover:text-indigo-400 dark:hover:bg-indigo-950/40" id={"edit-btn-#{block.id}"}>
                          <.icon name="hero-pencil-square" class="w-4 h-4" />
                        </button>
                        <button phx-click="delete_block" phx-value-block-id={block.id} data-confirm="Remove this block from your digest?" class="p-1.5 rounded-lg text-gray-400 hover:text-red-600 hover:bg-red-50 transition-all dark:hover:text-red-400 dark:hover:bg-red-950/40" id={"delete-btn-#{block.id}"}>
                          <.icon name="hero-trash" class="w-4 h-4" />
                        </button>
                      </div>
                    </div>
                  </div>
                <% end %>
              <% end %>
            </div>
          <% end %>
        </div>

        <%!-- Floating Voice Assistant --%>
        <div id="voice-assistant-container">
          <%!-- ElevenLabs Hook (hidden, for managing the conversation) --%>
          <div id="dashboard-elevenlabs-hook" phx-hook=".DashboardElevenLabs" phx-update="ignore" class="hidden" />

          <%!-- Floating Mic Button --%>
          <%= unless @show_voice_panel do %>
            <button
              phx-click="toggle_voice_panel"
              class={[
                "fixed bottom-8 right-8 z-50 w-16 h-16 rounded-full flex items-center justify-center",
                "bg-gradient-to-br from-indigo-500 to-purple-600 text-white",
                "hover:from-indigo-600 hover:to-purple-700 hover:scale-110",
                "transition-all duration-300 shadow-xl shadow-indigo-300/40 dark:shadow-indigo-900/40",
                "focus:outline-none focus:ring-4 focus:ring-indigo-200 dark:focus:ring-indigo-800",
                "group"
              ]}
              id="voice-fab-btn"
            >
              <.icon name="hero-microphone" class="w-7 h-7 group-hover:scale-110 transition-transform" />
            </button>
          <% end %>

          <%!-- Voice Panel (slide-up from bottom-right) --%>
          <%= if @show_voice_panel do %>
            <div
              class={[
                "fixed bottom-8 right-8 z-50 w-[380px] rounded-2xl overflow-hidden",
                "bg-white dark:bg-gray-800 border border-gray-200 dark:border-gray-700",
                "shadow-2xl shadow-gray-300/50 dark:shadow-black/40",
                "animate-[slideUp_0.3s_ease-out]"
              ]}
              id="voice-panel"
            >
              <%!-- Panel Header --%>
              <div class={[
                "px-5 py-4 border-b flex items-center justify-between",
                if(@conversation_status in [:connected, :speaking, :listening],
                  do: "border-indigo-200 bg-indigo-50/50 dark:border-indigo-800 dark:bg-indigo-950/30",
                  else: "border-gray-100 bg-gray-50/50 dark:border-gray-700 dark:bg-gray-800/50"
                )
              ]}>
                <div class="flex items-center gap-2.5">
                  <div class={[
                    "w-2.5 h-2.5 rounded-full",
                    if(@conversation_status in [:connected, :speaking, :listening],
                      do: "bg-indigo-500 animate-pulse",
                      else: "bg-gray-400"
                    )
                  ]} />
                  <span class="text-sm font-medium text-gray-700 dark:text-gray-300">
                    {status_text(@conversation_status)}
                  </span>
                </div>
                <button
                  phx-click="toggle_voice_panel"
                  class="p-1.5 rounded-lg text-gray-400 hover:text-gray-600 hover:bg-gray-100 dark:hover:text-gray-300 dark:hover:bg-gray-700 transition-all"
                  id="close-voice-panel-btn"
                >
                  <.icon name="hero-x-mark" class="w-5 h-5" />
                </button>
              </div>

              <%!-- Mic Control --%>
              <div class="flex flex-col items-center py-6">
                <%= if @conversation_status == :idle do %>
                  <button
                    phx-click="start_conversation"
                    class={[
                      "w-20 h-20 rounded-full flex items-center justify-center",
                      "bg-gradient-to-br from-indigo-500 to-purple-600 text-white",
                      "hover:from-indigo-600 hover:to-purple-700 hover:scale-105",
                      "transition-all duration-200 shadow-lg shadow-indigo-200 dark:shadow-indigo-900/30",
                      "focus:outline-none focus:ring-4 focus:ring-indigo-200 dark:focus:ring-indigo-800"
                    ]}
                    id="dashboard-start-conversation-btn"
                  >
                    <.icon name="hero-microphone" class="w-9 h-9" />
                  </button>
                <% else %>
                  <button
                    phx-click="end_conversation"
                    class={[
                      "w-20 h-20 rounded-full flex items-center justify-center",
                      "bg-gradient-to-br from-red-500 to-rose-600 text-white",
                      "hover:from-red-600 hover:to-rose-700 hover:scale-105",
                      "transition-all duration-200 shadow-lg shadow-red-200 dark:shadow-red-900/30",
                      "focus:outline-none focus:ring-4 focus:ring-red-200 dark:focus:ring-red-800"
                    ]}
                    id="dashboard-end-conversation-btn"
                  >
                    <.icon name="hero-stop" class="w-9 h-9" />
                  </button>
                <% end %>
                <p class="text-xs text-gray-400 dark:text-gray-500 mt-3">
                  <%= if @conversation_status == :idle do %>
                    Tap to talk — manage blocks & times by voice
                  <% else %>
                    Tap to stop the conversation
                  <% end %>
                </p>
              </div>

              <%!-- Transcript --%>
              <div class="border-t border-gray-100 dark:border-gray-700 px-4 py-3 max-h-48 overflow-y-auto" id="dashboard-transcript" phx-hook=".TranscriptScroll">
                <h4 class="text-[10px] font-semibold text-gray-400 dark:text-gray-500 uppercase tracking-wider mb-2">
                  Transcript
                </h4>
                <%= if @transcript == [] do %>
                  <p class="text-xs text-gray-400 dark:text-gray-500 italic">
                    Conversation will appear here...
                  </p>
                <% else %>
                  <div class="space-y-1.5">
                    <%= for entry <- @transcript do %>
                      <div class={[
                        "text-xs rounded-lg px-2.5 py-1.5",
                        if(entry.source == "ai",
                          do: "bg-indigo-50 text-indigo-800 dark:bg-indigo-950/30 dark:text-indigo-300",
                          else: "bg-gray-50 text-gray-700 dark:bg-gray-700/50 dark:text-gray-200"
                        )
                      ]}>
                        <span class="font-semibold">
                          {if entry.source == "ai", do: "Maya", else: "You"}:
                        </span>
                        {entry.message}
                      </div>
                    <% end %>
                  </div>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
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
    <script :type={Phoenix.LiveView.ColocatedHook} name=".TranscriptScroll">
      export default {
        mounted() { this.el.scrollTop = this.el.scrollHeight; },
        updated() { this.el.scrollTop = this.el.scrollHeight; }
      }
    </script>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".DashboardElevenLabs">
      import { Conversation } from "@elevenlabs/client";

      export default {
        mounted() {
          this.conversation = null;

          this.handleEvent("start_conversation", async ({ signed_url, user_id, existing_blocks, first_name, digest_time }) => {
            try {
              await navigator.mediaDevices.getUserMedia({ audio: true });

              this.conversation = await Conversation.startSession({
                signedUrl: signed_url,
                dynamicVariables: {
                  user_id: user_id,
                  existing_blocks: existing_blocks,
                  first_name: first_name,
                  digest_time: digest_time
                },
                onMessage: (props) => {
                  if (this.el.isConnected) {
                    this.pushEvent("transcript_update", {
                      message: props.message,
                      source: props.source
                    });
                  }
                },
                onStatusChange: ({ status }) => {
                  if (this.el.isConnected) {
                    this.pushEvent("status_change", { status });
                  }
                },
                onDisconnect: (details) => {
                  if (this.el.isConnected) {
                    this.pushEvent("conversation_ended", {});
                  }
                },
                onError: (message, context) => {
                  console.error("ElevenLabs error:", message, context);
                }
              });
            } catch (error) {
              console.error("ElevenLabs conversation error:", error);
              if (this.el.isConnected) {
                this.pushEvent("status_change", { status: "error" });
              }
            }
          });

          this.handleEvent("end_conversation", async () => {
            if (this.conversation) {
              await this.conversation.endSession();
              this.conversation = null;
            }
          });
        },

        destroyed() {
          if (this.conversation) {
            this.conversation.endSession();
          }
        }
      }
    </script>
    """
  end
end
