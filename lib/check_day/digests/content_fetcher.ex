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
  """
  def fetch(block, previous_context \\ nil) do
    route_firecrawl_strategy(block, previous_context)
  end

  @doc """
  Concurrently fetches content for a list of blocks and filters out failures.
  """
  def fetch_all(blocks, previous_blocks_data \\ %{}) do
    blocks
    |> Task.async_stream(
      fn block ->
        case fetch(block, Map.get(previous_blocks_data, block.id)) do
          {:ok, results} -> {block, results}
          {:error, reason} ->
            Logger.warning("Failed to fetch content for block #{block.id}: #{inspect(reason)}")
            {block, []}
        end
      end,
      timeout: :infinity,
      max_concurrency: 3
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, reason} ->
        Logger.error("Content fetch task crashed: #{inspect(reason)}")
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp route_firecrawl_strategy(%{type: t} = block, previous_context) when t in [:news, :interest] do
    fetch_via_hub_crawler(block, previous_context)
  end

  defp route_firecrawl_strategy(%{type: :weather} = block, previous_context) do
    fetch_via_weather_api(block, previous_context)
  end

  defp route_firecrawl_strategy(%{type: :competitor} = block, previous_context) do
    fetch_via_competitor_crawler(block, previous_context)
  end

  defp route_firecrawl_strategy(%{type: :stock} = block, previous_context) do
    fetch_via_stock_api(block, previous_context)
  end

  defp route_firecrawl_strategy(block, previous_context) do
    fetch_via_basic_search(block, previous_context)
  end

  # ===========================================================================
  # STRATEGY: LEGACY BASIC SEARCH (For :weather, :stock, :competitor, :custom)
  # ===========================================================================

  defp fetch_via_basic_search(block, _previous_context) do
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

  # ===========================================================================
  # STRATEGY: ADVANCED WEATHER API (For :weather)
  # ===========================================================================

  @weather_schema Zoi.map(%{
    headline: Zoi.string(description: "A short, engaging headline (e.g., 'Sunny in Paris', 'Grab an umbrella in London')"),
    summary: Zoi.string(description: "The concise 1-3 sentence markdown summary.")
  })

  defp fetch_via_weather_api(block, _previous_context) do
    location = block.config["location"] || block.label
    Logger.info("Weather API initiated for location: #{location}")

    case Req.get("https://nominatim.openstreetmap.org/search", 
           params: [q: location, format: "json", limit: 1],
           headers: [{"User-Agent", "CheckDay_Production_App"}]
         ) do
      {:ok, %Req.Response{status: 200, body: [geo | _]}} ->
        lat = geo["lat"]
        lon = geo["lon"]
        display_name = geo["display_name"]
        
        case Req.get("https://api.open-meteo.com/v1/forecast", params: [
               latitude: lat,
               longitude: lon,
               current: "temperature_2m,weather_code,precipitation,cloud_cover",
               daily: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_sum,precipitation_probability_max",
               timezone: "auto"
             ]) do
          {:ok, %Req.Response{status: 200, body: weather_data}} ->
            prompt = """
            You are a helpful assistant writing a brief weather summary for a daily digest app.
            The user's location is precisely: #{display_name}.
            
            Here is the raw, 100% accurate numerical JSON weather data for today:
            #{Jason.encode!(weather_data)}
            
            RULES:
            - Write a highly engaging, concise (1-3 sentences) markdown summary.
            - You MUST explicitly include the current temperature.
            - You MUST explicitly include today's high and low.
            - Note any significant precipitation or lack thereof.
            - Provide temperatures natively (e.g., if the JSON data is in Celsius, write it as °C).
            - Do NOT hallucinate temperatures or conditions. Rely ONLY on the provided JSON numbers.
            """
            
            try do
              result = ReqLLM.generate_object!(llm_model(), prompt, @weather_schema)
              
              {:ok, [
                %{
                  headline: result[:headline] || result["headline"] || "Weather for #{location}",
                  digest_summary: result[:summary] || result["summary"],
                  sources: [{"https://open-meteo.com/", "open-meteo.com"}, {"https://nominatim.openstreetmap.org/", "openstreetmap.org"}]
                }
              ]}
            rescue
              e ->
                Logger.error("Weather LLM parsing failed: #{inspect(e)}")
                {:error, "Failed to parse weather"}
            end
            
          _ ->
             Logger.error("Open-Meteo forecast failed")
             {:error, "Open-Meteo forecast failed"}
        end
        
      _ ->
        Logger.error("Nominatim geocoding failed for #{location}")
        {:error, "Nominatim geocoding failed"}
    end
  end

  # ===========================================================================
  # STRATEGY: LIVE STOCK API (For :stock)
  # ===========================================================================

  @stock_final_schema Zoi.map(%{
    headline: Zoi.string(description: "A sharp headline with the stock ticker and price movement (e.g. 'AAPL is up 1.5% today')."),
    digest_markdown: Zoi.string(description: "A rich markdown body synthesizing the stock performance and linking to the recent news stories using markdown links [Title](URL)."),
    source_urls: Zoi.list(Zoi.string(), description: "A list of the raw news URLs used as sources.")
  })

  defp fetch_via_stock_api(block, _previous_context) do
    config = block.config || %{}
    company = config["company_name"] || block.label
    symbol = config["symbol"] || block.label

    Logger.info("Stock API initiated for: #{company} (#{symbol})")

    url = "https://query1.finance.yahoo.com/v8/finance/chart/#{symbol}?interval=1d&range=1d"
    
    price_json = 
      case Req.get(url, headers: [{"User-Agent", "Mozilla/5.0"}]) do
        {:ok, %Req.Response{status: 200, body: body}} ->
          Jason.encode!(body)
        _ ->
          nil
      end

    rss_url = "https://feeds.finance.yahoo.com/rss/2.0/headline?s=#{symbol}&region=US&lang=en-US"
    
    news_xml =
      case Req.get(rss_url, headers: [{"User-Agent", "Mozilla/5.0"}]) do
        {:ok, %Req.Response{status: 200, body: body}} ->
          if is_binary(body), do: String.slice(body, 0, 10000), else: "No news parsing"
        _ ->
          nil
      end

    prompt_final = """
    You are generating a daily digest block for the stock: #{symbol} (#{company}).
    
    I am providing you with two strictly accurate data sources:
    
    1. RAW JSON PRICE DATA (From Yahoo Finance chart endpoint):
    #{price_json || "Not available"}
    
    2. RAW RSS NEWS FEED (From Yahoo Finance):
    #{news_xml || "Not available"}
    
    RULES:
    - Write a highly engaging, concise, professional final digest.
    - Extract the actual current price, and if possible, calculate the percentage change from the previous close using the JSON data.
    - Explain *why* the stock might be moving today by extracting the top 1-3 breaking news headlines from the XML feed.
    - Embed the most interesting news links directly into your summary using ONLY markdown links [Title](URL).
    - If either piece of data is missing, fail gracefully.
    - Do NOT hallucinate numbers! Rely only on the JSON payload.
    """

    try do
      result = ReqLLM.generate_object!(llm_model(), prompt_final, @stock_final_schema)
      
      raw_source_urls = result[:source_urls] || result["source_urls"] || []
      sources = Enum.map(raw_source_urls, &source_tuple/1)

      {:ok, [
        %{
          headline: result[:headline] || result["headline"] || "#{symbol} Stock Update",
          digest_summary: result[:digest_markdown] || result["digest_markdown"],
          sources: sources
        }
      ]}
    rescue
      e ->
        Logger.error("Failed to synthesize stock data: #{inspect(e)}")
        {:error, "Failed to synthesize stock data"}
    end
  end

  # ===========================================================================
  # STRATEGY: ADVANCED HUB CRAWLER (For :news, :interest)
  # ===========================================================================

  @source_schema Zoi.map(%{
    urls: Zoi.list(Zoi.string(), description: "The exact, direct URLs (must include https://) to the 'latest news', 'discussions', or 'blog' indexes of the top 3 best community sites for this topic.")
          |> Zoi.min(3)
          |> Zoi.max(5)
  })

  @hub_schema Zoi.map(%{
    discussions: Zoi.list(Zoi.string(), description: "Top active discussion titles with their full absolute URLs, formatted strictly as markdown links: [Title](URL).")
                 |> Zoi.max(5),
    community_sentiment: Zoi.string(description: "A 1-2 sentence summary of the general community focus right now based on these recent topics.")
  })

  @final_schema Zoi.map(%{
    headline: Zoi.string(description: "An overarching headline for the digest block."),
    digest_markdown: Zoi.string(description: "A rich markdown body synthesizing the recent community discussions across all sources. Include inline markdown links [Title](URL) to the most important discussions."),
    source_urls: Zoi.list(Zoi.string(), description: "A list of strings of the raw URLs used as sources.")
  })

  defp fetch_via_hub_crawler(block, previous_context) do
    delta_str = delta_instruction(previous_context)
    topic = block_topic(block)
    Logger.info("Advanced Hub Crawler initiated for topic: #{topic}")

    prompt = """
    The user wants to track community news and active discussions about: "#{topic}".
    Identify the absolute best specific forum, community aggregator, or trusted news site index pages for this.
    Instead of just the domain, provide the FULL, direct URL to their 'latest' or 'news' index page.
    For example, instead of 'news.yCombinator.com', use 'https://news.ycombinator.com'.
    Instead of 'elixirforum.com', use 'https://elixirforum.com/latest'.
    IMPORTANT: Do NOT suggest reddit.com, twitter.com, x.com, facebook.com, or linkedin.com, as they block scrapers.
    Provide minimum 3 and maximum 5 URLs.
    """

    urls =
      try do
        result = ReqLLM.generate_object!(llm_model(), prompt, @source_schema)
        result[:urls] || result["urls"] || []
      rescue
        e ->
          Logger.error("LLM URL sourcing failed: #{inspect(e)}")
          []
      end

    if urls == [] do
      {:ok, [%{headline: block.label, digest_summary: "No relevant community hubs could be found for this topic.", sources: []}]}
    else
      # We use Task.async_stream to scrape all hubs concurrently
      all_findings =
        urls
        |> Task.async_stream(fn url ->
          case Firecrawl.scrape_and_extract_from_url(
                 url: url,
                 formats: ["markdown"],
                 only_main_content: true,
                 timeout: 45_000
               ) do
            {:ok, %Req.Response{status: 200, body: %{"data" => %{"markdown" => markdown}}}} ->
              if markdown && markdown != "" do
                extracted = extract_hub(url, markdown, topic, delta_str)
                has_discussions = case extracted[:discussions] || extracted["discussions"] do
                  list when is_list(list) and length(list) > 0 -> true
                  _ -> false
                end

                if has_discussions do
                  %{url: url, findings: extracted}
                else
                  nil
                end
              else
                nil
              end
            _ ->
              nil
          end
        end, timeout: 50_000)
        |> Enum.map(fn
          {:ok, result} -> result
          {:exit, _} -> nil
        end)
        |> Enum.reject(&is_nil/1)

      if all_findings == [] do
         {:ok, [%{headline: block.label, digest_summary: "The community has been quiet on this topic over the last 24 hours. No recent discussions were detected.", sources: []}]}
      else
         combine_hub_findings(topic, all_findings)
      end
    end
  end

  defp extract_hub(url, markdown, topic, delta_str) do
    current_date = DateTime.utc_now() |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")

    prompt = """
    #{delta_str}
    You are reading an index page (forum, news aggregator, or blog) related to #{topic}.
    The base URL is: #{url}. Use this to convert relative links to absolute links.
    Today's current date and time is: #{current_date}.
    
    Extract the most active / top headlines or discussions listed on the page.
    IMPORTANT CRITICAL INSTRUCTION: You must ONLY extract discussions that are extremely recent (published or last replied to within the last 24 to 48 hours). 
    Ignore anything older than a few days. Look closely at timestamps, dates like "2h" or "yesterday", or compare dates with the current date to determine recency.
    If there are no discussions from the last 2 days on this page, return an empty array for discussions.
    
    Provide a general summary of the trending topics from these recent discussions.

    SOURCE MATERIAL:
    #{markdown}
    """

    try do
      ReqLLM.generate_object!(llm_model(), prompt, @hub_schema)
    rescue
      _ -> %{}
    end
  end

  defp combine_hub_findings(topic, all_findings) do
    findings_text =
      all_findings
      |> Enum.map(fn f ->
        """
        SOURCE HUB: #{f.url}
        DISCUSSIONS:
        #{Enum.join(f.findings[:discussions] || f.findings["discussions"] || [], "\n")}
        SENTIMENT: #{f.findings[:community_sentiment] || f.findings["community_sentiment"]}
        """
      end)
      |> Enum.join("\n\n")

    prompt = """
    You are generating a daily digest block for the topic: "#{topic}".
    I have scraped multiple community hubs and extracted ONLY the most recent, top discussions from the last 24-48 hours.
    
    FINDINGS:
    #{findings_text}
    
    Create a highly engaging, concise final digest. 
    Synthesize the information. If multiple hubs talk about the same release, combine them.
    Embed the most interesting links directly into your summary using ONLY markdown links [Title](URL).
    """

    try do
      result = ReqLLM.generate_object!(llm_model(), prompt, @final_schema)
      
      raw_source_urls = result[:source_urls] || result["source_urls"] || []
      sources = Enum.map(raw_source_urls, &source_tuple/1)

      {:ok, [
        %{
          headline: result[:headline] || result["headline"] || topic,
          digest_summary: result[:digest_markdown] || result["digest_markdown"],
          sources: sources
        }
      ]}
    rescue
      e ->
        Logger.error("Failed to combine findings: #{inspect(e)}")
        {:error, "Failed to combine findings"}
    end
  end


  # ===========================================================================
  # STRATEGY: ADVANCED COMPETITOR CRAWLER (For :competitor)
  # ===========================================================================

  @competitor_source_schema Zoi.map(%{
    urls: Zoi.list(Zoi.string(), description: "The exact, absolute URLs to the OFFICIAL 'blog', 'changelog', or 'newsroom' pages of the company.")
          |> Zoi.min(2)
          |> Zoi.max(3)
  })

  @competitor_intel_schema Zoi.map(%{
    announcements: Zoi.list(Zoi.string(), description: "Top recent product announcements or feature releases with their full absolute URLs, formatted strictly as markdown links: [Title](URL).")
                   |> Zoi.max(5),
    strategic_focus: Zoi.string(description: "A 1-2 sentence summary of what this company is focusing heavily on right now based on these updates.")
  })

  @competitor_final_schema Zoi.map(%{
    headline: Zoi.string(description: "A sharp headline capturing the competitor's recent momentum."),
    digest_markdown: Zoi.string(description: "A rich markdown body synthesizing the recent announcements. Include inline markdown links [Title](URL). Format beautifully as a bulleted list where appropriate."),
    source_urls: Zoi.list(Zoi.string(), description: "A list of strings of the raw URLs used as sources.")
  })

  defp fetch_via_competitor_crawler(block, previous_context) do
    delta_str = delta_instruction(previous_context)
    config = block.config || %{}
    company_name = config["company_name"] || block.label
    domain = config["domain"] || company_name

    Logger.info("Advanced Competitor Crawler initiated for: #{company_name}")

    prompt = """
    We want to track the latest official announcements, press releases, or changelogs for the company: #{company_name} (#{domain}).
    Provide the top 2-3 direct absolute URLs to their OFFICIAL blog, newsroom, press, or changelog index pages.
    (e.g., https://#{domain}/blog or https://#{domain}/changelog or https://#{domain}/news).
    """

    urls =
      try do
        result = ReqLLM.generate_object!(llm_model(), prompt, @competitor_source_schema)
        result[:urls] || result["urls"] || []
      rescue
        e ->
          Logger.error("LLM URL sourcing failed for competitor: #{inspect(e)}")
          []
      end

    if urls == [] do
      {:ok, [%{headline: block.label, digest_summary: "No official announcement pages could be pinpointed for this company.", sources: []}]}
    else
      all_findings =
        urls
        |> Task.async_stream(fn url ->
          case Firecrawl.scrape_and_extract_from_url(
                 url: url,
                 formats: ["markdown"],
                 only_main_content: true,
                 timeout: 45_000
               ) do
            {:ok, %Req.Response{status: 200, body: %{"data" => %{"markdown" => markdown}}}} ->
              if markdown && markdown != "" do
                extracted = extract_competitor(url, markdown, company_name, delta_str)
                has_announcements = case extracted[:announcements] || extracted["announcements"] do
                  list when is_list(list) and length(list) > 0 -> true
                  _ -> false
                end

                if has_announcements do
                  %{url: url, findings: extracted}
                else
                  nil
                end
              else
                nil
              end
            _ -> nil
          end
        end, timeout: 50_000)
        |> Enum.map(fn
          {:ok, result} -> result
          {:exit, _} -> nil
        end)
        |> Enum.reject(&is_nil/1)

      if all_findings == [] do
         {:ok, [%{headline: block.label, digest_summary: "No major product announcements or news detected in the last 14-30 days.", sources: []}]}
      else
         combine_competitor_findings(company_name, all_findings)
      end
    end
  end

  defp extract_competitor(url, markdown, company_name, delta_str) do
    current_date = DateTime.utc_now() |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")

    prompt = """
    #{delta_str}
    You are reading an official index page (blog, changelog, newsroom) for the company: #{company_name}.
    The base URL is: #{url}. Use this to convert relative links to absolute links.
    Today's current date and time is: #{current_date}.
    
    Extract the most important recent product announcements, feature releases, or strategic news listed on the page.
    IMPORTANT CRITICAL INSTRUCTION: Extract the absolute latest, most recent announcements present on this page. Focus on the very top of the feed or timeline to grab their newest updates.
    Do NOT return an empty array if there is recent news; extract the top items.
    
    SOURCE MATERIAL:
    #{markdown}
    """

    try do
      ReqLLM.generate_object!(llm_model(), prompt, @competitor_intel_schema)
    rescue
      _ -> %{}
    end
  end

  defp combine_competitor_findings(company_name, all_findings) do
    findings_text =
      all_findings
      |> Enum.map(fn f ->
        """
        SOURCE: #{f.url}
        ANNOUNCEMENTS:
        #{Enum.join(f.findings[:announcements] || f.findings["announcements"] || [], "\n")}
        STRATEGIC FOCUS: #{f.findings[:strategic_focus] || f.findings["strategic_focus"]}
        """
      end)
      |> Enum.join("\n\n")

    prompt = """
    You are generating a daily digest block for competitor intelligence on: "#{company_name}".
    I have scraped their official blogs/changelogs and extracted ONLY the most recent product updates and announcements.
    
    FINDINGS:
    #{findings_text}
    
    Create a highly engaging, concise, professional final digest. 
    Synthesize the information. If there are multiple updates, summarize them cleanly using bullet points.
    Embed the most interesting links directly into your summary using ONLY markdown links [Title](URL).
    """

    try do
      result = ReqLLM.generate_object!(llm_model(), prompt, @competitor_final_schema)
      
      raw_source_urls = result[:source_urls] || result["source_urls"] || []
      sources = Enum.map(raw_source_urls, &source_tuple/1)

      {:ok, [
        %{
          headline: result[:headline] || result["headline"] || company_name,
          digest_summary: result[:digest_markdown] || result["digest_markdown"],
          sources: sources
        }
      ]}
    rescue
      e ->
        Logger.error("Failed to combine competitor findings: #{inspect(e)}")
        {:error, "Failed to combine findings"}
    end
  end


  # ===========================================================================
  # QUERY BUILDER & SHARED HELPERS
  # ===========================================================================

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

  # -- Parsing & deduplication for legacy search -----------------------------

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

  # -- LLM extraction with relevance check for legacy search -----------------

  @extraction_schema [
    relevant: [
      type: :boolean,
      required: true,
      doc: "Is this content actually about the TOPIC? true if relevant, false if off-topic."
    ],
    headline: [
      type: :string,
      required: true,
      doc: "The main headline of the article. Return null if not found."
    ],
    digest_summary: [
      type: :string,
      required: true,
      doc: "A concise summary of the key facts. Return null if not found."
    ],
    verbatim_quote: [
      type: :string,
      required: true,
      doc: "An exact quote from the source material. Return null if not found."
    ]
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

  # -- Group & combine similar results for legacy search ---------------------

  @combine_schema [
    headline: [
      type: :string,
      required: true,
      doc: "A single headline that best represents all the sources combined."
    ],
    digest_summary: [
      type: :string,
      required: true,
      doc:
        "A concise combined summary synthesizing all sources into one coherent paragraph. Include the most important facts from each source without repeating."
    ]
  ]

  defp combine_results([], _block), do: []

  defp combine_results([single], _block) do
    [
      %{
        headline: single.headline,
        digest_summary: single.digest_summary,
        sources: [source_tuple(single.source_url)]
      }
    ]
  end

  defp combine_results(results, block) do
    groups = group_similar(results, block)

    Enum.flat_map(groups, fn group ->
      case group do
        [single] ->
          [
            %{
              headline: single.headline,
              digest_summary: single.digest_summary,
              sources: [source_tuple(single.source_url)]
            }
          ]

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
      schema = [
        groups: [
          type: {:list, {:list, :pos_integer}},
          required: true,
          doc:
            "Array of arrays of 1-based result indices. Each inner array is a group of similar results."
        ]
      ]

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

      [
        %{
          headline: combined[:headline] || combined["headline"],
          digest_summary: combined[:digest_summary] || combined["digest_summary"],
          sources: sources
        }
      ]
    rescue
      e ->
        Logger.warning("Merge failed: #{inspect(e)}, returning first result")

        [
          %{
            headline: hd(results).headline,
            digest_summary: hd(results).digest_summary,
            sources: sources
          }
        ]
    end
  end

  defp source_tuple(nil), do: {nil, nil}

  defp source_tuple(url) do
    domain =
      case URI.parse(to_string(url)) do
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
  defp delta_instruction(nil), do: ""
  defp delta_instruction(prev) do
    "\n\nCRITICAL CONTEXT: Here is the data from exactly the last successful run: #{inspect(prev)}\nHighlight and focus exclusively on NEW developments that have happened since then!"
  end
end
