defmodule TradingMicro.Repo do
  use Ecto.Repo,
    otp_app: :trading_micro,
    adapter: Ecto.Adapters.Postgres
end
