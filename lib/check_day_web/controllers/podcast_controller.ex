defmodule CheckDayWeb.PodcastController do
  use CheckDayWeb, :controller

  def show(conn, %{"id" => run_id}) do
    current_user = conn.assigns[:current_user]

    if current_user do
      case Ash.get(CheckDay.Digests.DigestRun, run_id, authorize?: false) do
        {:ok, %{podcast_audio: audio} = run} when not is_nil(audio) ->
          if run.user_id == current_user.id do
            conn
            |> put_resp_content_type("audio/mpeg")
            |> put_resp_header("cache-control", "public, max-age=31536000")
            |> send_resp(200, audio)
          else
            conn |> put_status(:forbidden) |> text("Not authorized.")
          end

        _ ->
          conn
          |> put_status(:not_found)
          |> text("Podcast audio not found.")
      end
    else
      conn
      |> put_status(:unauthorized)
      |> text("Authentication required.")
    end
  end
end
