defmodule CheckDay.Digests.ContentFetcher do
  @moduledoc """
  Fetches content for a digest block using Firecrawl search,
  then extracts structured data, validates via LLM, and combines
  similar entries into a single merged result with multiple sources.
  """

  require Logger

  @doc """
  Fetches content for a digest block.

  Returns `{:ok, results}` where results is a list of maps with
  `:headline`, `:digest_summary`, and `:sources` (list of `{url, domain}` tuples).

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
             sources: []
           }
         ]}

      :habit ->
        reminder = get_in(block.config, ["reminder"]) || block.label
        {:ok, [%{headline: block.label, digest_summary: reminder, sources: []}]}

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
        individual_results = parse_and_extract(body, block)
        combined = combine_results(individual_results, block)
        {:ok, combined}

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

    try do
      extracted = ReqLLM.generate_object!(llm_model(), prompt, @extraction_schema)

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

  # -- Group & combine similar results ---------------------------------------

  @combine_schema [
    headline: [type: :string, required: true, doc: "A single headline that best represents all the sources combined."],
    digest_summary: [type: :string, required: true, doc: "A concise combined summary synthesizing all sources into one coherent paragraph. Include the most important facts from each source without repeating."]
  ]

  defp combine_results([], _block), do: []

  defp combine_results([single], _block) do
    [%{
      headline: single.headline,
      digest_summary: single.digest_summary,
      sources: [source_tuple(single.source_url)]
    }]
  end

  defp combine_results(results, block) do
    groups = group_similar(results, block)

    Enum.flat_map(groups, fn group ->
      case group do
        [single] ->
          [%{
            headline: single.headline,
            digest_summary: single.digest_summary,
            sources: [source_tuple(single.source_url)]
          }]

        multiple ->
          merge_group(multiple, block)
      end
    end)
  end

  defp group_similar(results, block) do
    topic = block_topic(block)

    indexed =
      results
      |> Enum.with_index(1)
      |> Enum.map(fn {r, i} ->
        "[#{i}] #{r.headline}: #{String.slice(r.digest_summary || "", 0, 100)}"
      end)
      |> Enum.join("\n")

    prompt = """
    TOPIC: #{topic}

    I have #{length(results)} search results. Group them by similarity — results
    covering the same story or topic should be in the same group. Results about
    different subjects should be in separate groups.

    RESULTS:
    #{indexed}

    Return the groups as a JSON object with a "groups" key containing an array of arrays of indices.
    Example: {"groups": [[1, 3], [2], [4, 5]]}

    Keep results about different subjects separate. Only group results that cover
    essentially the same story from different sources.
    """

    try do
      schema = [groups: [type: {:list, {:list, :pos_integer}}, required: true, doc: "Array of arrays of 1-based result indices. Each inner array is a group of similar results."]]
      extracted = ReqLLM.generate_object!(llm_model(), prompt, schema)
      raw_groups = extracted[:groups] || extracted["groups"] || []

      raw_groups
      |> Enum.map(fn indices ->
        indices
        |> Enum.map(fn i -> Enum.at(results, i - 1) end)
        |> Enum.reject(&is_nil/1)
      end)
      |> Enum.reject(fn g -> g == [] end)
    rescue
      e ->
        Logger.warning("Grouping failed: #{inspect(e)}, treating each result as its own group")
        Enum.map(results, fn r -> [r] end)
    end
  end

  defp merge_group(results, block) do
    topic = block_topic(block)
    sources = Enum.map(results, fn r -> source_tuple(r.source_url) end)

    summaries =
      results
      |> Enum.with_index(1)
      |> Enum.map(fn {r, i} ->
        domain = elem(source_tuple(r.source_url), 1)
        "[#{i}] #{r.headline} (#{domain}): #{r.digest_summary}"
      end)
      |> Enum.join("\n\n")

    prompt = """
    TOPIC: #{topic}

    Combine these #{length(results)} related results into ONE concise digest entry.
    Synthesize the key facts, avoid repetition, and produce a single coherent summary.

    RESULTS:
    #{summaries}

    Write a single combined headline and a 2-4 sentence summary.
    """

    try do
      combined = ReqLLM.generate_object!(llm_model(), prompt, @combine_schema)

      [%{
        headline: combined[:headline] || combined["headline"],
        digest_summary: combined[:digest_summary] || combined["digest_summary"],
        sources: sources
      }]
    rescue
      e ->
        Logger.warning("Merge failed: #{inspect(e)}, returning first result")
        [%{
          headline: hd(results).headline,
          digest_summary: hd(results).digest_summary,
          sources: sources
        }]
    end
  end

  defp source_tuple(nil), do: {nil, nil}

  defp source_tuple(url) when is_binary(url) do
    domain =
      case URI.parse(url) do
        %URI{host: host} when is_binary(host) ->
          host |> String.replace_leading("www.", "")

        _ ->
          url
      end

    {url, domain}
  end

  defp llm_model do
    ReqLLM.model!(%{
      provider: :openrouter,
      id: "google/gemini-3-flash-preview"
    })
  end
end
