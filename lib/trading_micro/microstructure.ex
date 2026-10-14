defmodule TradingMicro.Microstructure do
  @moduledoc """
  The two per-event microstructure rules the recorder applies: one quote
  update's order-flow imbalance, and one trade's side.

  Both mirror `TradingCore.Signal.Compute`'s `:ofi` and `:signed_volume`
  (`"classifier" => "lee_ready"`) kinds exactly, so a number recorded here
  agrees with the same feature computed live elsewhere in the workspace.
  Compute keeps these as private steps inside a rolling window, so they
  are restated here per event; `test/trading_micro/microstructure_test.exs`
  folds the same ticks through Compute and asserts the totals match, which
  turns any drift between the two into a failing test.

  One deliberate difference: Compute treats a `nil` quote size as 0. Here
  a `nil` size makes the update unscorable (`nil`), because the recorder's
  contract is that `nil` means unknown, not zero, and a fabricated 0 would
  read as a real pull of the whole level.

  ## OFI sign

  Positive is buying pressure, per Cont, Kukanov and Stoikov (2014):

      e = 1[b >= b'] * qb  - 1[b <= b'] * qb'
        - 1[a <= a'] * qa  + 1[a >= a'] * qa'

  where primes are the previous quote.

  ## Trade side

  Lee–Ready: above the prevailing mid is a buy, below is a sell. At the mid,
  or with no usable quote (missing side, or a locked or crossed book), the
  tick rule decides: up from the previous trade is a buy, down is a sell,
  unchanged inherits the previous trade's side. With no quote and no
  earlier trade the side is `:unknown`.
  """

  @type quote_t :: %{
          bid: Decimal.t() | nil,
          ask: Decimal.t() | nil,
          bid_size: Decimal.t() | nil,
          ask_size: Decimal.t() | nil
        }

  @type side :: :buy | :sell | :unknown

  @doc """
  OFI contribution of moving from `prev` to `curr`, in the feed's size
  units. `nil` when either quote lacks a price or a size.
  """
  @spec ofi_contribution(quote_t() | nil, quote_t()) :: Decimal.t() | nil
  def ofi_contribution(nil, _curr), do: nil

  def ofi_contribution(prev, curr) do
    if complete?(prev) and complete?(curr) do
      Decimal.add(
        bid_contribution(prev.bid, prev.bid_size, curr.bid, curr.bid_size),
        ask_contribution(prev.ask, prev.ask_size, curr.ask, curr.ask_size)
      )
    end
  end

  defp complete?(%{bid: b, ask: a, bid_size: bs, ask_size: as}),
    do: not (is_nil(b) or is_nil(a) or is_nil(bs) or is_nil(as))

  defp complete?(_), do: false

  defp bid_contribution(prev_price, prev_size, curr_price, curr_size) do
    case Decimal.compare(curr_price, prev_price) do
      :gt -> curr_size
      :eq -> Decimal.sub(curr_size, prev_size)
      :lt -> Decimal.negate(prev_size)
    end
  end

  defp ask_contribution(prev_price, prev_size, curr_price, curr_size) do
    case Decimal.compare(curr_price, prev_price) do
      :lt -> Decimal.negate(curr_size)
      :eq -> Decimal.sub(prev_size, curr_size)
      :gt -> prev_size
    end
  end

  @doc """
  The side of a trade at `price`, given the prevailing quote (or `nil`)
  and the previous trade's price and side (each `nil` if none).
  """
  @spec trade_side(Decimal.t(), quote_t() | nil, Decimal.t() | nil, side() | nil) :: side()
  def trade_side(price, quote, last_price, last_side) do
    case mid(quote) do
      nil ->
        tick_rule(price, last_price, last_side)

      mid ->
        case Decimal.compare(price, mid) do
          :gt -> :buy
          :lt -> :sell
          :eq -> tick_rule(price, last_price, last_side)
        end
    end
  end

  defp tick_rule(_price, nil, _last_side), do: :unknown

  defp tick_rule(price, last_price, last_side) do
    case Decimal.compare(price, last_price) do
      :gt -> :buy
      :lt -> :sell
      :eq -> last_side || :unknown
    end
  end

  @doc """
  Midpoint of a usable quote: both sides present and `ask > bid`. `nil`
  for a missing side or a locked or crossed book.
  """
  @spec mid(quote_t() | nil) :: Decimal.t() | nil
  def mid(%{bid: %Decimal{} = bid, ask: %Decimal{} = ask}) do
    if Decimal.compare(ask, bid) == :gt do
      bid |> Decimal.add(ask) |> Decimal.div(2)
    end
  end

  def mid(_), do: nil

  @doc "Midpoint whenever both sides are present, even locked or crossed."
  @spec raw_mid(Decimal.t() | nil, Decimal.t() | nil) :: Decimal.t() | nil
  def raw_mid(%Decimal{} = bid, %Decimal{} = ask), do: bid |> Decimal.add(ask) |> Decimal.div(2)
  def raw_mid(_bid, _ask), do: nil
end
