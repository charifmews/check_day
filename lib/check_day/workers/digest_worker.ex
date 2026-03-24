defmodule CheckDay.Workers.DigestWorker do
  @moduledoc """
  Per-user Oban worker that builds and sends a daily digest email.
  """
  use Oban.Worker, queue: :digests, max_attempts: 3

  require Ash.Query
  require Logger

  alias CheckDay.Digests.ContentFetcher
  alias CheckDay.Digests.DigestEmail
  alias CheckDay.Digests.DigestRun

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "date" => date_str}}) do
    user = Ash.get!(CheckDay.Accounts.User, user_id, authorize?: false)
    date = Date.from_iso8601!(date_str)
    day_of_week = Date.day_of_week(date)

    # Cooldown Check
    last_run_query =
      DigestRun
      |> Ash.Query.filter(user_id == ^user_id)
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(1)

    last_run = Ash.read_first!(last_run_query, authorize?: false)

    if false and last_run && DateTime.diff(DateTime.utc_now(), last_run.inserted_at, :second) < 8 * 3600 do
      Logger.info("Skipping digest for user #{user_id} - already generated within the last 8 hours")
      :ok
    else
      blocks =
        CheckDay.Digests.DigestBlock
        |> Ash.Query.filter(user_id == ^user_id and enabled == true)
        |> Ash.Query.sort(position: :asc)
        |> Ash.read!(authorize?: false)
        |> Enum.filter(fn block ->
          day_of_week in (block.active_days || [1, 2, 3, 4, 5, 6, 7])
        end)

      if blocks == [] do
        Logger.info("No active blocks for user #{user_id} on #{date_str}, skipping digest")
        :ok
      else
        # We will pass the historical block outputs sequentially so the LLM can Delta compress
        previous_blocks_data = if last_run, do: last_run.blocks_data, else: %{}

        sections = ContentFetcher.fetch_all(blocks, previous_blocks_data)

        # We extract the bare HTML template wrapper organically for posterity caching
        html_body = DigestEmail.render_html(user, date, sections)
        DigestEmail.build_and_send(user, date, sections)

        blocks_data_map =
          sections
          |> Enum.into(%{}, fn {b, content} -> {b.id, content} end)
          |> sanitize_for_json()

        DigestRun
        |> Ash.Changeset.for_create(:create, %{
          user_id: user_id,
          blocks_data: blocks_data_map,
          html_body: html_body
        })
        |> Ash.create!(authorize?: false)

        Logger.info("Digest sent and persisted for user #{user_id} on #{date_str} (#{length(sections)} sections)")
        :ok
      end
    end
  end

  defp sanitize_for_json(data) when is_tuple(data), do: data |> Tuple.to_list() |> sanitize_for_json()
  defp sanitize_for_json(data) when is_list(data), do: Enum.map(data, &sanitize_for_json/1)

  defp sanitize_for_json(%{} = data) do
    if Map.has_key?(data, :__struct__) do
      data |> Map.from_struct() |> sanitize_for_json()
    else
      data |> Enum.map(fn {k, v} -> {k, sanitize_for_json(v)} end) |> Enum.into(%{})
    end
  end

  defp sanitize_for_json(data), do: data
end
