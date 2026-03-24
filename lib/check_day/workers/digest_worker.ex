defmodule CheckDay.Workers.DigestWorker do
  @moduledoc """
  Per-user Oban worker that builds and sends a daily digest email.

  1. Loads the user and their enabled digest blocks for today's day-of-week
  2. Fetches content for each block via ContentFetcher (Firecrawl + LLM validation)
  3. Assembles and sends the HTML digest email
  """
  use Oban.Worker, queue: :digests, max_attempts: 3

  require Ash.Query
  require Logger

  alias CheckDay.Digests.ContentFetcher
  alias CheckDay.Digests.DigestEmail

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "date" => date_str}}) do
    user = Ash.get!(CheckDay.Accounts.User, user_id, authorize?: false)
    date = Date.from_iso8601!(date_str)
    day_of_week = Date.day_of_week(date)

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
      sections = ContentFetcher.fetch_all(blocks)
      DigestEmail.build_and_send(user, date, sections)

      # TODO: Future — kick off podcast generation here
      # CheckDay.Workers.PodcastWorker.new(%{user_id: user_id, date: date_str, sections: ...})
      # |> Oban.insert()

      Logger.info("Digest sent for user #{user_id} on #{date_str} (#{length(sections)} sections)")
      :ok
    end
  end
end
