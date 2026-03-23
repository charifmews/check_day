defmodule CheckDay.Workers.DigestScheduler do
  @moduledoc """
  Oban cron worker that runs every minute.

  For each user, converts UTC now to their local timezone and checks if their
  digest time matches the current minute. If so, enqueues a DigestWorker.
  """
  use Oban.Worker, queue: :digests

  require Ash.Query

  @impl Oban.Worker
  def perform(_job) do
    utc_now = DateTime.utc_now()

    users = Ash.read!(CheckDay.Accounts.User, authorize?: false)

    Enum.each(users, fn user ->
      maybe_enqueue_digest(user, utc_now)
    end)

    :ok
  end

  defp maybe_enqueue_digest(user, utc_now) do
    timezone = user.timezone || "Etc/UTC"

    case DateTime.shift_zone(utc_now, timezone) do
      {:ok, local_now} ->
        today_dow = Date.day_of_week(DateTime.to_date(local_now))
        local_time_str = Calendar.strftime(local_now, "%H:%M")
        local_date = DateTime.to_date(local_now)

        expected_time =
          Map.get(user.digest_times || %{}, to_string(today_dow))

        if should_send_digest?(user, today_dow, local_date, local_time_str, expected_time) do
          %{user_id: user.id, date: Date.to_iso8601(local_date)}
          |> CheckDay.Workers.DigestWorker.new(unique: [keys: [:user_id, :date], period: 86_400])
          |> Oban.insert()
        end

      {:error, _} ->
        :skip
    end
  end

  defp should_send_digest?(user, today_dow, local_date, local_time_str, expected_time) do
    today_dow in (user.active_days || []) and
      local_date not in (user.skipped_dates || []) and
      local_time_str == expected_time
  end
end
