defmodule CheckDayWeb.DashboardLive do
  use CheckDayWeb, :live_view

  on_mount {CheckDayWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="max-w-4xl mx-auto">
        <h1 class="text-3xl font-bold text-gray-900 mb-4" id="dashboard-title">Dashboard</h1>
        <p class="text-gray-600" id="dashboard-welcome">
          Welcome back! Your morning podcast experience starts here.
        </p>
      </div>
    </Layouts.app>
    """
  end
end
