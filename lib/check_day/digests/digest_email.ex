defmodule CheckDay.Digests.DigestEmail do
  @moduledoc """
  Builds and sends the daily digest HTML email.
  """

  import Swoosh.Email
  alias CheckDay.Mailer

  @from {"CheckDay", "noreply@check.day"}

  @doc """
  Builds and sends a digest email to the user.

  `sections` is a list of `{block, results}` tuples where each result has
  `:headline`, `:digest_summary`, `:verbatim_quote`, and `:source_url` keys.
  """
  def build_and_send(user, date, sections) do
    subject = "Your Daily Digest — #{Calendar.strftime(date, "%A, %B %d")}"

    new()
    |> from(@from)
    |> to(to_string(user.email))
    |> subject(subject)
    |> html_body(render_html(user, date, sections))
    |> Mailer.deliver!()
  end

  defp render_html(user, date, sections) do
    greeting = if user.first_name, do: "Hi #{user.first_name}", else: "Hi"
    formatted_date = Calendar.strftime(date, "%A, %B %d, %Y")

    sections_html =
      sections
      |> Enum.map(fn {block, results} -> render_section(block, results) end)
      |> Enum.join("\n")

    """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>Your Daily Digest</title>
      <style>
        @media (prefers-color-scheme: dark) {
          .email-bg { background-color: #0a0f18 !important; }
          .email-card { background-color: #111827 !important; border: 1px solid #374151 !important; box-shadow: none !important; }
          .text-main { color: #f9fafb !important; }
          .text-sub { color: #d1d5db !important; }
          .text-muted { color: #9ca3af !important; }
          .divider { border-color: #374151 !important; }
          .block-container { border-color: #374151 !important; background-color: #1f2937 !important; }
        }
        .markdown-body a { color: #fd7831; text-decoration: none; font-weight: 500; }
        .markdown-body p { margin-top: 0; margin-bottom: 12px; }
        .markdown-body ul { margin-top: 0; margin-bottom: 12px; padding-left: 20px; }
        .markdown-body li { margin-bottom: 6px; }
      </style>
    </head>
    <body class="email-bg" style="margin: 0; padding: 0; background-color: #f9fafb; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif;">
      <table width="100%" cellpadding="0" cellspacing="0" class="email-bg" style="background-color: #f9fafb; padding: 32px 16px;">
        <tr>
          <td align="center">
            <table width="600" cellpadding="0" cellspacing="0" class="email-card" style="background-color: #ffffff; border-radius: 16px; overflow: hidden; box-shadow: 0 4px 20px rgba(0,0,0,0.05); border: 1px solid #f3f4f6;">
              <!-- Header -->
              <tr>
                <td style="background: linear-gradient(135deg, #fd7831 0%, #ff9500 100%); padding: 32px 40px;">
                  <h1 style="margin: 0; color: #ffffff; font-size: 24px; font-weight: 800; letter-spacing: -0.5px;">☀️ Your Daily Digest</h1>
                  <p style="margin: 8px 0 0; color: rgba(255,255,255,0.9); font-size: 15px; font-weight: 500;">#{formatted_date}</p>
                </td>
              </tr>

              <!-- Greeting -->
              <tr>
                <td style="padding: 32px 40px 16px;">
                  <p class="text-main" style="margin: 0; color: #111827; font-size: 18px; font-weight: 600;">#{greeting}, here's what's happening today:</p>
                </td>
              </tr>

              <!-- Sections -->
              #{sections_html}

              <!-- Footer -->
              <tr>
                <td class="divider" style="padding: 24px 40px 32px; border-top: 1px solid #f3f4f6; background-color: rgba(0,0,0,0.01);">
                  <p class="text-muted" style="margin: 0; color: #9ca3af; font-size: 13px; text-align: center;">
                    Sent by Check.Day · Manage your digest at <a href="https://check.day" style="color: #fd7831; text-decoration: none;">check.day</a>
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

  defp render_section(block, []) do
    """
    <tr>
      <td style="padding: 8px 40px;">
        <div class="block-container" style="border: 1px solid #f3f4f6; border-radius: 12px; padding: 24px; margin-bottom: 12px; background-color: #ffffff; box-shadow: 0 2px 8px rgba(0,0,0,0.02);">
          <h2 class="text-main" style="margin: 0 0 8px; color: #111827; font-size: 16px; font-weight: 700; letter-spacing: -0.2px;">
            #{type_emoji(block.type)} #{escape(block.label)}
          </h2>
          <p class="text-muted" style="margin: 0; color: #9ca3af; font-size: 14px; font-style: italic;">No results found for today.</p>
        </div>
      </td>
    </tr>
    """
  end

  defp render_section(block, results) do
    results_html =
      results
      |> Enum.map(&render_result/1)
      |> Enum.join("\n")

    """
    <tr>
      <td style="padding: 8px 40px;">
        <div class="block-container" style="border: 1px solid #f3f4f6; border-radius: 12px; padding: 24px; margin-bottom: 12px; background-color: #ffffff; box-shadow: 0 2px 8px rgba(0,0,0,0.02);">
          <h2 class="text-main" style="margin: 0 0 20px; color: #111827; font-size: 16px; font-weight: 700; letter-spacing: -0.2px; border-bottom: 1px solid #f3f4f6; padding-bottom: 12px;" class="divider">
            #{type_emoji(block.type)} #{escape(block.label)}
          </h2>
          #{results_html}
        </div>
      </td>
    </tr>
    """
  end

  defp render_result(result) do
    headline = result[:headline] || "Untitled"
    sources = result[:sources] || []

    summary_html =
      case result[:digest_summary] do
        nil -> ""
        "" -> ""
        text ->
          case Earmark.as_html(text) do
            {:ok, html, _} -> html
            _ -> escape(text)
          end
      end

    sources_html =
      case Enum.reject(sources, fn {url, _} -> is_nil(url) end) do
        [] ->
          ""

        valid_sources ->
          links =
            valid_sources
            |> Enum.map(fn {url, domain} ->
              """
              <a href="#{url}" style="color: #fd7831; font-size: 12px; font-weight: 600; text-decoration: none;">#{escape(domain)}</a>
              """
            end)
            |> Enum.join(" <span style='color: #d1d5db;'>·</span> ")

          """
          <p class="text-muted" style="margin: 12px 0 0; color: #9ca3af; font-size: 12px;">
            Sources: #{links}
          </p>
          """
      end

    """
    <div class="divider" style="margin-bottom: 20px; padding-bottom: 20px; border-bottom: 1px solid #f3f4f6;">
      <h3 class="text-main" style="margin: 0 0 10px; color: #111827; font-size: 15px; font-weight: 700;">#{escape(headline)}</h3>
      <div class="text-sub markdown-body" style="margin: 0; color: #4b5563; font-size: 15px; line-height: 1.6;">
        #{summary_html}
      </div>
      #{sources_html}
    </div>
    """
  end

  defp type_emoji(:weather), do: "🌤"
  defp type_emoji(:news), do: "📰"
  defp type_emoji(:interest), do: "✨"
  defp type_emoji(:competitor), do: "🏢"
  defp type_emoji(:stock), do: "📈"
  defp type_emoji(_), do: "📋"

  defp escape(nil), do: ""

  defp escape(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp escape(text), do: escape(to_string(text))
end
