defmodule CheckDayWeb.OnboardingLive do
  use CheckDayWeb, :live_view

  alias CheckDay.Digests.DigestBlock

  require Ash.Query

  on_mount {CheckDayWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    if connected?(socket) do
      Phoenix.PubSub.subscribe(CheckDay.PubSub, "user:#{user.id}")
    end

    blocks = load_user_blocks(user.id)

    {:ok,
     socket
     |> assign(:conversation_status, :idle)
     |> assign(:first_name, user.first_name || "")
     |> assign(:digest_times, user.digest_times || default_digest_times())
     |> assign(:transcript, [])
     |> stream(:digest_blocks, blocks)
     |> assign(:blocks_empty?, blocks == [])}
  end

  @impl true
  def handle_event("start_conversation", _params, socket) do
    agent_id = Application.get_env(:check_day, :eleven_labs_agent_id)
    user = socket.assigns.current_user
    blocks = load_user_blocks(user.id)
    existing_blocks = format_blocks_for_agent(blocks)

    case ElevenLabs.get_conversation_signed_link(agent_id: agent_id) do
      {:ok, %{body: %{"signed_url" => signed_url}}} ->
        {:noreply,
         socket
         |> assign(:conversation_status, :connecting)
         |> push_event("start_conversation", %{
           signed_url: signed_url,
           user_id: user.id,
           existing_blocks: existing_blocks,
           first_name: user.first_name || "",
           digest_time: first_digest_time(user.digest_times || default_digest_times())
         })}

      {:ok, response} ->
        IO.inspect(response, label: "Unexpected response format")

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

  def handle_event("update_digest_time", %{"time" => time_str}, socket) do
    user = socket.assigns.current_user
    current_times = socket.assigns.digest_times
    # Set the same time for all days from onboarding
    new_times = Map.new(current_times, fn {k, _v} -> {k, time_str} end)

    case Ash.update(user, %{digest_times: new_times},
           action: :update_profile,
           authorize?: false
         ) do
      {:ok, _} -> {:noreply, assign(socket, :digest_times, new_times)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to update time")}
    end
  end

  # PubSub handlers for real-time updates from the API controller
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

  def handle_info({:digest_update, :onboarding_completed}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/dashboard")}
  end

  def handle_info({:digest_update, {:digest_times_changed, times}}, socket) do
    {:noreply, assign(socket, :digest_times, times)}
  end

  def handle_info({:digest_update, _}, socket), do: {:noreply, socket}

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

  defp first_digest_time(digest_times) do
    # Show the most common time (typically all are the same during onboarding)
    Map.get(digest_times, "1", "07:00")
  end

  defp format_blocks_for_agent([]), do: "None"

  defp format_blocks_for_agent(blocks) do
    blocks
    |> Enum.map(fn block -> "block_id: #{block.id}, type: #{block.type}, label: #{block.label}" end)
    |> Enum.join(", ")
  end

  defp load_user_blocks(user_id) do
    DigestBlock
    |> Ash.Query.filter(user_id == ^user_id)
    |> Ash.Query.sort(position: :asc)
    |> Ash.read!()
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
      :weather -> "bg-sky-100 text-sky-700 dark:bg-sky-900/40 dark:text-sky-400"
      :news -> "bg-purple-100 text-purple-700 dark:bg-purple-900/40 dark:text-purple-400"
      :interest -> "bg-amber-100 text-amber-700 dark:bg-amber-900/40 dark:text-amber-400"
      :competitor -> "bg-red-100 text-red-700 dark:bg-red-900/40 dark:text-red-400"
      :stock -> "bg-emerald-100 text-emerald-700 dark:bg-emerald-900/40 dark:text-emerald-400"
      :agenda -> "bg-blue-100 text-blue-700 dark:bg-blue-900/40 dark:text-blue-400"
      :habit -> "bg-green-100 text-green-700 dark:bg-green-900/40 dark:text-green-400"
      :custom -> "bg-gray-100 text-gray-700 dark:bg-gray-800 dark:text-gray-400"
      _ -> "bg-gray-100 text-gray-700 dark:bg-gray-800 dark:text-gray-400"
    end
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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="max-w-6xl mx-auto px-4 py-8">
        <%!-- Header --%>
        <div class="text-center mb-10">
          <h1 class="text-3xl font-bold text-gray-900 dark:text-gray-100 mb-2" id="onboarding-title">
            Set up your daily digest
          </h1>
          <p class="text-gray-500 dark:text-gray-400 text-lg" id="onboarding-subtitle">
            Have a conversation and I'll set up your personalized daily briefing.
          </p>
        </div>

        <div class="grid grid-cols-1 lg:grid-cols-2 gap-8">
          <%!-- Left: Voice Conversation --%>
          <div class="space-y-6">
            <%!-- Conversation Control Card --%>
            <div
              id="conversation-card"
              class={[
                "rounded-2xl border-2 p-8 transition-all duration-300",
                if(@conversation_status in [:connected, :speaking, :listening],
                  do: "border-indigo-300 bg-indigo-50/50 shadow-lg shadow-indigo-100 dark:border-indigo-700 dark:bg-indigo-950/30 dark:shadow-indigo-900/30",
                  else: "border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-800"
                )
              ]}
            >
              <%!-- Status Indicator --%>
              <div class="flex items-center justify-center mb-6">
                <div class={[
                  "flex items-center gap-2 px-4 py-2 rounded-full text-sm font-medium",
                  if(@conversation_status in [:connected, :speaking, :listening],
                    do: "bg-indigo-100 text-indigo-700 dark:bg-indigo-900/40 dark:text-indigo-300",
                    else: "bg-gray-100 text-gray-600 dark:bg-gray-700 dark:text-gray-300"
                  )
                ]}>
                  <div class={[
                    "w-2.5 h-2.5 rounded-full",
                    if(@conversation_status in [:connected, :speaking, :listening],
                      do: "bg-indigo-500 animate-pulse",
                      else: "bg-gray-400"
                    )
                  ]} />
                  {status_text(@conversation_status)}
                </div>
              </div>

              <%!-- ElevenLabs Hook (hidden, separate from buttons so LiveView can re-render them) --%>
              <div id="elevenlabs-hook" phx-hook=".ElevenLabsConversation" phx-update="ignore" class="hidden" />

              <%!-- Mic Button --%>
              <div class="flex justify-center mb-6">
                <%= if @conversation_status == :idle do %>
                  <button
                    phx-click="start_conversation"
                    class={[
                      "w-24 h-24 rounded-full flex items-center justify-center",
                      "bg-gradient-to-br from-indigo-500 to-purple-600 text-white",
                      "hover:from-indigo-600 hover:to-purple-700 hover:scale-105",
                      "transition-all duration-200 shadow-lg shadow-indigo-200 dark:shadow-indigo-900/30",
                      "focus:outline-none focus:ring-4 focus:ring-indigo-200"
                    ]}
                    id="start-conversation-btn"
                  >
                    <.icon name="hero-microphone" class="w-10 h-10" />
                  </button>
                <% else %>
                  <button
                    phx-click="end_conversation"
                    class={[
                      "w-24 h-24 rounded-full flex items-center justify-center",
                      "bg-gradient-to-br from-red-500 to-rose-600 text-white",
                      "hover:from-red-600 hover:to-rose-700 hover:scale-105",
                      "transition-all duration-200 shadow-lg shadow-red-200 dark:shadow-red-900/30",
                      "focus:outline-none focus:ring-4 focus:ring-red-200"
                    ]}
                    id="end-conversation-btn"
                  >
                    <.icon name="hero-stop" class="w-10 h-10" />
                  </button>
                <% end %>
              </div>

              <p class="text-center text-sm text-gray-500 dark:text-gray-400">
                <%= if @conversation_status == :idle do %>
                  Click the microphone to start a conversation
                <% else %>
                  Click stop when you're done setting up
                <% end %>
              </p>
            </div>

            <%!-- Transcript --%>
            <div
              class="rounded-2xl border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-800 p-6 max-h-72 overflow-y-auto"
              id="transcript-container"
            >
              <h3 class="text-sm font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wide mb-4">
                Conversation
              </h3>
              <%= if @transcript == [] do %>
                <p class="text-gray-400 dark:text-gray-500 text-sm italic">
                  Transcript will appear here once you start talking...
                </p>
              <% else %>
                <div class="space-y-3">
                  <%= for entry <- @transcript do %>
                    <div class={[
                      "text-sm rounded-lg px-3 py-2",
                      if(entry.source == "agent",
                        do: "bg-indigo-50 text-indigo-800 dark:bg-indigo-950/30 dark:text-indigo-300",
                        else: "bg-gray-50 text-gray-800 dark:bg-gray-700/50 dark:text-gray-200"
                      )
                    ]}>
                      <span class="font-medium">
                        {if entry.source == "agent", do: "Agent", else: "You"}:
                      </span>
                      {entry.message}
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>

          <%!-- Right: Profile Card with Digest Blocks --%>
          <div class="space-y-6">
            <div class="rounded-2xl border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-800 p-6" id="profile-card">
              <h3 class="text-sm font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wide mb-4">
                Your Daily Digest
              </h3>

              <%!-- Digest Time Picker --%>
              <div
                class="flex items-center gap-2 mb-4 p-3 rounded-xl bg-indigo-50/50 border border-indigo-100 dark:bg-indigo-950/30 dark:border-indigo-800"
                id="onboarding-time-picker"
              >
                <.icon name="hero-clock" class="w-4 h-4 text-indigo-500 dark:text-indigo-400" />
                <span class="text-sm text-gray-600 dark:text-gray-400">Daily at</span>
                <input
                  type="time"
                  value={first_digest_time(@digest_times)}
                  phx-change="update_digest_time"
                  phx-debounce="500"
                  name="time"
                  id="onboarding-time-input"
                  class="text-sm font-semibold text-indigo-700 dark:text-indigo-400 bg-transparent border-none p-0 cursor-pointer focus:ring-0 w-[70px]"
                />
              </div>

              <div id="digest-blocks" phx-update="stream">
                <div
                  id="empty-blocks"
                  class="hidden only:flex flex-col items-center justify-center py-12 text-gray-400 dark:text-gray-500"
                >
                  <.icon name="hero-inbox" class="w-12 h-12 mb-3 opacity-50" />
                  <p class="text-sm">No blocks yet — start a conversation to add some!</p>
                </div>

                <div
                  :for={{id, block} <- @streams.digest_blocks}
                  id={id}
                  class={[
                    "flex items-center gap-3 p-4 rounded-xl border border-gray-100 dark:border-gray-700",
                    "hover:border-gray-200 hover:shadow-sm dark:hover:border-gray-600",
                    "transition-all duration-200 mb-3",
                    "animate-[slideIn_0.3s_ease-out]"
                  ]}
                >
                  <div class={[
                    "w-10 h-10 rounded-lg flex items-center justify-center",
                    type_color(block.type)
                  ]}>
                    <.icon name={type_icon(block.type)} class="w-5 h-5" />
                  </div>
                  <div class="flex-1 min-w-0">
                    <p class="font-medium text-gray-900 dark:text-gray-100 truncate">{block.label}</p>
                    <p class="text-xs text-gray-500 dark:text-gray-400 capitalize">{block.type}</p>
                  </div>
                  <div class={["px-2 py-0.5 rounded-full text-xs font-medium", type_color(block.type)]}>
                    {block.type}
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>

      <%!-- Colocated ElevenLabs JS Hook --%>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".ElevenLabsConversation">
        import { Conversation } from "@elevenlabs/client";

        export default {
          mounted() {
            this.conversation = null;

            this.handleEvent("start_conversation", async ({ signed_url, user_id, existing_blocks, first_name, digest_time }) => {
              try {
                // Request microphone permission before starting the session
                await navigator.mediaDevices.getUserMedia({ audio: true });

                console.log("Starting ElevenLabs session with signed URL:", signed_url);

                this.conversation = await Conversation.startSession({
                  signedUrl: signed_url,
                  dynamicVariables: {
                    user_id: user_id,
                    existing_blocks: existing_blocks,
                    first_name: first_name,
                    digest_time: digest_time
                  },
                  onMessage: (props) => {
                    console.log("ElevenLabs message:", props);
                    if (this.el.isConnected) {
                      this.pushEvent("transcript_update", {
                        message: props.message,
                        source: props.source
                      });
                    }
                  },
                  onStatusChange: ({ status }) => {
                    console.log("ElevenLabs status:", status);
                    if (this.el.isConnected) {
                      this.pushEvent("status_change", { status });
                    }
                  },
                  onDisconnect: (details) => {
                    console.log("ElevenLabs disconnected:", details);
                    if (this.el.isConnected) {
                      this.pushEvent("conversation_ended", {});
                    }
                  },
                  onError: (message, context) => {
                    console.error("ElevenLabs error:", message, context);
                  }
                });

                console.log("ElevenLabs session started successfully");
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
    </Layouts.app>
    """
  end
end
