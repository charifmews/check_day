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
    </head>
    <body style="margin: 0; padding: 0; background-color: #f4f4f7; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif;">
      <table width="100%" cellpadding="0" cellspacing="0" style="background-color: #f4f4f7; padding: 32px 16px;">
        <tr>
          <td align="center">
            <table width="600" cellpadding="0" cellspacing="0" style="background-color: #ffffff; border-radius: 12px; overflow: hidden; box-shadow: 0 2px 8px rgba(0,0,0,0.08);">
              <!-- Header -->
              <tr>
                <td style="background: linear-gradient(135deg, #e97a1f 0%, #f5a623 100%); padding: 32px 40px; text-align: center;">
                  <h1 style="margin: 0; color: #ffffff; font-size: 24px; font-weight: 700;">✓ Check.Day</h1>
                </td>
              </tr>

              <!-- Body -->
              <tr>
                <td style="padding: 40px;">
                  <h2 style="margin: 0 0 8px; color: #1f2937; font-size: 20px; font-weight: 600; text-align: center;">Sign in to your account</h2>
                  <p style="margin: 0 0 32px; color: #6b7280; font-size: 15px; text-align: center; line-height: 1.5;">
                    Click the button below to securely sign in. This link expires in 10 minutes.
                  </p>

                  <!-- CTA Button -->
                  <table width="100%" cellpadding="0" cellspacing="0">
                    <tr>
                      <td align="center">
                        <a href="#{url}" style="display: inline-block; padding: 14px 40px; background: linear-gradient(135deg, #e97a1f 0%, #f5a623 100%); color: #ffffff; font-size: 16px; font-weight: 600; text-decoration: none; border-radius: 8px; box-shadow: 0 4px 12px rgba(233, 122, 31, 0.3);">
                          Sign in to Check.Day →
                        </a>
                      </td>
                    </tr>
                  </table>

                  <p style="margin: 32px 0 0; color: #9ca3af; font-size: 13px; text-align: center; line-height: 1.5;">
                    If the button doesn't work, copy and paste this link into your browser:
                  </p>
                  <p style="margin: 8px 0 0; color: #6366f1; font-size: 13px; text-align: center; word-break: break-all;">
                    <a href="#{url}" style="color: #e97a1f; text-decoration: none;">#{url}</a>
                  </p>
                </td>
              </tr>

              <!-- Footer -->
              <tr>
                <td style="padding: 24px 40px 32px; border-top: 1px solid #e5e7eb;">
                  <p style="margin: 0; color: #9ca3af; font-size: 12px; text-align: center;">
                    If you didn't request this email, you can safely ignore it.
                  </p>
                  <p style="margin: 8px 0 0; color: #9ca3af; font-size: 12px; text-align: center;">
                    Sent by Check.Day · Wake up to what matters
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
