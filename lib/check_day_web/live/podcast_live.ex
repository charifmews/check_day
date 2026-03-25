defmodule CheckDayWeb.PodcastLive do
  use CheckDayWeb, :live_view

  on_mount {CheckDayWeb.LiveUserAuth, :live_user_required}

  def mount(%{"id" => id}, _session, socket) do
    current_user = socket.assigns.current_user

    case Ash.get(CheckDay.Digests.DigestRun, id, authorize?: false) do
      {:ok, run} ->
        if run.user_id == current_user.id do
          socket =
            socket
            |> assign(:run, run)
            |> assign(:page_title, "Daily Digest Podcast")

          {:ok, socket}
        else
          {:ok, push_navigate(socket, to: "/dashboard")}
        end

      {:error, _} ->
        {:ok, push_navigate(socket, to: "/dashboard")}
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <main class="w-full max-w-5xl mx-auto px-4 sm:px-6 py-12 relative">
        <div class="mb-8 flex justify-start">
          <.link
            navigate="/dashboard"
            class="inline-flex items-center gap-2 px-4 py-2 rounded-full border border-white/10 bg-zinc-800/40 backdrop-blur-md shadow-sm hover:shadow-lg hover:border-[oklch(70%_0.213_47.604)]/80 hover:bg-[oklch(70%_0.213_47.604)]/20 transition-all duration-300 text-zinc-300 hover:text-white font-medium text-sm hover:-translate-y-0.5"
          >
            <.icon name="hero-arrow-left" class="w-4 h-4" />
            <span>Back to Dashboard</span>
          </.link>
        </div>

        <div class="mb-12 text-center">
          <div class="inline-flex items-center justify-center p-3 mb-6 rounded-full bg-gradient-to-tr from-orange-500/20 to-amber-500/20 shadow-inner">
            <.icon name="hero-play" class="w-8 h-8 text-orange-500" />
          </div>
          <h1 class="text-4xl font-extrabold tracking-tight bg-clip-text text-transparent bg-gradient-to-r from-orange-400 to-amber-500 mb-4">
            Check Day Podcast
          </h1>
          <p class="text-zinc-400 text-lg font-medium">
            {Calendar.strftime(@run.inserted_at, "%A, %B %d, %Y")}
          </p>
        </div>

        <%= if @run.podcast_audio do %>
          <div class="sticky top-6 z-10 p-6 sm:p-8 mb-12 bg-zinc-900/80 backdrop-blur-xl border border-white/10 rounded-3xl shadow-2xl flex flex-col items-center max-w-2xl mx-auto">
            <p class="text-sm text-zinc-400 font-semibold uppercase tracking-wider mb-4">
              Daily Briefing
            </p>

            <audio controls autoplay class="w-full mb-2">
              <source src={"/digests/#{@run.id}/podcast.mp3"} type="audio/mpeg" />
              Your browser does not support the audio element.
            </audio>
          </div>
        <% else %>
          <div class="max-w-2xl mx-auto p-6 mb-12 bg-red-950/20 border border-red-500/20 rounded-3xl text-center text-red-400">
            No podcast audio available for this digest.
          </div>
        <% end %>

        <% # Intercept the strict 600px email constraints (for both old and new legacy runs)
        # and dynamically scale it up for the rich web view so it fills the podcast screen natively!
        expanded_html =
          @run.html_body
          |> String.replace("width=\"600\"", "width=\"100%\" style=\"max-width: 896px;\"")
          |> String.replace("max-width: 600px;", "max-width: 896px;") %>

        <div class="w-full max-w-4xl mx-auto rounded-3xl overflow-hidden shadow-2xl border border-white/5 ring-1 ring-white/10 bg-zinc-950">
          <iframe
            id={"iframe-#{@run.id}"}
            phx-update="ignore"
            phx-hook=".IframeResizer"
            srcdoc={expanded_html}
            class="w-full border-0 bg-transparent"
            style="height: 100vh;"
            sandbox="allow-same-origin allow-popups allow-scripts"
          >
          </iframe>
        </div>

        <script :type={Phoenix.LiveView.ColocatedHook} name=".IframeResizer">
          export default {
            mounted() {
              this.resize();
              this.el.addEventListener('load', () => this.resize());
              // Fallback interval to ensure complete load adjustments
              this.interval = setInterval(() => this.resize(), 1000);
            },
            destroyed() {
              if (this.interval) clearInterval(this.interval);
            },
            resize() {
              try {
                const doc = this.el.contentWindow.document;
                if (doc && doc.documentElement) {
                  this.el.style.height = Math.max(doc.documentElement.scrollHeight, doc.body.scrollHeight) + 'px';
                }
              } catch (e) {}
            }
          }
        </script>
      </main>
    </Layouts.app>
    """
  end
end
