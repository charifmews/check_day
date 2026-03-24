defmodule CheckDay.Digests.DigestBlock do
  use Ash.Resource,
    otp_app: :check_day,
    domain: CheckDay.Digests,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "digest_blocks"
    repo CheckDay.Repo

    migration_defaults active_days: "'[1,2,3,4,5,6,7]'"
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:type, :label, :config, :position, :enabled, :active_days, :user_id]
      change CheckDay.Digests.Changes.NormalizeWeatherLocation
    end

    update :update do
      accept [:type, :label, :config, :position, :enabled, :active_days]
      change CheckDay.Digests.Changes.NormalizeWeatherLocation
    end

    update :update_days do
      accept [:active_days]
    end

    update :reorder do
      accept [:position]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :type, :atom do
      constraints one_of: [
                    :weather,
                    :news,
                    :interest,
                    :competitor,
                    :stock,
                    :agenda,
                    :habit,
                    :custom
                  ]

      allow_nil? false
      public? true
    end

    attribute :label, :string do
      allow_nil? false
      public? true
    end

    attribute :config, :map do
      default %{}
      public? true
    end

    attribute :position, :integer do
      default 0
      public? true
    end

    attribute :enabled, :boolean do
      default true
      public? true
    end

    attribute :active_days, {:array, :integer} do
      default [1, 2, 3, 4, 5, 6, 7]
      public? true
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
