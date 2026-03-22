defmodule CheckDay.Repo.Migrations.ReplaceDigestTimeWithMap do
  @moduledoc """
  Replaces the single digest_time column with a digest_times JSONB map
  containing per-day times.
  """

  use Ecto.Migration

  def up do
    alter table(:users) do
      remove :digest_time
    end

    alter table(:users) do
      add :digest_times, :map,
        default:
          fragment(
            ~s|'{"1":"07:00","2":"07:00","3":"07:00","4":"07:00","5":"07:00","6":"07:00","7":"07:00"}'::jsonb|
          )
    end
  end

  def down do
    alter table(:users) do
      remove :digest_times
    end

    alter table(:users) do
      add :digest_time, :time, default: fragment("'07:00:00'")
    end
  end
end
