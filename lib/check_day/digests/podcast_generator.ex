defmodule CheckDay.Digests.PodcastGenerator do
  @moduledoc "Generates an audio podcast from digest sections using LLM and ElevenLabs."

  require Logger

  @doc """
  Generates a short podcast script and then fetches the TTS audio binary from ElevenLabs.
  """
  def generate_audio(sections, voice_id \\ "21m00Tcm4TlvDq8ikWAM") do
    text_content =
      sections
      |> Enum.map(fn {block, results} ->
        results_text =
          Enum.map(results, fn r -> "- #{r[:headline]}: #{r[:digest_summary]}" end)
          |> Enum.join("\n")

        "Topic: #{block.label}\n#{results_text}"
      end)
      |> Enum.join("\n\n")

    script = generate_script(text_content)

    Logger.info("Generated Podcast Script (length: #{String.length(script)}):\n\n#{script}")

    fetch_elevenlabs_audio(script, voice_id)
  end

  defp generate_script(text_content) do
    prompt = """
    You are a professional, engaging podcast host for a daily digest called 'Check Day'.
    I will provide you with today's news and updates.
    Your job is to read them and write a conversational, extremely engaging 1-minute podcast script that flows naturally.
    Do NOT include speaker labels, sound effects, or stage directions. Just return the exact spoken text.
    Start with an enthusiastic welcome, summarize the key points interactively, and end with a quick sign-off.

    TODAY'S UPDATES:
    #{text_content}
    """

    schema =
      Zoi.map(%{
        transcript:
          Zoi.string(
            description:
              "The raw spoken podcast transcript. Do NOT include Markdown, asterisks, brackets, or stage directions."
          )
      })

    try do
      llm_model = ReqLLM.model!(%{provider: :openrouter, id: "google/gemini-3-flash-preview"})
      result = ReqLLM.generate_object!(llm_model, prompt, schema)

      result[:transcript] || result["transcript"] ||
        "Welcome to Check Day! It looks like there are no updates for today. Have a great day!"
    rescue
      e ->
        Logger.error("Failed to generate podcast script: #{inspect(e)}")

        "Welcome to Check Day! We are experiencing technical difficulties generating today's script."
    end
  end

  defp fetch_elevenlabs_audio(script, voice_id) do
    api_key = Application.fetch_env!(:eleven_labs, :api_key)

    url = "https://api.elevenlabs.io/v1/text-to-speech/#{voice_id}"

    body = %{
      text: script,
      model_id: "eleven_turbo_v2_5",
      voice_settings: %{
        stability: 0.5,
        similarity_boost: 0.75
      }
    }

    Logger.info("Requesting ElevenLabs TTS for voice_id: #{voice_id}...")

    case Req.post(url,
           json: body,
           headers: [
             {"xi-api-key", api_key},
             {"content-type", "application/json"}
           ],
           receive_timeout: 45_000
         ) do
      {:ok, %Req.Response{status: 200, body: audio_bytes}} ->
        Logger.info("Successfully received ElevenLabs audio payload.")
        {:ok, audio_bytes}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("ElevenLabs API failed with status #{status}: #{inspect(body)}")
        {:error, "API Error: #{status}"}

      {:error, reason} ->
        Logger.error("ElevenLabs Request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
