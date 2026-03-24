defmodule CheckDay.Accounts.User do
  use Ash.Resource,
    otp_app: :check_day,
    domain: CheckDay.Accounts,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthentication],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "users"
    repo CheckDay.Repo

    migration_defaults active_days: "\"{1,2,3,4,5,6,7}\"",
                       digest_times:
                         "\"{\\\"1\\\":\\\"07:00\\\",\\\"2\\\":\\\"07:00\\\",\\\"3\\\":\\\"07:00\\\",\\\"4\\\":\\\"07:00\\\",\\\"5\\\":\\\"07:00\\\",\\\"6\\\":\\\"07:00\\\",\\\"7\\\":\\\"07:00\\\"}\""
  end

  authentication do
    add_ons do
      log_out_everywhere do
        apply_on_password_change? true
      end
    end

    tokens do
      enabled? true
      token_resource CheckDay.Accounts.Token
      signing_secret CheckDay.Secrets
      store_all_tokens? true
      require_token_presence_for_authentication? true
    end

    strategies do
      magic_link do
        identity_field :email
        registration_enabled? true
        require_interaction? true

        sender CheckDay.Accounts.User.Senders.SendMagicLinkEmail
      end

      remember_me :remember_me
    end
  end

  actions do
    defaults [:read]

    update :update_profile do
      accept [
        :first_name,
        :active_days,
        :skipped_dates,
        :digest_times,
        :timezone
      ]
    end

    read :get_by_subject do
      description "Get a user by the subject claim in a JWT"
      argument :subject, :string, allow_nil?: false
      get? true
      prepare AshAuthentication.Preparations.FilterBySubject
    end

    read :get_by_email do
      description "Looks up a user by their email"
      get_by :email
    end

    create :sign_in_with_magic_link do
      description "Sign in or register a user with magic link."

      argument :token, :string do
        description "The token from the magic link that was sent to the user"
        allow_nil? false
      end

      argument :remember_me, :boolean do
        description "Whether to generate a remember me token"
        allow_nil? true
      end

      upsert? true
      upsert_identity :unique_email
      upsert_fields [:email, :timezone]

      # Uses the information from the token to create or sign in the user
      change AshAuthentication.Strategy.MagicLink.SignInChange

      change {AshAuthentication.Strategy.RememberMe.MaybeGenerateTokenChange,
              strategy_name: :remember_me}

      metadata :token, :string do
        allow_nil? false
      end
    end

    action :request_magic_link do
      argument :email, :ci_string do
        allow_nil? false
      end

      run AshAuthentication.Strategy.MagicLink.Request
    end
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :email, :ci_string do
      allow_nil? false
      public? true
    end

    attribute :first_name, :string do
      allow_nil? true
      public? true
    end

    attribute :active_days, {:array, :integer} do
      default [1, 2, 3, 4, 5, 6, 7]
      public? true
    end

    attribute :skipped_dates, {:array, :date} do
      default []
      public? true
    end

    attribute :digest_times, :map do
      default %{
        "1" => "07:00",
        "2" => "07:00",
        "3" => "07:00",
        "4" => "07:00",
        "5" => "07:00",
        "6" => "07:00",
        "7" => "07:00"
      }

      public? true
    end

    attribute :timezone, :string do
      default "Etc/UTC"
      public? true
    end
  end

  relationships do
    has_many :digest_blocks, CheckDay.Digests.DigestBlock
  end

  identities do
    identity :unique_email, [:email]
  end
end
