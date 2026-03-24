defmodule CheckDay.Digests.Changes.NormalizeStock do
  @moduledoc """
  An Ash Change that intercepts block creation/updates for :stock blocks.
  It uses an LLM to accurately identify the target publicly traded company and extract
  their official US stock ticker symbol (e.g. "AAPL"), ensuring reliable price fetching.
  """
  use Ash.Resource.Change

  def change(changeset, _opts, _context) do
    type = Ash.Changeset.get_attribute(changeset, :type)

    if type == :stock do
      label = Ash.Changeset.get_attribute(changeset, :label)
      config = Ash.Changeset.get_attribute(changeset, :config) || %{}

      if Ash.Changeset.changing_attribute?(changeset, :label) or
         Ash.Changeset.changing_attribute?(changeset, :type) do
         
        {clean_name, symbol} = normalize(label)
        
        new_config = 
          config
          |> Map.put("company_name", clean_name)
          |> Map.put("symbol", symbol)

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
    The user wants to track a stock, entered as: "#{label}".
    Determine the primary publicly traded US company they are talking about and provide its official stock ticker symbol.
    """

    schema = Zoi.map(%{
      company_name: Zoi.string(description: "The clean company name (e.g., 'Apple Inc.', 'Tesla')."),
      symbol: Zoi.string(description: "The official stock ticker symbol on the US exchange (e.g., 'AAPL', 'TSLA').")
    })

    try do
      llm_model = ReqLLM.model!(%{provider: :openrouter, id: "google/gemini-3-flash-preview"})
      result = ReqLLM.generate_object!(llm_model, prompt, schema)
      
      clean_name = result[:company_name] || result["company_name"] || label
      symbol = result[:symbol] || result["symbol"] || label
      {clean_name, symbol}
    rescue
      _ -> {label, label}
    end
  end
end
