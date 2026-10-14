# trading_backtest: test a 20m Donchian breakout with an OFI entry filter on second_quotes

**From:** trading_micro, 2026-10-14. A research backtest. Nothing in it trades, and no other app changes.

## Why

`trading_micro` now records live SPY/QQQ seconds (`trading_micro_dev.live_second_quotes`) in the same shape as this app's historical `second_quotes`. The question is whether order-flow imbalance (OFI) makes a Donchian channel breakout a better entry. Both signals already run live in `trading_signal`: `massive_spy_spy_donchian` / `massive_qqq_qqq_donchain` (kind `donchian`, window 20m) and `massive_spy_spy_ofi` / `massive_qqq_qqq_ofi` (kind `ofi`, window 1m). If the filter holds up on history, the rule will be built in `trading_live` or `trading_system` from those signals. This backtest decides whether that's worth doing.

The one-day check on trading_micro's 2026-10-14 recording means nothing yet. Each symbol had about 24 breakouts, and the filter pointed opposite ways:

| 15 min after breakout | OFI agrees | OFI disagrees |
|---|---|---|
| QQQ | 13 trades, +5.6 bps, 62% win | 10 trades, −0.7 bps, 50% |
| SPY | 13 trades, −2.1 bps, 38% win | 11 trades, +3.8 bps, 73% |

`second_quotes` already holds SPY and QQQ for 24 sessions (2026-09-08 to 2026-10-09). Use those, and backfill further with `IngestSecondQuotes` if you want more history.

## What to build

A read-only study over `second_quotes`. A mix task fits, e.g. `mix backtest.donchian_ofi --symbols SPY,QQQ --from 2026-09-08 --to 2026-10-09`, with the core logic in a pure module that has tests.

**Inputs per second (RTH only, 09:30–16:00 ET):** `mid`, `ofi`, `buy_volume - sell_volume`. `second_quotes` has no `rth` column, so get the session from `TradingCore.Intraday.RegularSession`, which handles holidays and half days. Use only rows with a non-null `mid` for the price path.

**Signals:** use `trading_core` where it can be done, so the numbers match the live `trading_signal` values.
- **Donchian, 20m:** the same rule as `TradingCore.Signals.donchian/4` / `Compute` kind `:donchian`. The value is +1 when the latest mid is at or above the window high, −1 when it is at or below the window low, and 0 otherwise. Skip the first 20 minutes of each session (warm-up), and never let the window reach back into the previous day.
- **OFI, 1m:** the sum of `ofi` over the trailing 60 seconds, current second included.

**Entry:** a breakout is the first second the Donchian value goes from 0 to ±1. Ignore a repeat in the same direction within 5 minutes. Compare three variants:
1. Every breakout (baseline).
2. Breakouts where the 1m OFI has the same sign as the breakout.
3. Breakouts where the 1m OFI has the same sign and `|OFI| > k × the session's rolling σ of 1m OFI`, for k in {0.5, 1, 2}.

**Exits:** report each separately:
- a fixed hold of 5, 15 and 30 minutes;
- a cross back through the channel midline;
- the opposite breakout;
- the 1m OFI turning against the position for N consecutive seconds (N in {10, 30});
- the session close in every case (no overnight positions).

**Costs:** enter and exit at the touch (buy at the ask, sell at the bid) rather than the mid, and also report the mid-to-mid result. SPY's median RTH spread is about 0.13 bps and QQQ's about 0.27, so costs matter at this scale.

**Report per symbol and variant:** trade count, average and median return in bps, win rate, total bps, and a by-day breakdown, so one day can't carry the result. Add a simple placebo: the same entry rule with the OFI sign shuffled across breakouts within each day (e.g. 200 shuffles). Show where the actual filter result falls in that distribution. A filter whose lift is inside the shuffle spread is noise.

## Things to know about the data

- **OFI sign:** positive is buying pressure. `trading_micro` and this app's `SecondQuoteAggregator` use the same Cont–Kukanov–Stoikov formula.
- **Sizes:** trading_micro's live data suggests Polygon sizes are shares (the smallest SPY/QQQ bid size is 40, the round lot for that price band; about 55–63 shares per trade).
- **Small differences between the two tables.** In this app `ofi` is `bigint not null` (0 when no update could be scored), while trading_micro stores `nil`. trading_micro also resets the previous quote after a 5s break in SIP time, and this app does not. Neither should matter at a 1m window, but don't treat `ofi == 0` as "no data".
- **Live gaps:** live seconds have brief gaps on the feed side (5–23 s, both symbols at once). History from flat files shouldn't have them, but skip seconds with no mid rather than forward-filling into a breakout.

## Out of scope

- No changes to `trading_signal`, `trading_live`, `trading_system` or `trading_micro`.
- No order placement and no new PubSub topics.
- Reading `trading_micro_dev.live_second_quotes` to extend the sample past 2026-10-09 is welcome, but read-only. Don't write to another app's database.

Please send back a short summary of the result table, and say plainly whether the OFI filter beats the shuffle placebo for either symbol after costs.
