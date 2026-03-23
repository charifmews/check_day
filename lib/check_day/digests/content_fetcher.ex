defmodule CheckDay.Digests.ContentFetcher do
  @moduledoc """
  Fetches content for a digest block using Firecrawl search,
  then extracts structured data and validates via LLM to prevent hallucinations.
  """

  require Logger

  @doc """
  Fetches content for a digest block.

  Returns `{:ok, results}` where results is a list of maps with
  `:headline`, `:digest_summary`, `:verbatim_quote`, and `:source_url`.

  For blocks that don't need Firecrawl (agenda, habit), returns static content.
  """
  def fetch(block) do
    case block.type do
      :agenda ->
        {:ok,
         [
           %{
             headline: "Agenda",
             digest_summary: "Calendar integration coming soon.",
             source_url: nil
           }
         ]}

      :habit ->
        reminder = get_in(block.config, ["reminder"]) || block.label
        {:ok, [%{headline: block.label, digest_summary: reminder, source_url: nil}]}

      _ ->
        fetch_from_firecrawl(block)
    end
  end

  defp fetch_from_firecrawl(block) do
    query = build_query(block)

    case Firecrawl.search_and_scrape(
           query: query,
           limit: 5,
           tbs: "qdr:d",
           scrape_options: [
             formats: ["markdown"],
             only_main_content: true
           ]
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        results = parse_and_extract(body, block)
        {:ok, results}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("Firecrawl search failed with status #{status}: #{inspect(body)}")
        {:error, "Firecrawl returned status #{status}"}

      {:error, reason} ->
        Logger.error("Firecrawl search error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp build_query(block) do
    config = block.config || %{}

    case block.type do
      :weather ->
        location = config["location"] || block.label
        "#{location} weather forecast today current conditions"

      :news ->
        topic = config["topic"] || block.label
        "#{topic} news today #{Date.to_iso8601(Date.utc_today())}"

      :interest ->
        topic = config["topic"] || block.label
        "#{topic} news latest #{Date.to_iso8601(Date.utc_today())}"

      :competitor ->
        company = config["company_name"] || block.label
        "\"#{company}\" news announcements today"

      :stock ->
        symbol = config["symbol"] || block.label
        "#{symbol} stock price market news today"

      :custom ->
        config["query"] || block.label

      _ ->
        block.label
    end
  end

  # -- Parsing & deduplication -----------------------------------------------

  defp parse_and_extract(%{"data" => %{"web" => results}}, block) when is_list(results) do
    do_parse_and_extract(results, block)
  end

  defp parse_and_extract(%{"data" => results}, block) when is_list(results) do
    do_parse_and_extract(results, block)
  end

  defp parse_and_extract(_, _block), do: []

  defp do_parse_and_extract(results, block) do
    topic = block_topic(block)

    results
    |> Enum.reject(fn r -> is_nil(r["markdown"]) or r["markdown"] == "" end)
    |> dedup_by_domain()
    |> Enum.map(fn result ->
      case extract_and_validate(result["markdown"], result["url"], topic) do
        {:ok, extracted} -> extracted
        {:error, _} -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp dedup_by_domain(results) do
    results
    |> Enum.uniq_by(fn result ->
      case URI.parse(result["url"] || "") do
        %URI{host: host} when is_binary(host) -> host
        _ -> result["url"]
      end
    end)
  end

  defp block_topic(block) do
    config = block.config || %{}

    case block.type do
      :weather -> "weather in #{config["location"] || block.label}"
      :news -> config["topic"] || block.label
      :interest -> config["topic"] || block.label
      :competitor -> config["company_name"] || block.label
      :stock -> "#{config["symbol"] || block.label} stock"
      :custom -> config["query"] || block.label
      _ -> block.label
    end
  end

  # -- LLM extraction with relevance check -----------------------------------

  @extraction_schema [
    relevant: [type: :boolean, required: true, doc: "Is this content actually about the TOPIC? true if relevant, false if off-topic."],
    headline: [type: :string, required: true, doc: "The main headline of the article. Return null if not found."],
    digest_summary: [type: :string, required: true, doc: "A concise summary of the key facts. Return null if not found."],
    verbatim_quote: [type: :string, required: true, doc: "An exact quote from the source material. Return null if not found."]
  ]

  defp extract_and_validate(markdown, source_url, topic) do
    source_snippet = String.slice(markdown, 0, 4000)

    prompt = """
    TOPIC: #{topic}

    Extract the core facts from this article. Do NOT infer or add information not present.

    First, determine if this content is actually about the TOPIC above.
    Set "relevant" to false if the content is off-topic, a generic homepage,
    a forum index page, or not specifically about the TOPIC.

    SOURCE MATERIAL:
    #{source_snippet}

    CRITICAL: Every value MUST come directly from the source material above.
    If a field cannot be determined from the source, set it to null.
    """

    model =
      ReqLLM.model!(%{
        provider: :openrouter,
        id: "google/gemini-3-flash-preview"
      })

    try do
      extracted = ReqLLM.generate_object!(model, prompt, @extraction_schema)

      relevant = extracted[:relevant] || extracted["relevant"]

      if relevant do
        {:ok,
         %{
           headline: extracted[:headline] || extracted["headline"],
           digest_summary: extracted[:digest_summary] || extracted["digest_summary"],
           verbatim_quote: extracted[:verbatim_quote] || extracted["verbatim_quote"],
           source_url: source_url
         }}
      else
        Logger.info("Skipping irrelevant result for '#{topic}': #{source_url}")
        {:error, :irrelevant}
      end
    rescue
      e ->
        Logger.warning("LLM extraction failed: #{inspect(e)}")
        {:error, :llm_failed}
    end
  end
end
