defmodule CheckDay.Accounts.User.Senders.SendMagicLinkEmail do
  @moduledoc """
  Sends a magic link email
  """

  use AshAuthentication.Sender
  use CheckDayWeb, :verified_routes

  import Swoosh.Email
  alias CheckDay.Mailer

  @impl true
  def send(user_or_email, token, _) do
    # if you get a user, its for a user that already exists.
    # if you get an email, then the user does not yet exist.

    email =
      case user_or_email do
        %{email: email} -> email
        email -> email
      end

    new()
    # TODO: Replace with your email
    |> from({"Check.Day", "noreply@check.day"})
    |> to(to_string(email))
    |> subject("Your login link")
    |> html_body(body(token: token, email: email))
    |> Mailer.deliver!()
  end

  defp body(params) do
    url = url(~p"/magic_link/#{params[:token]}")

    """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>Sign in to Check.Day</title>
      <style>
        @media (prefers-color-scheme: dark) {
          .email-bg { background-color: #0a0f18 !important; }
          .email-card { background-color: #111827 !important; border: 1px solid #374151 !important; box-shadow: none !important; }
          .text-main { color: #f9fafb !important; }
          .text-muted { color: #9ca3af !important; }
          .footer-border { border-top: 1px solid #374151 !important; }
        }
      </style>
    </head>
    <body class="email-bg" style="margin: 0; padding: 0; background-color: #f9fafb; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif;">
      <table width="100%" cellpadding="0" cellspacing="0" class="email-bg" style="background-color: #f9fafb; padding: 40px 16px;">
        <tr>
          <td align="center">
            <table width="600" cellpadding="0" cellspacing="0" class="email-card" style="background-color: #ffffff; border-radius: 16px; overflow: hidden; box-shadow: 0 4px 20px rgba(0,0,0,0.05); border: 1px solid #f3f4f6;">
              <!-- Header -->
              <tr>
                <td style="background: linear-gradient(135deg, #fd7831 0%, #ff9500 100%); padding: 40px 40px; text-align: center;">
                  <h1 style="margin: 0; color: #ffffff; font-size: 28px; font-weight: 800; letter-spacing: -0.5px;">Check.Day</h1>
                </td>
              </tr>

              <!-- Body -->
              <tr>
                <td style="padding: 48px 40px;">
                  <h2 class="text-main" style="margin: 0 0 12px; color: #111827; font-size: 22px; font-weight: 700; text-align: center;">Secure Sign In</h2>
                  <p class="text-muted" style="margin: 0 0 36px; color: #4b5563; font-size: 16px; text-align: center; line-height: 1.6;">
                    Click the button below to instantly access your dashboard. This link expires in 10 minutes.
                  </p>

                  <!-- CTA Button -->
                  <table width="100%" cellpadding="0" cellspacing="0">
                    <tr>
                      <td align="center">
                        <a href="#{url}" style="display: inline-block; padding: 16px 40px; background: linear-gradient(135deg, #fd7831 0%, #ff9500 100%); color: #ffffff; font-size: 16px; font-weight: 700; text-decoration: none; border-radius: 12px; box-shadow: 0 4px 15px rgba(253, 120, 49, 0.3);">
                          Sign in to Check.Day →
                        </a>
                      </td>
                    </tr>
                  </table>

                  <p class="text-muted" style="margin: 36px 0 0; color: #9ca3af; font-size: 13px; text-align: center; line-height: 1.5;">
                    If the button doesn't work, copy and paste this link:
                  </p>
                  <p style="margin: 8px 0 0; font-size: 13px; text-align: center; word-break: break-all;">
                    <a href="#{url}" style="color: #fd7831; text-decoration: none;">#{url}</a>
                  </p>
                </td>
              </tr>

              <!-- Footer -->
              <tr>
                <td class="footer-border" style="padding: 32px 40px; border-top: 1px solid #f3f4f6; background-color: rgba(0,0,0,0.01);">
                  <p class="text-muted" style="margin: 0; color: #9ca3af; font-size: 13px; text-align: center;">
                    If you didn't request this email, you can safely ignore it.
                  </p>
                  <p class="text-muted" style="margin: 8px 0 0; color: #9ca3af; font-size: 13px; text-align: center;">
                    Check.Day · Wake up to what matters
                  </p>
                </td>
              </tr>
            </table>
          </td>
        </tr>
      </table>
    </body>
    </html>
    """
  end
end
