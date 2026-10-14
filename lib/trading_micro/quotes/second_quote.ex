defmodule TradingMicro.Quotes.SecondQuote do
  @moduledoc """
  One symbol's top of book and trade flow for one UTC second.

  Rows exist only for seconds that had at least one quote or trade. A
  quiet second is a missing row, never a forward-filled copy of the one
  before it.

  ## Columns

    * `symbol`, `ts` — `ts` is the start of the second, UTC, taken from
      Polygon's SIP timestamp (`t`), not from when the message arrived.
    * `bid`, `ask`, `bid_size`, `ask_size` — the last quote received in the
      second. All `nil` when the second had trades but no quote: the
      prevailing quote is not copied forward. A size may be `nil` on its
      own when Polygon omitted it; `nil` means unknown, not zero. Sizes are
      stored exactly as Polygon sends them (see the README on units).
    * `mid` — `(bid + ask) / 2`, `nil` when either side is missing.
    * `quote_updates` — quote messages received in the second.
    * `ofi` — Cont–Kukanov–Stoikov order-flow imbalance summed over the
      second's quote updates. **Positive means buying pressure** (bid
      rising or growing, ask lifted or shrinking); negative means selling
      pressure. The first quote of a second is differenced against the
      last quote of the previous second, wherever that was. An update with
      any `nil` size contributes nothing; a second where no update could
      be scored has `ofi` `nil`, not 0. See `TradingMicro.Microstructure`.
    * `buy_volume`, `sell_volume`, `unknown_volume` — trade size signed by
      Lee–Ready against the quote prevailing when the trade arrived, with
      the tick rule at the mid. `unknown_volume` is size that could not be
      signed (no quote and no earlier trade). Only prints that count toward
      volume under Polygon's trade conditions are included.
    * `trade_count` — volume-eligible prints in the second, including any
      with no size.
    * `rth` — whether `ts` falls in the regular session (09:30–16:00 ET, or
      the early close on a half day).
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key false
  schema "live_second_quotes" do
    field :symbol, :string, primary_key: true
    field :ts, :utc_datetime, primary_key: true
    field :bid, :decimal
    field :ask, :decimal
    field :bid_size, :decimal
    field :ask_size, :decimal
    field :mid, :decimal
    field :quote_updates, :integer, default: 0
    field :ofi, :decimal
    field :buy_volume, :decimal, default: Decimal.new(0)
    field :sell_volume, :decimal, default: Decimal.new(0)
    field :unknown_volume, :decimal, default: Decimal.new(0)
    field :trade_count, :integer, default: 0
    field :rth, :boolean, default: false
  end
end
