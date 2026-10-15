# trading_backtest: does a SPY/QQQ short-term volatility gate improve existing strategies' trades?

**From:** trading_micro, 2026-10-14. A research study that only reads data. Nothing trades, and no other app changes. It follows the Donchian + OFI study (`claude/donchian-ofi-study`), which found no directional edge.

## Why

Over the 24 sessions in `second_quotes` (SPY/QQQ, 2026-09-08 to 2026-10-09), second-level data showed **no direction edge after costs**. OFI, signed volume, momentum, reversal, SPY↔QQQ lead-lag and QQQ/SPY divergence all had |corr| ≤ 0.04 with the next 10s to 5m. It does forecast **how big the next move will be**:

- **Quote-activity burst:** when the last 60s of `quote_updates` is in the top 5%, the next 5m move is about 2× larger (SPY 7.9 vs 3.5 bps average |5m move|; QQQ 10.0 vs 5.0).
- **Time of day:** 09:30–10:00 ET moves about 2× more than 13:30–14:00 or 15:00–15:30 (SPY 5.4 vs about 2.7 bps over 5m).

The idea to test: in volatile market moments, gate new entries (skip them, or size them down) for the strategies already running in `trading_system` (paper) and `trading_live` (live). If it works, the gate goes into `trading_system` strategy versions first, gets paper-tested, and reaches `trading_live` through the normal promotion. This study decides whether that's worth doing, and which signal the gate should use.

## Part A: which signal forecasts volatility best

Using `second_quotes` RTH seconds (09:30–16:00 ET via `TradingCore.Intraday.RegularSession`), sample once a minute. Compare how well each candidate, measured over the trailing window, forecasts SPY's and QQQ's realized |move| and realized variance over the next 5, 15 and 30 minutes:

1. Quote updates per 60s (and 5m).
2. Trade count per 60s.
3. 5m realized volatility from second mids (as close as practical to `TradingCore.Signal.Compute` `:two_scale_rv`, window 5m, subsample_k 5).
4. Rolling 5m traded volume (like `:rolling_volume`).
5. 1m quoted spread (like `:quoted_spread`).
6. Time-of-day bucket alone, and each of 1–5 adjusted for time of day. The point is to learn whether the signal adds anything beyond "it's the open".

Report the rank correlation and top-decile vs median lift for each. **What matters:** `trading_signal` already publishes these for SPY/QQQ live: `massive_{spy,qqq}_{spy,qqq}_two_scale_rv` (5m), `..._rolling_volume_5m`, `..._quoted_spread` (1m), `..._kyle_s_lambda` (1m). It has **no** quote-update-rate signal. If quote rate clearly beats the existing signals, say so and say by how much, because it would need a new `trading_core` kind plus a `trading_signal` definition. If an existing signal is about as good, prefer it.

## Part B: does gating improve real strategy trades

Join the market's state at each trade's entry to these trade sets (read-only):

- **`trading_system_dev.strategy_runs`:** closed runs (`exit_at` not null) with `entry_at` in 2026-09-08 13:30Z to 2026-10-10, excluding `invalid_session` and `is_churn`. That's about 631k runs across about 1,876 strategy versions. It has `r_multiple`, `return_pct`, `realized_pnl_net`, `risk_at_entry`, `mae_r`/`mfe_r`, `exit_reason`/`exit_category`, `hold_time_seconds` and the regime columns. Get the symbol from the version/target if needed.
- **`trading_live_dev`:** live fills/orders over the same dates (about 3.9k fills, mostly INTC, AMD, NVDA, TSM, TQQQ, SPXL). It's a much smaller sample. Report it separately as a check on direction, not as evidence.

For each trade, compute the SPY (and QQQ) gate state at `entry_at` from `second_quotes`: the best Part A signal's percentile (by the day's or the trailing distribution, **not** using any future data), and whether entry was in 09:30–10:00. Then compare:

- **Skip gate:** trades entered when volatility is in the top 10% / top 5%, or in the first 30 minutes, against all other trades. Show the average and median `r_multiple`, average `return_pct`, net P&L per trade, win rate and count.
- **Size-down gate:** the total effect on net P&L if gated trades were taken at half size.
- **Stops:** whether stop-outs (`exit_reason`/`exit_category`) and adverse excursion (`mae_r`) are worse for entries during high volatility. This shows whether "widen stops when busy" is worth a later test.

Guard against a few versions or days carrying the result:

- Weight each strategy version equally, and also show the raw pooled result.
- Give per-day and per-version breakdowns, plus the share of versions where the gate helps.
- Run a placebo: shuffle the gate flag across trades within each day and version (≥ 200 shuffles) and give a p-value.
- Split by `regime_vol_state`, because the gate may only repeat what the regime label already captures.
- Split by asset type: SPY/QQQ-correlated names and leveraged ETFs vs everything else.

## What to send back

A short summary covering:

- **Part A:** which signal to use, and whether a new quote-rate signal is justified.
- **Part B:** whether skipping or sizing down beats the placebo across most versions, with the effect size in R and net P&L.
- **A concrete gate rule, if it holds up,** that can be expressed with existing `trading_signal` signals plus time of day. For example: "no new entries when `massive_spy_spy_two_scale_rv` > its trailing-20-day 90th percentile, or before 10:00 ET".

If the gate doesn't beat the placebo, say so plainly.

## Out of scope

- No changes to `trading_system`, `trading_live`, `trading_signal`, `trading_core` or `trading_micro`, and no writes to their databases.
- Implementation in those apps comes after this result, through separate prompts.
- Follow your repo's usual branch, test and PR rules, and don't merge without the user's go-ahead.
