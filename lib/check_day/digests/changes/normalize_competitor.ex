defmodule CheckDay.Digests.Changes.NormalizeCompetitor do
  @moduledoc """
  An Ash Change that intercepts block creation/updates for :competitor blocks.
  It uses an LLM to accurately identify the target company and extract their official
  domain name (e.g. "stripe.com"), ensuring reliable competitor intelligence extraction.
  """
  use Ash.Resource.Change

  def change(changeset, _opts, _context) do
    type = Ash.Changeset.get_attribute(changeset, :type)

    if type == :competitor do
      label = Ash.Changeset.get_attribute(changeset, :label)
      config = Ash.Changeset.get_attribute(changeset, :config) || %{}

      if Ash.Changeset.changing_attribute?(changeset, :label) or
           Ash.Changeset.changing_attribute?(changeset, :type) do
        {clean_name, domain} = normalize(label)

        new_config =
          config
          |> Map.put("company_name", clean_name)
          |> Map.put("domain", domain)

        changeset
        |> Ash.Changeset.force_change_attribute(:label, clean_name)
        |> Ash.Changeset.force_change_attribute(:config, new_config)
      else
        changeset
      end
    else
      changeset
    end
  end

  defp normalize(nil), do: {nil, nil}
  defp normalize(""), do: {"", ""}

  defp normalize(label) do
    prompt = """
    The user wants to track a company, entered as: "#{label}".
    Determine the primary company they are talking about and identify their official web domain.
    Do NOT hallucinate a generic domain; determine their actual tech/startup domain (e.g., linear.app, stripe.com, vercel.com).
    """

    schema =
      Zoi.map(%{
        company_name:
          Zoi.string(
            description: "The clean company name (e.g., 'Linear', 'OpenAI', 'Anthropic')."
          ),
        domain:
          Zoi.string(
            description: "The company's primary web domain (e.g., 'linear.app', 'openai.com')."
          )
      })

    try do
      llm_model = ReqLLM.model!(%{provider: :openrouter, id: "google/gemini-3-flash-preview"})
      result = ReqLLM.generate_object!(llm_model, prompt, schema)

      clean_name = result[:company_name] || result["company_name"] || label
      domain = result[:domain] || result["domain"] || label
      {clean_name, domain}
    rescue
      _ -> {label, label}
    end
  end
end
