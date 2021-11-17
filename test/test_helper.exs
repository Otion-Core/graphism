ExUnit.start()

defmodule AllowEverything do
  def allow?(_, _), do: true
  def scope(q, _), do: q
end

defmodule TestRepo do
  use Ecto.Repo,
    otp_app: :graphism,
    adapter: Ecto.Adapters.Postgres
end
