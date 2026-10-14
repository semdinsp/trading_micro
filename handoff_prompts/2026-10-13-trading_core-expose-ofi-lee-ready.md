# trading_core: expose per-event OFI and Lee–Ready as public functions

**From:** trading_micro, 2026-10-13. Low priority. trading_micro already works without this.

## Why

`TradingCore.Signal.Compute` already implements the CKS OFI step (`ofi_contribution/2`, `bid_contribution/4`, `ask_contribution/4`) and the Lee–Ready trade sign (`trade_sign/4`). Both are private and sit inside the rolling-window `:ofi` / `:signed_volume` kinds.

trading_micro needs them **per event**, summed per second, so it restates them in `TradingMicro.Microstructure`. A parity test there folds the same ticks through `Compute` and asserts equal totals. trading_backtest's `second_quotes` ingest will need the same per-event rules. Three copies is how the pre-2026-09-25 inverted-ask OFI bug happened.

## What to add

A public, pure module, for example `TradingCore.Microstructure`:

```elixir
@spec ofi_contribution(prev_quote, curr_quote) :: Decimal.t()
# prev/curr: %{bid:, ask:, bid_size:, ask_size:} (Decimals)
# Positive = buy pressure. Same formula Compute uses today.

@spec trade_sign(price, quote | nil, last_price | nil, last_sign | nil) :: 1 | -1 | nil
# Lee–Ready: vs mid when ask > bid, tick rule at the mid / no usable quote,
# zero tick inherits last_sign, nil when nothing to sign against.
```

Then have `Compute`'s `:ofi` and `:signed_volume` call it, which changes no behaviour. Release it under a new version tag.

## One semantic point to decide

`Compute` treats a `nil` quote size as 0. trading_micro treats it as unknown and skips the update, because "nil is not zero" is the hub's contract. Either take an option, or return `nil` when a size is nil and let `Compute` keep its `|| 0` at the call site. Once this ships, trading_micro will switch to the shared functions and delete its own copy.
