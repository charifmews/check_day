defmodule CheckDay.Digests.DigestRun do
  use Ash.Resource,
    domain: CheckDay.Digests,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "digest_runs"
    repo CheckDay.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:blocks_data, :html_body, :podcast_audio, :user_id]
    end

    read :latest_for_user do
      argument :user_id, :uuid do
        allow_nil? false
      end

      filter expr(user_id == ^arg(:user_id))
      prepare build(sort: [inserted_at: :desc], limit: 1)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :blocks_data, :map do
      allow_nil? false
      description "The raw JSON representation of the pulled blocks"
    end

    attribute :html_body, :string do
      allow_nil? false
      description "The baked HTML version of the digest email"
    end

    attribute :podcast_audio, :binary do
      allow_nil? true
      description "The generated raw MP3 audio payload from ElevenLabs"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :user, CheckDay.Accounts.User do
      allow_nil? false
    end
  end
end
