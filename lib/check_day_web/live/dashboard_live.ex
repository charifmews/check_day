defmodule CheckDayWeb.DashboardLive do
  use CheckDayWeb, :live_view

  alias CheckDay.Digests.DigestBlock

  require Ash.Query

  on_mount {CheckDayWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    socket =
      if connected?(socket) do
        Phoenix.PubSub.subscribe(CheckDay.PubSub, "user:#{user.id}")
        maybe_save_timezone(socket, user)
      else
        socket
      end

    blocks = load_user_blocks(user.id)
    needs_onboarding = blocks == []
    today = Date.utc_today()
    week_start = today

    {:ok,
     socket
     |> assign(:week_start, week_start)
     |> assign(:today, today)
     |> assign(:blocks, blocks)
     |> assign(:needs_onboarding, needs_onboarding)
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
     |> assign(:show_voice_panel, needs_onboarding)
     |> assign(:preview_modal_open, false)}
  end

  @impl true
  def handle_event("generate_preview", _params, socket) do
    user = socket.assigns.current_user
    blocks = socket.assigns.blocks

    case Hammer.check_rate("preview_digest:#{user.id}", :timer.hours(24), 3) do
      {:allow, _count} ->
        socket =
          socket
          |> assign(:preview_modal_open, true)
          |> assign(:preview_html, Phoenix.LiveView.AsyncResult.loading())
          |> assign_async(:preview_html, fn ->
            # Passing an empty {} context map for previews since they don't persist
            sections = CheckDay.Digests.ContentFetcher.fetch_all(blocks, %{})
            html = CheckDay.Digests.DigestEmail.render_html(user, Date.utc_today(), sections)
            {:ok, %{preview_html: html}}
          end)

        {:noreply, socket}

      {:deny, _limit} ->
        {:noreply,
         socket
         |> put_flash(:error, "You have reached your limit of 3 previews per 24 hours.")}
    end
  end

  def handle_event("close_preview", _params, socket) do
    {:noreply, assign(socket, :preview_modal_open, false)}
  end

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

  def handle_event("update_add_type", payload, socket) do
    type = Map.get(payload, "type") || Map.get(payload, "value") || "weather"
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

  def handle_event("update_edit_type", payload, socket) do
    type = Map.get(payload, "type") || Map.get(payload, "value") || "weather"
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

      case Ash.update(
             block,
             %{
               type: String.to_existing_atom(socket.assigns.edit_type),
               label: socket.assigns.edit_label,
               config: config
             },
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

    active_days = user.active_days || [1, 2, 3, 4, 5, 6, 7]
    skipped_dates = user.skipped_dates || []
    active_days_str = Enum.map_join(active_days, ", ", &day_of_week_name/1)

    skipped_dates_str =
      if skipped_dates == [],
        do: "None",
        else: Enum.map_join(skipped_dates, ", ", &Date.to_iso8601/1)

    case ElevenLabs.get_conversation_signed_link(agent_id: agent_id) do
      {:ok, %{body: %{"signed_url" => raw_signed_url}}} ->
        env = if CheckDayWeb.Endpoint.host() == "check.day", do: "production", else: "development"
        uri = URI.parse(raw_signed_url)

        query =
          URI.decode_query(uri.query || "") |> Map.put("environment", env) |> URI.encode_query()

        signed_url = URI.to_string(%{uri | query: query})

        opening_message =
          if blocks == [] do
            "Hey, welcome to Check.Day! I'm Maya. Let's build your morning digest — what do you usually check first thing when you wake up?"
          else
            "Welcome back to Check.Day! How can I change your morning digest for you today?"
          end

        {:noreply,
         socket
         |> assign(:conversation_status, :connecting)
         |> assign(:show_voice_panel, true)
         |> push_event("start_conversation", %{
           signed_url: signed_url,
           user_id: user.id,
           existing_blocks: existing_blocks,
           first_name: user.first_name || "",
           digest_time: first_digest_time(user.digest_times || default_digest_times()),
           active_days: active_days_str,
           skipped_dates: skipped_dates_str,
           opening_message: opening_message
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
    {:noreply, socket |> assign(:blocks, blocks) |> assign(:needs_onboarding, false)}
  end

  def handle_info({:digest_update, {:block_removed, _block}}, socket) do
    blocks = load_user_blocks(socket.assigns.current_user.id)
    {:noreply, assign(socket, :blocks, blocks)}
  end

  def handle_info({:digest_update, {:digest_times_changed, times}}, socket) do
    {:noreply, assign(socket, :digest_times, times)}
  end

  def handle_info({:digest_update, {:active_days_changed, new_days}}, socket) do
    {:noreply, assign(socket, :user_active_days, new_days)}
  end

  def handle_info({:digest_update, {:skipped_dates_changed, new_skipped}}, socket) do
    {:noreply, assign(socket, :skipped_dates, new_skipped)}
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

  defp maybe_save_timezone(socket, user) do
    timezone = get_connect_params(socket)["timezone"]

    if timezone && timezone != "" && user.timezone in [nil, "Etc/UTC"] do
      case Ash.update(user, %{timezone: timezone}, action: :update_profile, authorize?: false) do
        {:ok, _} -> socket
        {:error, _} -> socket
      end
    else
      socket
    end
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

  defp day_of_week_name(1), do: "Monday"
  defp day_of_week_name(2), do: "Tuesday"
  defp day_of_week_name(3), do: "Wednesday"
  defp day_of_week_name(4), do: "Thursday"
  defp day_of_week_name(5), do: "Friday"
  defp day_of_week_name(6), do: "Saturday"
  defp day_of_week_name(7), do: "Sunday"
  defp day_of_week_name(_), do: "Unknown"

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
    |> Enum.map(fn block ->
      "block_id: #{block.id}, type: #{block.type}, label: #{block.label}"
    end)
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
      _ -> "hero-square-3-stack-3d"
    end
  end

  defp type_bg(type) do
    case type do
      :weather ->
        "bg-sky-50/70 border-sky-200/60 dark:bg-sky-900/20 dark:border-sky-800/50 backdrop-blur-md shadow-sm"

      :news ->
        "bg-purple-50/70 border-purple-200/60 dark:bg-purple-900/20 dark:border-purple-800/50 backdrop-blur-md shadow-sm"

      :interest ->
        "bg-amber-50/70 border-amber-200/60 dark:bg-amber-900/20 dark:border-amber-800/50 backdrop-blur-md shadow-sm"

      :competitor ->
        "bg-red-50/70 border-red-200/60 dark:bg-red-900/20 dark:border-red-800/50 backdrop-blur-md shadow-sm"

      :stock ->
        "bg-emerald-50/70 border-emerald-200/60 dark:bg-emerald-900/20 dark:border-emerald-800/50 backdrop-blur-md shadow-sm"

      _ ->
        "bg-gray-50/70 border-gray-200/60 dark:bg-gray-800/30 dark:border-gray-700/50 backdrop-blur-md shadow-sm"
    end
  end

  defp type_icon_color(type) do
    case type do
      :weather -> "text-sky-600 dark:text-sky-400"
      :news -> "text-purple-600 dark:text-purple-400"
      :interest -> "text-amber-600 dark:text-amber-400"
      :competitor -> "text-red-600 dark:text-red-400"
      :stock -> "text-emerald-600 dark:text-emerald-400"
      _ -> "text-gray-600 dark:text-gray-400"
    end
  end

  defp type_label_color(type) do
    case type do
      :weather -> "text-sky-900 dark:text-sky-200"
      :news -> "text-purple-900 dark:text-purple-200"
      :interest -> "text-amber-900 dark:text-amber-200"
      :competitor -> "text-red-900 dark:text-red-200"
      :stock -> "text-emerald-900 dark:text-emerald-200"
      _ -> "text-gray-900 dark:text-gray-200"
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :days, week_days(assigns.week_start))

    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="w-full relative z-10 pt-4">
        <%= if @needs_onboarding do %>
          <%!-- Onboarding Welcome Banner --%>
          <div
            class="flex flex-col items-center justify-center min-h-[60vh] animate-[slideUp_0.8s_ease-out_forwards]"
            id="onboarding-banner"
          >
            <div class="relative mb-10 group cursor-default">
              <div class="absolute inset-0 bg-gradient-to-br from-[oklch(70%_0.213_47.604)] to-orange-500 dark:from-[oklch(70%_0.213_47.604)] dark:to-orange-600 rounded-full blur-2xl opacity-40 group-hover:opacity-60 transition-opacity duration-500">
              </div>
              <div class="relative w-28 h-28 rounded-full bg-gradient-to-br from-[oklch(70%_0.213_47.604)] to-orange-500 flex items-center justify-center shadow-2xl shadow-[oklch(70%_0.213_47.604)]/30 border border-white/20 dark:border-white/10 animate-[pulse_3s_ease-in-out_infinite]">
                <.icon name="hero-microphone" class="w-14 h-14 text-white" />
              </div>
              <div class="absolute -top-1 -right-1 w-7 h-7 rounded-full bg-green-400 border-[3px] border-gray-50 dark:border-[#0a0f18] animate-bounce shadow-md" />
            </div>

            <h1
              class="text-4xl sm:text-5xl font-black text-gray-900 dark:text-white mb-4 text-center tracking-tight"
              id="onboarding-title"
            >
              Welcome to
              <span class="bg-clip-text text-transparent bg-gradient-to-r from-[oklch(70%_0.213_47.604)] to-orange-400">
                Check.Day
              </span>
            </h1>
            <p class="text-lg sm:text-xl text-gray-600 dark:text-gray-300 mb-3 text-center max-w-lg font-medium">
              Let's set up your personalized daily digest.
            </p>
            <p class="text-base text-gray-500 dark:text-gray-400 mb-12 text-center max-w-md leading-relaxed">
              Click the
              <span class="font-semibold text-[oklch(70%_0.213_47.604)]">microphone button</span>
              in the bottom-right corner to start a conversation and your assistant will effortlessly configure everything for you.
            </p>

            <div class="flex items-center gap-2.5 px-6 py-3 rounded-full bg-white dark:bg-gray-900 border border-[oklch(70%_0.213_47.604)]/20 shadow-sm text-[oklch(60%_0.213_47.604)] dark:text-[oklch(75%_0.213_47.604)] text-sm font-semibold">
              <.icon name="hero-arrow-down-right" class="w-5 h-5 animate-bounce" />
              <span>Your voice assistant is waiting</span>
            </div>
          </div>
        <% else %>
          <%!-- Header --%>
          <div class="flex items-center justify-between mb-8">
            <div>
              <h1
                class="text-3xl font-black tracking-tight text-gray-900 dark:text-white"
                id="dashboard-title"
              >
                Your Week
              </h1>
              <div class="flex items-center gap-3 mt-1.5">
                <p
                  class="text-sm font-medium text-gray-500 dark:text-gray-400"
                  id="dashboard-subtitle"
                >
                  {month_label(@week_start)}
                </p>
              </div>
            </div>

            <div class="flex items-center gap-2">
              <button
                phx-click="generate_preview"
                class="hidden sm:flex items-center gap-2 px-4 py-2 mr-3 rounded-full cursor-pointer bg-[oklch(70%_0.213_47.604)] hover:bg-[#ea580c] transition-all duration-300 text-white font-semibold text-sm shadow-md hover:shadow-lg hover:-translate-y-0.5"
                id="preview-digest-btn"
              >
                <.icon name="hero-sparkles" class="w-4 h-4" />
                <span>Preview Digest</span>
              </button>

              <button
                phx-click="prev_week"
                class="p-2.5 rounded-full border border-gray-200/60 bg-white/70 cursor-pointer backdrop-blur-md dark:bg-gray-800/60 dark:border-gray-700/60 shadow-sm hover:shadow-md hover:border-gray-300/80 dark:hover:border-gray-600 hover:-translate-y-0.5 transition-all duration-300 text-gray-600 dark:text-gray-300"
                id="prev-week-btn"
              >
                <.icon name="hero-chevron-left" class="w-5 h-5" />
              </button>

              <button
                phx-click="this_week"
                class="px-5 py-2.5 rounded-full border border-gray-200/60 bg-white/70 cursor-pointerbackdrop-blur-md text-sm font-semibold text-gray-700 shadow-sm dark:bg-gray-800/60 dark:border-gray-700/60 dark:text-gray-200 hover:shadow-md hover:border-gray-300/80 dark:hover:border-gray-600 hover:-translate-y-0.5 transition-all duration-300"
                id="this-week-btn"
              >
                Today
              </button>

              <button
                phx-click="next_week"
                class="p-2.5 rounded-full border border-gray-200/60 bg-white/70 backdrop-blur-md cursor-pointer dark:bg-gray-800/60 dark:border-gray-700/60 shadow-sm hover:shadow-md hover:border-gray-300/80 dark:hover:border-gray-600 hover:-translate-y-0.5 transition-all duration-300 text-gray-600 dark:text-gray-300"
                id="next-week-btn"
              >
                <.icon name="hero-chevron-right" class="w-5 h-5" />
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
                  "rounded-3xl border flex flex-col min-h-[420px] transition-all duration-300 relative overflow-hidden group/day",
                  cond do
                    is_disabled ->
                      "border-gray-200/50 bg-gray-50/40 opacity-50 dark:border-gray-800/50 dark:bg-gray-900/40 backdrop-blur-md"

                    day == @today ->
                      "border-[oklch(70%_0.213_47.604)]/40 bg-white/80 shadow-xl ring-1 ring-[oklch(70%_0.213_47.604)]/20 dark:border-[oklch(70%_0.213_47.604)]/50 dark:bg-gray-900/60 backdrop-blur-xl dark:ring-[oklch(70%_0.213_47.604)]/30 z-10"

                    true ->
                      "border-gray-200/60 bg-white/70 hover:shadow-lg dark:border-gray-800/60 dark:bg-gray-900/40 backdrop-blur-xl hover:border-gray-300/60 dark:hover:border-gray-700/60"
                  end
                ]}
                id={"day-#{day}"}
              >
                <%= if day == @today do %>
                  <div class="absolute inset-0 bg-gradient-to-b from-[oklch(70%_0.213_47.604)]/5 to-transparent rounded-3xl opacity-100 pointer-events-none">
                  </div>
                <% else %>
                  <div class="absolute inset-0 bg-gradient-to-b from-gray-500/5 to-transparent rounded-3xl opacity-0 group-hover/day:opacity-100 transition-opacity duration-500 pointer-events-none">
                  </div>
                <% end %>

                <%!-- Day Header --%>
                <div
                  class={[
                    "px-4 py-4 border-b shrink-0 relative z-10 transition-all duration-300",
                    cond do
                      is_disabled ->
                        "border-gray-200/50 bg-gray-100/30 dark:border-gray-800/50 dark:bg-gray-800/30"

                      day == @today ->
                        "border-[oklch(70%_0.213_47.604)]/20 bg-[oklch(70%_0.213_47.604)]/5 dark:border-[oklch(70%_0.213_47.604)]/30 dark:bg-[oklch(70%_0.213_47.604)]/10"

                      true ->
                        "border-gray-100/80 dark:border-gray-800/80 bg-white/40 dark:bg-gray-800/20"
                    end
                  ]}
                  id={"day-header-#{day}"}
                >
                  <%!-- Menu icon button --%>
                  <button
                    phx-click="toggle_day_menu"
                    phx-value-date={Date.to_iso8601(day)}
                    class={[
                      "absolute top-3 right-3 p-1.5 rounded-lg cursor-pointer",
                      "hover:bg-gray-200/60 transition-all duration-200 dark:hover:bg-gray-700/60",
                      "text-gray-400 hover:text-gray-600 dark:text-gray-500 dark:hover:text-gray-300"
                    ]}
                    id={"day-menu-btn-#{day}"}
                  >
                    <.icon name="hero-ellipsis-horizontal" class="w-5 h-5" />
                  </button>

                  <%!-- Centered day name + number --%>
                  <div class="text-center mt-2">
                    <p class={[
                      "text-xs font-bold uppercase tracking-widest",
                      cond do
                        is_disabled ->
                          "text-gray-400 line-through dark:text-gray-500"

                        day == @today ->
                          "text-[oklch(70%_0.213_47.604)] dark:text-[oklch(75%_0.213_47.604)]"

                        true ->
                          "text-gray-400 dark:text-gray-500"
                      end
                    ]}>
                      {day_name(day)}
                    </p>
                    <p class={[
                      "text-2xl font-black mt-0.5",
                      cond do
                        is_disabled -> "text-gray-400 dark:text-gray-500"
                        day == @today -> "text-gray-900 dark:text-white"
                        true -> "text-gray-800 dark:text-gray-200"
                      end
                    ]}>
                      {day_number(day)}
                    </p>
                    <%= unless is_disabled do %>
                      <form
                        phx-change="update_digest_time"
                        id={"time-form-#{day}"}
                        class="flex items-center justify-center mt-3"
                      >
                        <input
                          type="hidden"
                          name="day"
                          value={Integer.to_string(Date.day_of_week(day))}
                        />
                        <input
                          type="time"
                          value={get_day_time(@digest_times, day)}
                          phx-debounce="500"
                          name="time"
                          id={"time-#{day}"}
                          phx-hook=".TimePicker"
                          class="text-[13px] font-semibold text-[oklch(70%_0.213_47.604)] bg-[oklch(70%_0.213_47.604)]/5 border border-[oklch(70%_0.213_47.604)]/20 rounded-md px-2 py-1 cursor-pointer focus:ring-2 focus:ring-[oklch(70%_0.213_47.604)]/50 focus:border-[oklch(70%_0.213_47.604)] focus:outline-none w-[90px] text-center shadow-sm dark:bg-[oklch(70%_0.213_47.604)]/10 dark:text-[oklch(75%_0.213_47.604)] dark:border-[oklch(70%_0.213_47.604)]/30 transition-all hover:bg-[oklch(70%_0.213_47.604)]/10"
                        />
                      </form>
                    <% end %>
                  </div>

                  <%!-- Status badge below number --%>
                  <%= cond do %>
                    <% is_weekly_off -> %>
                      <div class="text-center mt-2.5">
                        <span class="text-[10px] px-2 py-0.5 rounded-full bg-orange-100/80 text-orange-700 font-medium dark:bg-orange-900/50 dark:text-orange-300 border border-orange-200/50 dark:border-orange-800/50 shadow-sm">
                          Every {day_name(day)} off
                        </span>
                      </div>
                    <% is_date_skipped -> %>
                      <div class="text-center mt-2.5">
                        <span class="text-[10px] px-2 py-0.5 rounded-full bg-red-100/80 text-red-700 font-medium dark:bg-red-900/50 dark:text-red-300 border border-red-200/50 dark:border-red-800/50 shadow-sm">
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
                      "absolute top-12 right-2 z-30",
                      "bg-white/90 backdrop-blur-xl rounded-2xl shadow-xl border border-gray-200/60 p-1.5 w-52 dark:bg-gray-800/90 dark:border-gray-700/60",
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
                        "flex items-center gap-3 w-full px-3 py-2.5 rounded-xl text-left text-sm cursor-pointer",
                        "transition-all duration-200",
                        if(is_date_skipped,
                          do:
                            "bg-red-50 text-red-700 hover:bg-red-100 dark:bg-red-950/40 dark:text-red-400 dark:hover:bg-red-900/60",
                          else:
                            "text-gray-700 hover:bg-gray-50 dark:text-gray-300 dark:hover:bg-gray-700/50"
                        )
                      ]}
                      id={"skip-date-#{day}"}
                    >
                      <.icon
                        name={
                          if(is_date_skipped,
                            do: "hero-arrow-uturn-left",
                            else: "hero-calendar-solid"
                          )
                        }
                        class="w-4 h-4 shrink-0"
                      />
                      <div>
                        <p class="font-medium leading-tight">
                          {if is_date_skipped, do: "Unskip date", else: "Skip this date"}
                        </p>
                        <p class="text-[10px] opacity-70 leading-tight mt-0.5">
                          {Calendar.strftime(day, "%b %d")} only
                        </p>
                      </div>
                    </button>

                    <div class="h-px bg-gray-100 dark:bg-gray-700/50 mx-2 my-1" />

                    <%!-- Toggle this day every week --%>
                    <button
                      phx-click="toggle_weekly_day"
                      phx-value-day={Date.day_of_week(day)}
                      class={[
                        "flex items-center gap-3 w-full px-3 py-2.5 rounded-xl text-left text-sm cursor-pointer",
                        "transition-all duration-200",
                        if(is_weekly_off,
                          do:
                            "bg-orange-50 text-orange-700 hover:bg-orange-100 dark:bg-orange-950/40 dark:text-orange-400 dark:hover:bg-orange-900/60",
                          else:
                            "text-gray-700 hover:bg-gray-50 dark:text-gray-300 dark:hover:bg-gray-700/50"
                        )
                      ]}
                      id={"toggle-weekly-#{day}"}
                    >
                      <.icon
                        name={
                          if(is_weekly_off,
                            do: "hero-arrow-uturn-left",
                            else: "hero-arrow-path-rounded-square"
                          )
                        }
                        class="w-4 h-4 shrink-0"
                      />
                      <div>
                        <p class="font-medium leading-tight">
                          {if is_weekly_off,
                            do: "Enable #{full_day_name(day)}s",
                            else: "Skip #{full_day_name(day)}s"}
                        </p>
                        <p class="text-[10px] opacity-70 leading-tight mt-0.5">
                          Recurring weekly
                        </p>
                      </div>
                    </button>
                  </div>
                <% end %>

                <%!-- Digest Blocks --%>
                <div
                  class="p-3 flex-1 space-y-2 overflow-y-auto relative z-10"
                  id={"day-blocks-#{day}"}
                >
                  <%= if is_disabled do %>
                    <div class="flex flex-col items-center justify-center h-full text-gray-300 dark:text-gray-600">
                      <.icon name="hero-moon-solid" class="w-6 h-6 mb-2 opacity-50" />
                      <p class="text-[11px] font-medium uppercase tracking-wider">Day off</p>
                    </div>
                  <% else %>
                    <%= if @blocks == [] do %>
                      <div class="flex flex-col items-center justify-center h-full text-gray-300 dark:text-gray-600">
                        <.icon name="hero-inbox-solid" class="w-6 h-6 mb-2 opacity-50" />
                        <p class="text-[11px] font-medium uppercase tracking-wider">No blocks</p>
                      </div>
                    <% else %>
                      <%= for block <- @blocks do %>
                        <% is_block_active = block_active_on_day?(block, day) %>
                        <button
                          phx-click="toggle_block_day"
                          phx-value-block-id={block.id}
                          phx-value-day={Date.day_of_week(day)}
                          class={[
                            "flex items-center gap-2.5 p-2 rounded-xl border w-full text-left",
                            "transition-all duration-300 group/block cursor-pointer",
                            if(is_block_active,
                              do: ["hover:scale-[1.02]", type_bg(block.type)],
                              else:
                                "bg-gray-50/50 border-gray-200/50 opacity-40 hover:opacity-70 dark:bg-gray-800/30 dark:border-gray-700/50 hover:scale-[1.02]"
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
                            "text-xs font-semibold truncate flex-1 tracking-tight",
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
          <div class="mt-12 relative z-10" id="block-management">
            <div class="flex items-center justify-between mb-8">
              <h2 class="text-2xl font-black tracking-tight text-gray-900 dark:text-white">
                Digest Blocks
              </h2>
              <button
                phx-click="toggle_add_form"
                class={[
                  "inline-flex items-center gap-2 px-5 py-2.5 rounded-full text-sm font-semibold shadow-sm cursor-pointer",
                  "bg-white/80 text-gray-700 border border-gray-200/60 dark:bg-gray-800/80 dark:text-gray-200 dark:border-gray-700/60 backdrop-blur-md",
                  "hover:shadow-md hover:border-[oklch(70%_0.213_47.604)]/40 dark:hover:border-[oklch(70%_0.213_47.604)]/40 hover:-translate-y-0.5 hover:text-[oklch(70%_0.213_47.604)] dark:hover:text-[oklch(75%_0.213_47.604)]",
                  "transition-all duration-300"
                ]}
                id="toggle-add-form-btn"
              >
                <.icon
                  name={if(@show_add_form, do: "hero-x-mark-solid", else: "hero-plus-solid")}
                  class="w-4 h-4"
                />
                {if @show_add_form, do: "Cancel", else: "Add Block"}
              </button>
            </div>

            <%= if @show_add_form do %>
              <div
                class="mb-8 p-6 sm:p-8 rounded-3xl border border-[oklch(70%_0.213_47.604)]/20 bg-white/70 shadow-2xl shadow-[oklch(70%_0.213_47.604)]/5 backdrop-blur-xl dark:border-[oklch(70%_0.213_47.604)]/30 dark:bg-gray-900/70"
                id="add-block-form"
              >
                <h3 class="text-lg font-bold text-gray-900 dark:text-white mb-6 flex items-center gap-2">
                  <.icon
                    name="hero-squares-plus-solid"
                    class="w-5 h-5 text-[oklch(70%_0.213_47.604)] dark:text-[oklch(75%_0.213_47.604)]"
                  /> New Block
                </h3>
                <div class="grid grid-cols-1 sm:grid-cols-3 gap-5">
                  <div>
                    <label class="block text-xs font-semibold uppercase tracking-wider text-gray-500 dark:text-gray-400 mb-2">
                      Type
                    </label>
                    <form phx-change="update_add_type" class="relative">
                      <select
                        name="type"
                        id="add-block-type"
                        class="w-full appearance-none rounded-xl border border-gray-200/80 bg-white/50 px-4 py-2.5 text-sm font-medium text-gray-800 shadow-sm focus:ring-2 focus:ring-[oklch(70%_0.213_47.604)]/50 focus:border-[oklch(70%_0.213_47.604)] dark:bg-gray-800/50 dark:border-gray-700/80 dark:text-gray-200 backdrop-blur-sm transition-all outline-none"
                      >
                        <option value="weather" selected={@add_type == "weather"}>☀️ Weather</option>
                        <option value="news" selected={@add_type == "news"}>📰 News</option>
                        <option value="interest" selected={@add_type == "interest"}>
                          ✨ Interest
                        </option>
                        <option value="competitor" selected={@add_type == "competitor"}>
                          🏢 Competitor
                        </option>
                        <option value="stock" selected={@add_type == "stock"}>📈 Stock</option>
                      </select>
                      <.icon
                        name="hero-chevron-down"
                        class="w-4 h-4 absolute right-3 top-3 text-gray-500 pointer-events-none"
                      />
                    </form>
                  </div>
                  <div class="sm:col-span-2">
                    <label class="block text-xs font-semibold uppercase tracking-wider text-gray-500 dark:text-gray-400 mb-2">
                      Label
                    </label>
                    <input
                      type="text"
                      value={@add_label}
                      phx-keyup="update_add_label"
                      phx-key=""
                      name="label"
                      id="add-block-label"
                      placeholder="e.g. Amsterdam Weather"
                      class="w-full rounded-xl border border-gray-200/80 bg-white/50 px-4 py-2.5 text-sm font-medium text-gray-800 placeholder-gray-400 shadow-sm focus:ring-2 focus:ring-[oklch(70%_0.213_47.604)]/50 focus:border-[oklch(70%_0.213_47.604)] dark:bg-gray-800/50 dark:border-gray-700/80 dark:text-gray-200 dark:placeholder-gray-500 backdrop-blur-sm transition-all outline-none"
                    />
                  </div>
                </div>
                <%!-- Config Key/Value Rows --%>
                <div class="mt-6">
                  <div class="flex items-center justify-between mb-3 border-b border-gray-100 dark:border-gray-800/50 pb-2">
                    <label class="block text-xs font-semibold uppercase tracking-wider text-gray-500 dark:text-gray-400">
                      Configuration
                      <span class="text-gray-400 dark:text-gray-600 font-normal normal-case tracking-normal ml-1">
                        (Optional rules)
                      </span>
                    </label>
                    <button
                      phx-click="add_config_row"
                      type="button"
                      class="text-xs text-[oklch(70%_0.213_47.604)] hover:text-[oklch(60%_0.213_47.604)] font-bold transition-colors dark:text-[oklch(75%_0.213_47.604)] flex items-center gap-1"
                      id="add-config-row-btn"
                    >
                      <.icon name="hero-plus" class="w-3.5 h-3.5" /> Add Field
                    </button>
                  </div>
                  <div class="space-y-2 mt-3">
                    <%= for {row, idx} <- Enum.with_index(@add_config_rows) do %>
                      <div class="flex items-center gap-3" id={"add-config-row-#{idx}"}>
                        <input
                          type="text"
                          value={row.key}
                          phx-keyup="update_add_config_key"
                          phx-value-index={idx}
                          phx-key=""
                          placeholder="Key (e.g. topic)"
                          id={"add-config-key-#{idx}"}
                          class="flex-1 rounded-xl border border-gray-200/80 bg-white/50 px-4 py-2 text-sm font-medium text-gray-800 placeholder-gray-400 focus:ring-2 focus:ring-[oklch(70%_0.213_47.604)]/50 focus:border-[oklch(70%_0.213_47.604)] dark:bg-gray-800/50 dark:border-gray-700/80 dark:text-gray-200 backdrop-blur-sm transition-all outline-none"
                        />
                        <input
                          type="text"
                          value={row.value}
                          phx-keyup="update_add_config_value"
                          phx-value-index={idx}
                          phx-key=""
                          placeholder="Value (e.g. AI News)"
                          id={"add-config-val-#{idx}"}
                          class="flex-[2] rounded-xl border border-gray-200/80 bg-white/50 px-4 py-2 text-sm font-medium text-gray-800 placeholder-gray-400 focus:ring-2 focus:ring-[oklch(70%_0.213_47.604)]/50 focus:border-[oklch(70%_0.213_47.604)] dark:bg-gray-800/50 dark:border-gray-700/80 dark:text-gray-200 backdrop-blur-sm transition-all outline-none"
                        />
                        <button
                          phx-click="remove_add_config_row"
                          phx-value-index={idx}
                          type="button"
                          class="p-2 cursor-pointer text-gray-400 hover:text-red-500 hover:bg-red-50 dark:hover:bg-red-900/20 rounded-lg transition-all"
                          id={"remove-add-config-#{idx}"}
                        >
                          <.icon name="hero-trash-solid" class="w-4 h-4" />
                        </button>
                      </div>
                    <% end %>
                  </div>
                </div>
                <div class="mt-8 flex justify-end">
                  <button
                    phx-click="add_block"
                    disabled={@add_label == ""}
                    class={[
                      "inline-flex items-center gap-2 px-6 py-3 rounded-full text-sm font-bold transition-all duration-300 shadow-md",
                      if(@add_label == "",
                        do:
                          "bg-gray-200 text-gray-400 cursor-not-allowed dark:bg-gray-800 dark:text-gray-600 shadow-none",
                        else:
                          "bg-gradient-to-r from-[oklch(70%_0.213_47.604)] to-orange-500 text-white hover:shadow-lg hover:shadow-[oklch(70%_0.213_47.604)]/20 hover:-translate-y-0.5"
                      )
                    ]}
                    id="submit-add-block-btn"
                  >
                    <.icon name="hero-plus-circle-solid" class="w-5 h-5" /> Add Block
                  </button>
                </div>
              </div>
            <% end %>

            <%= if @blocks == [] do %>
              <div
                class="flex flex-col items-center justify-center py-20 px-4 rounded-3xl border-2 border-dashed border-gray-200/60 bg-white/40 backdrop-blur-sm dark:border-gray-800/60 dark:bg-gray-900/30"
                id="empty-state"
              >
                <div class="w-20 h-20 bg-gray-100 dark:bg-gray-800 rounded-full flex items-center justify-center mb-6 shadow-inner">
                  <.icon
                    name="hero-inbox-solid"
                    class="w-10 h-10 text-gray-300 dark:text-gray-600"
                  />
                </div>
                <h3 class="text-xl font-bold text-gray-700 dark:text-gray-200 mb-2 tracking-tight">
                  No digest blocks yet
                </h3>
                <p class="text-gray-500 dark:text-gray-400 max-w-sm text-center font-medium">
                  Click <span class="text-gray-700 dark:text-gray-300">"Add Block"</span>
                  above to start assembling your perfect morning routine.
                </p>
              </div>
            <% else %>
              <div
                class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-4"
                id="block-list"
              >
                <%= for block <- @blocks do %>
                  <%= if @editing_block_id == block.id do %>
                    <div
                      class="rounded-3xl border border-[oklch(70%_0.213_47.604)]/30 bg-white/80 shadow-2xl backdrop-blur-xl dark:border-[oklch(70%_0.213_47.604)]/40 dark:bg-gray-900/80 p-6 sm:p-8 col-span-full ring-2 ring-[oklch(70%_0.213_47.604)]/10 animate-[fadeIn_0.2s_ease-out] relative overflow-hidden"
                      id={"manage-block-#{block.id}"}
                    >
                      <div class="absolute -right-10 -top-10 w-40 h-40 bg-[oklch(70%_0.213_47.604)]/10 blur-[50px] rounded-full pointer-events-none">
                      </div>
                      <h3 class="text-lg font-bold text-gray-900 dark:text-white mb-6 flex items-center gap-2 relative z-10">
                        <.icon
                          name="hero-pencil-square-solid"
                          class="w-5 h-5 text-[oklch(70%_0.213_47.604)]"
                        /> Edit Block
                      </h3>
                      <div class="space-y-6 relative z-10">
                        <div class="grid grid-cols-1 sm:grid-cols-3 gap-5">
                          <div>
                            <label class="block text-xs font-semibold uppercase tracking-wider text-gray-500 dark:text-gray-400 mb-2">
                              Type
                            </label>
                            <form phx-change="update_edit_type" class="relative">
                              <select
                                name="type"
                                id={"edit-type-#{block.id}"}
                                class="w-full appearance-none rounded-xl border border-gray-200/80 bg-white/50 px-4 py-2.5 text-sm font-medium text-gray-800 shadow-sm focus:ring-2 focus:ring-[oklch(70%_0.213_47.604)]/50 focus:border-[oklch(70%_0.213_47.604)] dark:bg-gray-800/50 dark:border-gray-700/80 dark:text-gray-200 backdrop-blur-sm transition-all outline-none"
                              >
                                <option value="weather" selected={@edit_type == "weather"}>
                                  ☀️ Weather
                                </option>
                                <option value="news" selected={@edit_type == "news"}>📰 News</option>
                                <option value="interest" selected={@edit_type == "interest"}>
                                  ✨ Interest
                                </option>
                                <option value="competitor" selected={@edit_type == "competitor"}>
                                  🏢 Competitor
                                </option>
                                <option value="stock" selected={@edit_type == "stock"}>
                                  📈 Stock
                                </option>
                              </select>
                              <.icon
                                name="hero-chevron-down"
                                class="w-4 h-4 absolute right-3 top-3 text-gray-500 pointer-events-none"
                              />
                            </form>
                          </div>
                          <div class="sm:col-span-2">
                            <label class="block text-xs font-semibold uppercase tracking-wider text-gray-500 dark:text-gray-400 mb-2">
                              Label
                            </label>
                            <input
                              type="text"
                              value={@edit_label}
                              phx-keyup="update_edit_label"
                              phx-key=""
                              name="label"
                              id={"edit-label-#{block.id}"}
                              class="w-full rounded-xl border border-gray-200/80 bg-white/50 px-4 py-2.5 text-sm font-medium text-gray-800 placeholder-gray-400 shadow-sm focus:ring-2 focus:ring-[oklch(70%_0.213_47.604)]/50 focus:border-[oklch(70%_0.213_47.604)] dark:bg-gray-800/50 dark:border-gray-700/80 dark:text-gray-200 dark:placeholder-gray-500 backdrop-blur-sm transition-all outline-none"
                            />
                          </div>
                        </div>
                        <div>
                          <div class="flex items-center justify-between mb-3 border-b border-gray-100 dark:border-gray-800/50 pb-2">
                            <label class="block text-xs font-semibold uppercase tracking-wider text-gray-500 dark:text-gray-400">
                              Configuration
                            </label>
                            <button
                              phx-click="add_edit_config_row"
                              type="button"
                              class="text-xs text-[oklch(70%_0.213_47.604)] hover:text-[oklch(60%_0.213_47.604)] font-bold transition-colors dark:text-[oklch(75%_0.213_47.604)] flex items-center gap-1"
                              id={"add-edit-config-row-#{block.id}"}
                            >
                              <.icon name="hero-plus" class="w-3.5 h-3.5" /> Add Field
                            </button>
                          </div>
                          <div class="space-y-2 mt-3">
                            <%= for {row, idx} <- Enum.with_index(@edit_config_rows) do %>
                              <div
                                class="flex items-center gap-3"
                                id={"edit-config-row-#{block.id}-#{idx}"}
                              >
                                <input
                                  type="text"
                                  value={row.key}
                                  phx-keyup="update_edit_config_key"
                                  phx-value-index={idx}
                                  phx-key=""
                                  placeholder="Key"
                                  id={"edit-config-key-#{block.id}-#{idx}"}
                                  class="flex-1 rounded-xl border border-gray-200/80 bg-white/50 px-4 py-2 text-sm font-medium text-gray-800 placeholder-gray-400 focus:ring-2 focus:ring-[oklch(70%_0.213_47.604)]/50 focus:border-[oklch(70%_0.213_47.604)] dark:bg-gray-800/50 dark:border-gray-700/80 dark:text-gray-200 backdrop-blur-sm transition-all outline-none"
                                />
                                <input
                                  type="text"
                                  value={row.value}
                                  phx-keyup="update_edit_config_value"
                                  phx-value-index={idx}
                                  phx-key=""
                                  placeholder="Value"
                                  id={"edit-config-val-#{block.id}-#{idx}"}
                                  class="flex-[2] rounded-xl border border-gray-200/80 bg-white/50 px-4 py-2 text-sm font-medium text-gray-800 placeholder-gray-400 focus:ring-2 focus:ring-[oklch(70%_0.213_47.604)]/50 focus:border-[oklch(70%_0.213_47.604)] dark:bg-gray-800/50 dark:border-gray-700/80 dark:text-gray-200 backdrop-blur-sm transition-all outline-none"
                                />
                                <button
                                  phx-click="remove_edit_config_row"
                                  phx-value-index={idx}
                                  type="button"
                                  class="p-2 text-gray-400 hover:text-red-500 hover:bg-red-50 dark:hover:bg-red-900/20 rounded-lg transition-all cursor-pointer"
                                  id={"remove-edit-config-#{block.id}-#{idx}"}
                                >
                                  <.icon name="hero-trash-solid" class="w-4 h-4" />
                                </button>
                              </div>
                            <% end %>
                          </div>
                        </div>
                        <div class="flex gap-3 justify-end mt-4 pt-4 border-t border-gray-100 dark:border-gray-800/50">
                          <button
                            phx-click="cancel_edit"
                            class="px-5 py-2.5 rounded-full text-sm font-semibold text-gray-600 bg-gray-100 hover:bg-gray-200 transition-all dark:text-gray-300 dark:bg-gray-800 dark:hover:bg-gray-700 cursor-pointer"
                            id={"cancel-edit-#{block.id}"}
                          >
                            Cancel
                          </button>
                          <button
                            phx-click="save_edit"
                            class="px-8 py-2.5 rounded-full text-sm font-bold text-white bg-gradient-to-r from-[oklch(70%_0.213_47.604)] to-orange-500 shadow-md hover:shadow-lg hover:-translate-y-0.5 transition-all cursor-pointer"
                            id={"save-edit-#{block.id}"}
                          >
                            Save Changes
                          </button>
                        </div>
                      </div>
                    </div>
                  <% else %>
                    <div
                      class={[
                        "rounded-3xl border p-5 transition-all duration-300 group/block relative overflow-hidden",
                        "hover:-translate-y-1 hover:shadow-xl",
                        type_bg(block.type)
                      ]}
                      id={"manage-block-#{block.id}"}
                    >
                      <div class="absolute inset-0 bg-white/30 dark:bg-white/5 opacity-0 group-hover/block:opacity-100 transition-opacity duration-300 pointer-events-none">
                      </div>
                      <div class="flex items-start gap-4 relative z-10">
                        <div class={["shrink-0 mt-0.5", type_icon_color(block.type)]}>
                          <.icon name={type_icon(block.type)} class="w-7 h-7 drop-shadow-sm" />
                        </div>
                        <div class="flex-1 min-w-0">
                          <p class={[
                            "font-bold text-base truncate tracking-tight mb-0.5",
                            type_label_color(block.type)
                          ]}>
                            {block.label}
                          </p>
                          <p class="text-[11px] font-bold uppercase tracking-wider text-opacity-70 dark:text-opacity-70 mb-2">
                            {block.type}
                          </p>
                          <%= if block.config && block.config != %{} do %>
                            <div class="flex flex-wrap gap-1.5">
                              <%= for {k, v} <- block.config do %>
                                <span class="inline-flex items-center px-2 py-0.5 rounded-md text-[10px] font-medium bg-black/5 text-black/60 dark:bg-white/10 dark:text-white/70 border border-black/5 dark:border-white/5 backdrop-blur-sm">
                                  {k}: {v}
                                </span>
                              <% end %>
                            </div>
                          <% end %>
                        </div>
                        <div class="flex flex-col sm:flex-row items-center gap-1.5 shrink-0 opacity-0 group-hover/block:opacity-100 transition-opacity duration-200">
                          <button
                            phx-click="start_edit"
                            phx-value-block-id={block.id}
                            class="p-2 rounded-xl text-gray-500 bg-white/50 hover:text-[oklch(70%_0.213_47.604)] hover:bg-white shadow-sm transition-all dark:bg-gray-800/50 dark:hover:bg-gray-800 dark:hover:text-[oklch(75%_0.213_47.604)] cursor-pointer"
                            id={"edit-btn-#{block.id}"}
                          >
                            <.icon name="hero-pencil-solid" class="w-4 h-4" />
                          </button>
                          <button
                            phx-click="delete_block"
                            phx-value-block-id={block.id}
                            data-confirm="Remove this block from your digest?"
                            class="p-2 rounded-xl text-gray-500 bg-white/50 hover:text-red-500 hover:bg-white shadow-sm transition-all dark:bg-gray-800/50 dark:hover:bg-gray-800 dark:hover:text-red-400 cursor-pointer"
                            id={"delete-btn-#{block.id}"}
                          >
                            <.icon name="hero-trash-solid" class="w-4 h-4" />
                          </button>
                        </div>
                      </div>
                    </div>
                  <% end %>
                <% end %>
              </div>
            <% end %>
          </div>
        <% end %>

        <%!-- Floating Voice Assistant --%>
        <div id="voice-assistant-container" class="relative z-50">
          <%!-- ElevenLabs Hook (hidden, for managing the conversation) --%>
          <div
            id="dashboard-elevenlabs-hook"
            phx-hook=".DashboardElevenLabs"
            phx-update="ignore"
            class="hidden"
          />

          <%!-- Floating Mic Button --%>
          <%= unless @show_voice_panel do %>
            <button
              phx-click="toggle_voice_panel"
              class={[
                "fixed bottom-8 right-8 z-50 w-16 h-16 rounded-full flex items-center justify-center cursor-pointer",
                "bg-gradient-to-br from-[oklch(70%_0.213_47.604)] to-orange-500 text-white",
                "hover:scale-110",
                "transition-all duration-300 shadow-2xl shadow-[oklch(70%_0.213_47.604)]/40 dark:shadow-[oklch(70%_0.213_47.604)]/30",
                "focus:outline-none focus:ring-4 focus:ring-[oklch(70%_0.213_47.604)]/50",
                "group",
                @needs_onboarding &&
                  "ring-4 ring-[oklch(70%_0.213_47.604)]/30 ring-offset-2 dark:ring-offset-gray-900 animate-pulse"
              ]}
              id="voice-fab-btn"
            >
              <.icon
                name="hero-microphone-solid"
                class="w-7 h-7 group-hover:scale-110 transition-transform"
              />
            </button>
          <% end %>

          <%!-- Voice Panel (slide-up from bottom-right) --%>
          <%= if @show_voice_panel do %>
            <div
              class={[
                "fixed bottom-8 right-8 z-50 w-[380px] rounded-3xl overflow-hidden backdrop-blur-3xl",
                "bg-white/80 dark:bg-gray-900/80 border border-gray-200/60 dark:border-gray-800/60",
                "shadow-2xl shadow-gray-400/30 dark:shadow-black/60 ring-1 ring-white/20",
                "animate-[slideUp_0.3s_ease-out]"
              ]}
              id="voice-panel"
            >
              <%!-- Panel Header --%>
              <div class={[
                "px-5 py-4 border-b flex items-center justify-between",
                if(@conversation_status in [:connected, :speaking, :listening],
                  do:
                    "border-[oklch(70%_0.213_47.604)]/30 bg-[oklch(70%_0.213_47.604)]/10 dark:border-[oklch(70%_0.213_47.604)]/30 dark:bg-[oklch(70%_0.213_47.604)]/10",
                  else: "border-gray-100 bg-gray-50/50 dark:border-gray-800/50 dark:bg-gray-800/50"
                )
              ]}>
                <div class="flex items-center gap-3">
                  <div class={[
                    "w-3 h-3 rounded-full shadow-sm",
                    if(@conversation_status in [:connected, :speaking, :listening],
                      do:
                        "bg-[oklch(70%_0.213_47.604)] animate-pulse shadow-[oklch(70%_0.213_47.604)]/50",
                      else: "bg-gray-400 dark:bg-gray-600"
                    )
                  ]} />
                  <span class="text-sm font-bold tracking-tight text-gray-800 dark:text-gray-200">
                    {status_text(@conversation_status)}
                  </span>
                </div>
                <button
                  phx-click="toggle_voice_panel"
                  class="p-2 rounded-full text-gray-400 hover:text-gray-700 hover:bg-gray-200/50 dark:hover:text-gray-300 dark:hover:bg-gray-700/50 transition-all"
                  id="close-voice-panel-btn"
                >
                  <.icon name="hero-x-mark-solid" class="w-5 h-5" />
                </button>
              </div>

              <%!-- Mic Control --%>
              <div class="flex flex-col items-center py-8 relative overflow-hidden">
                <div class="absolute inset-0 bg-gradient-to-b from-transparent to-black/5 dark:to-white/5 pointer-events-none">
                </div>
                <%= if @conversation_status == :idle do %>
                  <button
                    phx-click="start_conversation"
                    class={[
                      "w-24 h-24 rounded-full flex items-center justify-center cursor-pointer relative z-10",
                      "bg-gradient-to-br from-[oklch(70%_0.213_47.604)] to-orange-500 text-white",
                      "hover:scale-105",
                      "transition-all duration-300 shadow-xl shadow-[oklch(70%_0.213_47.604)]/30 dark:shadow-[oklch(70%_0.213_47.604)]/20",
                      "focus:outline-none focus:ring-4 focus:ring-[oklch(70%_0.213_47.604)]/40"
                    ]}
                    id="dashboard-start-conversation-btn"
                  >
                    <.icon name="hero-microphone-solid" class="w-10 h-10" />
                  </button>
                <% else %>
                  <button
                    phx-click="end_conversation"
                    class={[
                      "w-24 h-24 rounded-full flex items-center justify-center cursor-pointer relative z-10",
                      "bg-gradient-to-br from-red-500 to-rose-600 text-white",
                      "hover:from-red-600 hover:to-rose-700 hover:scale-105",
                      "transition-all duration-300 shadow-xl shadow-red-500/30 dark:shadow-red-900/40",
                      "focus:outline-none focus:ring-4 focus:ring-red-200 dark:focus:ring-red-800"
                    ]}
                    id="dashboard-end-conversation-btn"
                  >
                    <.icon name="hero-stop-solid" class="w-10 h-10" />
                  </button>
                <% end %>
                <p class="text-[13px] font-medium text-gray-500 dark:text-gray-400 mt-5 relative z-10">
                  <%= if @conversation_status == :idle do %>
                    Tap to talk — adjust blocks by voice
                  <% else %>
                    Tap to stop the conversation
                  <% end %>
                </p>
              </div>

              <%!-- Transcript --%>
              <div
                class="border-t border-gray-100 dark:border-gray-800/80 px-5 py-4 max-h-56 overflow-y-auto bg-gray-50/50 dark:bg-black/20"
                id="dashboard-transcript"
                phx-hook=".TranscriptScroll"
              >
                <div class="flex items-center gap-2 mb-3">
                  <.icon name="hero-chat-bubble-left-right-solid" class="w-4 h-4 text-gray-400" />
                  <h4 class="text-[11px] font-bold text-gray-500 dark:text-gray-400 uppercase tracking-widest">
                    Transcript
                  </h4>
                </div>
                <%= if @transcript == [] do %>
                  <p class="text-[13px] text-gray-400 dark:text-gray-500 italic text-center py-4">
                    Conversation will appear here...
                  </p>
                <% else %>
                  <div class="space-y-2">
                    <%= for entry <- @transcript do %>
                      <div class={[
                        "text-[13px] rounded-2xl px-3.5 py-2.5 max-w-[85%] leading-relaxed shadow-sm",
                        if(entry.source == "ai",
                          do:
                            "bg-white border border-gray-100 text-gray-800 mr-auto dark:bg-gray-800 dark:border-gray-700 dark:text-gray-200",
                          else: "bg-[oklch(70%_0.213_47.604)] text-white ml-auto"
                        )
                      ]}>
                        <span class={[
                          "font-bold block mb-0.5 text-[10px] uppercase tracking-wider opacity-70",
                          if(entry.source == "ai",
                            do: "text-[oklch(70%_0.213_47.604)] dark:text-[oklch(75%_0.213_47.604)]",
                            else: "text-white/80"
                          )
                        ]}>
                          {if entry.source == "ai", do: "Maya", else: "You"}
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
      <%!-- Preview Modal --%>
      <%= if @preview_modal_open do %>
        <div class="fixed inset-0 z-50 flex items-center justify-center bg-gray-900/60 backdrop-blur-sm p-4">
          <div class="relative w-full max-w-3xl max-h-[90vh] bg-white dark:bg-gray-800 rounded-3xl shadow-2xl flex flex-col animate-[slideUp_0.3s_ease-out]">
            <div class="flex items-center justify-between p-6 border-b border-gray-100 dark:border-gray-700">
              <div>
                <h3 class="text-xl font-bold text-gray-900 dark:text-white flex items-center gap-2">
                  <.icon name="hero-sparkles" class="w-6 h-6 text-[oklch(70%_0.213_47.604)]" />
                  Today's Digest Preview
                </h3>
                <p class="text-sm text-gray-500 mt-1">Rendered live exclusively for you.</p>
              </div>
              <button
                phx-click="close_preview"
                class="p-2 rounded-full hover:bg-gray-100 dark:hover:bg-gray-700 transition transition-colors text-gray-500 cursor-pointer"
              >
                <.icon name="hero-x-mark" class="w-6 h-6" />
              </button>
            </div>

            <div class="flex-1 p-6 overflow-hidden flex flex-col bg-gray-50 dark:bg-gray-900/50 rounded-b-3xl">
              <.async_result :let={payload} assign={@preview_html}>
                <:loading>
                  <div class="flex flex-col items-center justify-center py-20 h-full">
                    <div class="relative w-20 h-20 mb-6">
                      <div class="absolute inset-0 bg-[oklch(70%_0.213_47.604)] rounded-full animate-ping opacity-20">
                      </div>
                      <div class="absolute inset-2 bg-[oklch(70%_0.213_47.604)] rounded-full animate-pulse opacity-40">
                      </div>
                      <.icon
                        name="hero-arrow-path"
                        class="absolute inset-0 w-full h-full text-[oklch(70%_0.213_47.604)] animate-spin"
                      />
                    </div>
                    <h4 class="text-lg font-bold text-gray-900 dark:text-white mb-2">
                      Generating your Digest...
                    </h4>
                    <p class="text-sm text-gray-500 dark:text-gray-400 text-center max-w-sm">
                      We're crawling the web, synthesizing news, and fetching realtime metrics. This usually takes 15-40 seconds for a full dash.
                    </p>
                  </div>
                </:loading>
                <:failed :let={_reason}>
                  <div class="py-20 text-center text-red-500">
                    <.icon name="hero-exclamation-triangle" class="w-12 h-12 mx-auto mb-4" />
                    <p class="font-bold">Failed to load preview.</p>
                  </div>
                </:failed>

                <iframe
                  srcdoc={payload}
                  class="w-full h-full min-h-[500px] border border-gray-200 dark:border-gray-700 rounded-xl bg-white shadow-sm flex-1"
                >
                </iframe>
              </.async_result>
            </div>
          </div>
        </div>
      <% end %>
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

          this.handleEvent("start_conversation", async ({ signed_url, user_id, existing_blocks, first_name, digest_time, active_days, skipped_dates, opening_message }) => {
            try {
              await navigator.mediaDevices.getUserMedia({ audio: true });

              this.conversation = await Conversation.startSession({
                signedUrl: signed_url,
                dynamicVariables: {
                  user_id: user_id,
                  existing_blocks: existing_blocks,
                  first_name: first_name,
                  digest_time: digest_time,
                  active_days: active_days,
                  skipped_dates: skipped_dates,
                  opening_message: opening_message
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
