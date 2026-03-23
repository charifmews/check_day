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
    </head>
    <body style="margin: 0; padding: 0; background-color: #f4f4f7; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif;">
      <table width="100%" cellpadding="0" cellspacing="0" style="background-color: #f4f4f7; padding: 32px 16px;">
        <tr>
          <td align="center">
            <table width="600" cellpadding="0" cellspacing="0" style="background-color: #ffffff; border-radius: 12px; overflow: hidden; box-shadow: 0 2px 8px rgba(0,0,0,0.08);">
              <!-- Header -->
              <tr>
                <td style="background: linear-gradient(135deg, #6366f1 0%, #8b5cf6 100%); padding: 32px 40px;">
                  <h1 style="margin: 0; color: #ffffff; font-size: 24px; font-weight: 700;">☀️ Your Daily Digest</h1>
                  <p style="margin: 8px 0 0; color: rgba(255,255,255,0.85); font-size: 14px;">#{formatted_date}</p>
                </td>
              </tr>

              <!-- Greeting -->
              <tr>
                <td style="padding: 32px 40px 16px;">
                  <p style="margin: 0; color: #374151; font-size: 16px;">#{greeting}, here's what's happening today:</p>
                </td>
              </tr>

              <!-- Sections -->
              #{sections_html}

              <!-- Footer -->
              <tr>
                <td style="padding: 24px 40px 32px; border-top: 1px solid #e5e7eb;">
                  <p style="margin: 0; color: #9ca3af; font-size: 12px; text-align: center;">
                    Sent by CheckDay · Manage your digest at check.day
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
        <div style="border: 1px solid #e5e7eb; border-radius: 8px; padding: 20px; margin-bottom: 8px;">
          <h2 style="margin: 0 0 8px; color: #1f2937; font-size: 16px; font-weight: 600;">
            #{type_emoji(block.type)} #{escape(block.label)}
          </h2>
          <p style="margin: 0; color: #9ca3af; font-size: 14px; font-style: italic;">No results found for today.</p>
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
        <div style="border: 1px solid #e5e7eb; border-radius: 8px; padding: 20px; margin-bottom: 8px;">
          <h2 style="margin: 0 0 16px; color: #1f2937; font-size: 16px; font-weight: 600;">
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
    summary = result[:digest_summary] || ""
    sources = result[:sources] || []

    sources_html =
      case Enum.reject(sources, fn {url, _} -> is_nil(url) end) do
        [] ->
          ""

        valid_sources ->
          links =
            valid_sources
            |> Enum.map(fn {url, domain} ->
              """
              <a href="#{url}" style="color: #6366f1; font-size: 12px; text-decoration: none;">#{escape(domain)}</a>
              """
            end)
            |> Enum.join(" · ")

          """
          <p style="margin: 8px 0 0; color: #9ca3af; font-size: 12px;">
            Sources: #{links}
          </p>
          """
      end

    """
    <div style="margin-bottom: 16px; padding-bottom: 16px; border-bottom: 1px solid #f3f4f6;">
      <h3 style="margin: 0 0 4px; color: #1f2937; font-size: 14px; font-weight: 600;">#{escape(headline)}</h3>
      <p style="margin: 0; color: #4b5563; font-size: 14px; line-height: 1.5;">#{escape(summary)}</p>
      #{sources_html}
    </div>
    """
  end

  defp type_emoji(:weather), do: "🌤"
  defp type_emoji(:news), do: "📰"
  defp type_emoji(:interest), do: "✨"
  defp type_emoji(:competitor), do: "🏢"
  defp type_emoji(:stock), do: "📈"
  defp type_emoji(:agenda), do: "📅"
  defp type_emoji(:habit), do: "✅"
  defp type_emoji(:custom), do: "🧩"
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
