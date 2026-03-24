defmodule CheckDay.Digests.Changes.NormalizeWeatherLocation do
  @moduledoc """
  An Ash Change that intercepts block creation/updates. If the block is a :weather block,
  it uses an LLM to smartly strip conversational metadata (e.g., "Weather in Amsterdam")
  into a clean location name ("Amsterdam") and injects it into both the label and config.
  """
  use Ash.Resource.Change

  def change(changeset, _opts, _context) do
    type = Ash.Changeset.get_attribute(changeset, :type)

    if type == :weather do
      label = Ash.Changeset.get_attribute(changeset, :label)
      config = Ash.Changeset.get_attribute(changeset, :config) || %{}

      # Normalize only if the label or type has actively changed to avoid redundant LLM calls
      if Ash.Changeset.changing_attribute?(changeset, :label) or
         Ash.Changeset.changing_attribute?(changeset, :type) do
         
        clean_loc = normalize(label)
        
        # Keep any other config intact but force standard location
        new_config = Map.put(config, "location", clean_loc)

        changeset
        |> Ash.Changeset.force_change_attribute(:label, clean_loc)
        |> Ash.Changeset.force_change_attribute(:config, new_config)
      else
        changeset
      end
    else
      changeset
    end
  end

  defp normalize(nil), do: nil
  defp normalize(""), do: ""
  defp normalize(label) do
    prompt = """
    The user entered a weather location string: "#{label}".
    Extract ONLY the raw city/country name from this string, stripping out any conversational text like "Weather in", "Is it raining in", "weather", etc.
    Capitalize it properly. If it's already just a location, return it exactly as is.
    """

    schema = Zoi.map(%{
      location: Zoi.string(description: "The cleaned, capitalized location string")
    })

    try do
      llm_model = ReqLLM.model!(%{provider: :openrouter, id: "google/gemini-3-flash-preview"})
      result = ReqLLM.generate_object!(llm_model, prompt, schema)
      result[:location] || result["location"] || label
    rescue
      _ -> label
    end
  end
end
