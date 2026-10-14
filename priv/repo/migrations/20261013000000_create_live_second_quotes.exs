defmodule TradingMicro.Repo.Migrations.CreateLiveSecondQuotes do
  use Ecto.Migration

  # One row per symbol per UTC second, same shape as trading_backtest's
  # historical `second_quotes` so live and history compare directly. See
  # TradingMicro.Quotes.SecondQuote for what each column means.
  def change do
    create table(:live_second_quotes, primary_key: false) do
      add :symbol, :string, primary_key: true, null: false
      add :ts, :utc_datetime, primary_key: true, null: false

      add :bid, :decimal
      add :ask, :decimal
      add :bid_size, :decimal
      add :ask_size, :decimal
      add :mid, :decimal
      add :quote_updates, :integer, null: false, default: 0
      add :ofi, :decimal

      add :buy_volume, :decimal, null: false, default: 0
      add :sell_volume, :decimal, null: false, default: 0
      add :unknown_volume, :decimal, null: false, default: 0
      add :trade_count, :integer, null: false, default: 0

      add :rth, :boolean, null: false, default: false
    end

    # The PK (symbol, ts) already serves per-symbol time-range reads; this
    # covers the cross-symbol "last minute" health query.
    create index(:live_second_quotes, [:ts])
  end
end
