defmodule CheckDayWeb.PageController do
  use CheckDayWeb, :controller

  def home(conn, _params) do
    render(conn, :home, current_user: conn.assigns[:current_user])
  end

  def register_redirect(conn, _params) do
    redirect(conn, to: ~p"/sign-in")
  end
end
