defmodule CheckDayWeb.DigestBlockController do
  use CheckDayWeb, :controller

  alias CheckDay.Digests.DigestBlock
  alias CheckDay.Accounts.User

  require Ash.Query

  @doc """
  Called by ElevenLabs Server Tool: add_digest_block
  Expects: type, label, config (optional), user_id
  """
  def add_block(conn, params) do
    with :ok <- verify_api_token(conn),
         {:ok, user} <- fetch_user(params),
         {:ok, block} <- create_block(user, params) do
      broadcast_update(user.id, {:block_added, block})

      json(conn, %{
        success: true,
        message: "Added #{block.label} to your digest.",
        block_id: block.id
      })
    else
      {:error, :unauthorized} ->
        conn |> put_status(401) |> json(%{error: "Unauthorized"})

      {:error, :user_not_found} ->
        conn |> put_status(404) |> json(%{error: "User not found"})

      {:error, changeset} ->
        conn |> put_status(422) |> json(%{error: format_errors(changeset)})
    end
  end

  @doc """
  Called by ElevenLabs Server Tool: remove_digest_block
  Expects: label or block_id, user_id
  """
  def remove_block(conn, params) do
    with :ok <- verify_api_token(conn),
         {:ok, user} <- fetch_user(params),
         {:ok, block} <- find_block(user, params),
         :ok <- destroy_block(block) do
      broadcast_update(user.id, {:block_removed, block})

      json(conn, %{
        success: true,
        message: "Removed #{block.label} from your digest."
      })
    else
      {:error, :unauthorized} ->
        conn |> put_status(401) |> json(%{error: "Unauthorized"})

      {:error, :user_not_found} ->
        conn |> put_status(404) |> json(%{error: "User not found"})

      {:error, :block_not_found} ->
        conn |> put_status(404) |> json(%{error: "Digest block not found"})

      {:error, reason} ->
        conn |> put_status(422) |> json(%{error: inspect(reason)})
    end
  end

  @doc """
  Called by ElevenLabs Server Tool: complete_onboarding
  Expects: user_id
  """
  def complete_onboarding(conn, params) do
    with :ok <- verify_api_token(conn),
         {:ok, user} <- fetch_user(params),
         {:ok, _user} <- mark_onboarding_complete(user) do
      broadcast_update(user.id, :onboarding_completed)

      json(conn, %{
        success: true,
        message: "Onboarding complete! Your daily digest is ready."
      })
    else
      {:error, :unauthorized} ->
        conn |> put_status(401) |> json(%{error: "Unauthorized"})

      {:error, :user_not_found} ->
        conn |> put_status(404) |> json(%{error: "User not found"})

      {:error, reason} ->
        conn |> put_status(422) |> json(%{error: inspect(reason)})
    end
  end

  # --- Private helpers ---

  defp verify_api_token(conn) do
    expected_token = Application.get_env(:check_day, :eleven_labs_webhook_secret)

    case get_req_header(conn, "x-api-key") do
      [token] when token == expected_token -> :ok
      _ -> {:error, :unauthorized}
    end
  end

  defp fetch_user(%{"user_id" => user_id}) when is_binary(user_id) do
    case Ash.get(User, user_id, authorize?: false) do
      {:ok, user} -> {:ok, user}
      {:error, _} -> {:error, :user_not_found}
    end
  end

  defp fetch_user(_), do: {:error, :user_not_found}

  defp create_block(user, params) do
    type =
      params
      |> Map.get("type", "custom")
      |> String.to_existing_atom()

    attrs = %{
      type: type,
      label: Map.get(params, "label", "Untitled"),
      config: Map.get(params, "config", %{}),
      position: Map.get(params, "position", 0),
      enabled: true,
      user_id: user.id
    }

    Ash.create(DigestBlock, attrs, authorize?: false)
  end

  defp find_block(user, %{"block_id" => block_id}) when is_binary(block_id) do
    case Ash.get(DigestBlock, block_id, authorize?: false) do
      {:ok, block} ->
        if block.user_id == user.id,
          do: {:ok, block},
          else: {:error, :block_not_found}

      {:error, _} ->
        {:error, :block_not_found}
    end
  end

  defp find_block(user, %{"label" => label}) when is_binary(label) do
    user_id = user.id

    DigestBlock
    |> Ash.Query.filter(user_id == ^user_id and label == ^label)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, [block | _]} -> {:ok, block}
      _ -> {:error, :block_not_found}
    end
  end

  defp find_block(_, _), do: {:error, :block_not_found}

  defp destroy_block(block) do
    case Ash.destroy(block, authorize?: false) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp mark_onboarding_complete(user) do
    Ash.update(user, %{onboarding_completed: true}, action: :update_profile, authorize?: false)
  end

  defp broadcast_update(user_id, message) do
    Phoenix.PubSub.broadcast(
      CheckDay.PubSub,
      "user:#{user_id}",
      {:digest_update, message}
    )
  end

  defp format_errors(%Ash.Error.Invalid{} = error) do
    error
    |> Map.get(:errors, [])
    |> Enum.map(& &1.message)
    |> Enum.join(", ")
  end

  defp format_errors(other), do: inspect(other)
end
