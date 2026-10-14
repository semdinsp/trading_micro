defmodule TradingMicro.Microstructure do
  @moduledoc """
  The recorder's per-event microstructure rules: one quote update's
  order-flow imbalance, and one trade's side.

  The rules themselves live in `TradingCore.Microstructure`, the same
  functions `TradingCore.Signal.Compute`'s `:ofi` and `:signed_volume`
  kinds call, so a number recorded here agrees with that feature computed
  anywhere else in the workspace. This module only pins the recorder's two
  stricter options and maps the trade sign to a side atom:

    * `nil_size: :skip`: a `nil` quote size makes the update unscorable
      (`nil`) rather than counting as 0. The hub's contract is that `nil`
      means unknown, and a fabricated 0 would read as a pull of the whole
      level.
    * `empty_side: :skip`: a zero bid or ask is Polygon's empty side, not a
      price. Such a quote gives no OFI and no mid to sign a trade against.

  Compute keeps its defaults (`:zero`, `:price`), so live signal values are
  unchanged.

  ## OFI sign

  Positive is buying pressure, per Cont, Kukanov and Stoikov (2014):

      e = 1[b >= b'] * qb  - 1[b <= b'] * qb'
        - 1[a <= a'] * qa  + 1[a >= a'] * qa'

  where primes are the previous quote.

  ## Trade side

  Lee–Ready: above the prevailing mid is a buy, below is a sell. At the mid,
  or with no usable quote (missing or empty side, or a locked or crossed
  book), the tick rule decides, and an unchanged price inherits the previous
  trade's side. With nothing to sign against the side is `:unknown`.
  """

  alias TradingCore.Microstructure, as: Core

  @ofi_opts [nil_size: :skip, empty_side: :skip]
  @sign_opts [empty_side: :skip]

  @type quote_t :: %{
          bid: Decimal.t() | nil,
          ask: Decimal.t() | nil,
          bid_size: Decimal.t() | nil,
          ask_size: Decimal.t() | nil
        }

  @type side :: :buy | :sell | :unknown

  @doc """
  OFI contribution of moving from `prev` to `curr`, in the feed's size
  units. `nil` when either quote is missing, has a missing or empty side,
  or has a `nil` size.
  """
  @spec ofi_contribution(quote_t() | nil, quote_t()) :: Decimal.t() | nil
  def ofi_contribution(nil, _curr), do: nil
  def ofi_contribution(prev, curr), do: Core.ofi_contribution(prev, curr, @ofi_opts)

  @doc """
  The side of a trade at `price`, given the prevailing quote (or `nil`)
  and the previous trade's price and side (each `nil` if none).
  """
  @spec trade_side(Decimal.t(), quote_t() | nil, Decimal.t() | nil, side() | nil) :: side()
  def trade_side(price, quote, last_price, last_side) do
    case Core.trade_sign(price, quote, last_price, to_sign(last_side), @sign_opts) do
      1 -> :buy
      -1 -> :sell
      nil -> :unknown
    end
  end

  defp to_sign(:buy), do: 1
  defp to_sign(:sell), do: -1
  defp to_sign(_), do: nil

  @doc """
  The stored `mid`: `(bid + ask) / 2` whenever both sides are positive,
  locked or crossed books included. Unlike the mid that signs trades, it
  describes the quote as received rather than judging whether it is usable.
  """
  @spec raw_mid(Decimal.t() | nil, Decimal.t() | nil) :: Decimal.t() | nil
  def raw_mid(bid, ask) do
    if positive?(bid) and positive?(ask), do: bid |> Decimal.add(ask) |> Decimal.div(2)
  end

  defp positive?(%Decimal{} = d), do: Decimal.compare(d, 0) == :gt
  defp positive?(_), do: false
end
