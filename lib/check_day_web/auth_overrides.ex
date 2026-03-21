defmodule CheckDayWeb.AuthOverrides do
  use AshAuthentication.Phoenix.Overrides

  override AshAuthentication.Phoenix.Components.Banner do
    set :root_class, "flex flex-col items-center justify-center py-6"
    set :image_url, "/images/logo.svg"
    set :dark_image_url, nil
    set :image_class, "w-16 h-16"
    set :href_url, nil
    set :text, "Check.Day"
    set :text_class, "text-2xl font-bold text-gray-900 dark:text-white tracking-tight mt-3"
  end
end
