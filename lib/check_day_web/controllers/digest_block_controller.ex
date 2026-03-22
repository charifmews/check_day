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

  @doc """
  Called by ElevenLabs Server Tool: set_digest_time
  Expects: user_id, time (HH:MM format), optional day (1-7, omit to set all days)
  """
  def set_digest_time(conn, params) do
    with :ok <- verify_api_token(conn),
         {:ok, user} <- fetch_user(params),
         {:ok, time_str} <- parse_time_string(params),
         {:ok, new_times} <- build_digest_times(user, params, time_str),
         {:ok, _user} <- update_digest_times(user, new_times) do
      broadcast_update(user.id, {:digest_times_changed, new_times})

      json(conn, %{
        success: true,
        message: "Digest time updated"
      })
    else
      {:error, :unauthorized} ->
        conn |> put_status(401) |> json(%{error: "Unauthorized"})

      {:error, :user_not_found} ->
        conn |> put_status(404) |> json(%{error: "User not found"})

      {:error, :invalid_time} ->
        conn |> put_status(422) |> json(%{error: "Invalid time format. Use HH:MM"})

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

  defp find_block(user, %{"block_id" => block_id} = params) when is_binary(block_id) do
    case Ash.get(DigestBlock, block_id, authorize?: false) do
      {:ok, block} ->
        if block.user_id == user.id,
          do: {:ok, block},
          else: find_block_by_label(user, params)

      {:error, _} ->
        find_block_by_label(user, params)
    end
  end

  defp find_block(user, %{"label" => _} = params), do: find_block_by_label(user, params)

  defp find_block(_, _), do: {:error, :block_not_found}

  defp find_block_by_label(user, %{"label" => label}) when is_binary(label) do
    user_id = user.id

    DigestBlock
    |> Ash.Query.filter(user_id == ^user_id and label == ^label)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, [block | _]} -> {:ok, block}
      _ -> {:error, :block_not_found}
    end
  end

  defp find_block_by_label(_, _), do: {:error, :block_not_found}

  defp destroy_block(block) do
    case Ash.destroy(block, authorize?: false) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp mark_onboarding_complete(user) do
    Ash.update(user, %{onboarding_completed: true}, action: :update_profile, authorize?: false)
  end

  defp parse_time_string(%{"time" => time_str}) when is_binary(time_str) do
    time_str = String.trim(time_str)
    # Validate the time format
    case Time.from_iso8601(time_str <> ":00") do
      {:ok, _time} ->
        {:ok, String.slice(time_str, 0, 5)}

      {:error, _} ->
        case Time.from_iso8601(time_str) do
          {:ok, _time} -> {:ok, String.slice(time_str, 0, 5)}
          {:error, _} -> {:error, :invalid_time}
        end
    end
  end

  defp parse_time_string(_), do: {:error, :invalid_time}

  defp build_digest_times(user, %{"day" => day_str}, time_str) when is_binary(day_str) do
    current = user.digest_times || default_digest_times()
    {:ok, Map.put(current, day_str, time_str)}
  end

  defp build_digest_times(user, _, time_str) do
    current = user.digest_times || default_digest_times()
    new_times = Map.new(current, fn {k, _v} -> {k, time_str} end)
    {:ok, new_times}
  end

  defp default_digest_times do
    %{
      "1" => "07:00",
      "2" => "07:00",
      "3" => "07:00",
      "4" => "07:00",
      "5" => "07:00",
      "6" => "07:00",
      "7" => "07:00"
    }
  end

  defp update_digest_times(user, times) do
    Ash.update(user, %{digest_times: times}, action: :update_profile, authorize?: false)
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
