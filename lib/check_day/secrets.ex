defmodule CheckDay.Secrets do
  use AshAuthentication.Secret

  def secret_for(
        [:authentication, :tokens, :signing_secret],
        CheckDay.Accounts.User,
        _opts,
        _context
      ) do
    Application.fetch_env(:check_day, :token_signing_secret)
  end
end
