defmodule CheckDay.Accounts do
  use Ash.Domain,
    otp_app: :check_day

  resources do
    resource CheckDay.Accounts.Token
    resource CheckDay.Accounts.User
  end
end
