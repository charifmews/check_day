defmodule CheckDay.Repo.Migrations.AddDigestRuns do
  use Ecto.Migration

  def change do
    create table(:digest_runs, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"), null: false
      add :blocks_data, :map, null: false
      add :html_body, :text, null: false

      add :user_id,
          references(:users,
            column: :id,
            name: "digest_runs_user_id_fkey",
            type: :uuid,
            prefix: "public",
            on_delete: :delete_all
          ),
          null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create index(:digest_runs, [:user_id])
  end
end
