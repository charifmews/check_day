defmodule CheckDay.Repo do
  use Ecto.Repo,
    otp_app: :check_day,
    adapter: Ecto.Adapters.Postgres
end
