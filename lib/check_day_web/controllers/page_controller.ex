defmodule CheckDayWeb.PageController do
  use CheckDayWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
