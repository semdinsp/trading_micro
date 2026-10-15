# Findings and recommendations

*From trading_micro's first recorded session (2026-10-14) and the 24 sessions of history in `trading_backtest.second_quotes` (SPY and QQQ, 2026-09-08 to 2026-10-09).*

**Summary:** SPY and QQQ seconds show **no direction edge after costs**, but they do forecast **how big the next move will be**. Testing that on the strategies already running pointed to one gate: **no new entries before 10:00 ET**. It is now being paper A/B tested in `trading_system`. Don't build anything from it in `trading_live` until that test passes.

## 1. Recorder: works and should keep running

The first full session, 2026-10-14 (`mix micro.report 2026-10-14`):

| | SPY | QQQ |
|---|---|---|
| Rows, 04:00–20:00 ET | 40,176 | 43,294 |
| Seconds with quotes, 09:30–16:00 ET | 99.61% | 99.55% |
| Median spread, 09:30–16:00 ET | 0.13 bps | 0.27 bps |
| Largest gap, 09:30–16:00 ET | 17 s at 10:37:12 | 23 s at 09:30:02 |
| Volume that couldn't be signed buy/sell | 0% | 0% |

- **The gaps come from the feed, not the recorder.** Both symbols went quiet at the same moments, all for less than 60 s. The hub dropped once, at 09:10 ET pre-market, and the recorder reconnected on its own.
- **Polygon sizes appear to be shares, not round lots.** The smallest bid size is 40, which is the round lot for this price band, and trades average 54–63 shares.
- **The log was mostly per-query debug lines (about 50 MB a session).** PR #5 turned those off, along with colour codes in the file.

**Recommendation:** run it continuously. Recording starts and stops on its own, from 04:00 to 20:00 ET. After 4–6 weeks, `live_second_quotes` gives a fresh sample for re-checking anything adopted from this research.

## 2. Direction at seconds-to-minutes: no edge

Every check was measured against the bid/ask cost (an average SPY spread of about 0.24 bps, QQQ about 0.30):

| Idea | Result |
|---|---|
| OFI predicts the next 10 s / 1 m / 5 m | corr ≈ 0.00; the extreme buckets are noisy (±1 bps, small n) |
| Signed volume predicts the next 1 m | corr ≈ 0.01 |
| Momentum, or reversal after a > 2σ 5 m move | continues 46–48% of the time, −0.1 to −0.2 bps |
| SPY↔QQQ lead-lag at 1 s | corr 0.03–0.04, far below the spread |
| QQQ/SPY 5 s divergence closes | about 0.03 bps, against about 0.5 bps to trade both legs |
| **20 m Donchian breakout + 1 m OFI filter** (`trading_backtest` PR #58) | Doesn't beat a shuffled-OFI placebo after costs for either symbol. The baseline breakout loses money, and the best cells rest on 22–44 trades carried by one day |

**Recommendation:** don't build a strategy from these signals' direction alone in `trading_live` or `trading_system`. The only thing worth a second look is QQQ with OFI above 1σ and a 30 m hold (+1.62 bps, p = 0.03, n = 161), and only after a longer backfill.

## 3. Volatility: strong forecasts, but not a useful gate

- **The size of the next move is predictable.** A burst of quote activity (top 5% of the last 60 s) doubles the next 5 m move: SPY 7.9 vs 3.5 bps, QQQ 10.0 vs 5.0. The 09:30–10:00 period moves about twice as much as early afternoon.
- **No new signal is needed.** The existing `two_scale_rv` (5m) forecasts this as well as quote-update rate or better: Spearman 0.84–0.87 vs 0.82–0.84 against the next 5 m realized variance. A new quote-rate signal kind isn't justified.
- **Skipping entries when volatility is high doesn't help** (`trading_backtest` PR #59, 302,707 closed `strategy_runs` across 1,876 versions). The apparent harm is the market open overlapping with high volatility. Within the same day and version, high-volatility trades are slightly *better*, and after 10:00 skipping them is worse than skipping at random.

**Recommendation:** don't add a SPY/QQQ volatility gate. "Widen stops when busy" could be a separate test: after 10:00, entries during high volatility stop out more often (11–15% vs 6%) but still finish with a better mean R.

## 4. No new entries before 10:00 ET: the one gate that held up

This is from the same study (PR #59):

| | Before 10:00 ET | Rest of day |
|---|---|---|
| Mean R | −0.079 | −0.033 |
| Stop-out rate | 29% | 6% |

- **Effect size:** version-weighted mean ΔR −0.056 (median −0.026). Skipping helps 58% of 1,448 versions and 16 of 21 days, and beats both placebos with p = 0.000.
- **P&L:** skipping adds +2.82M paper P&L, against +1.80M for a random skip of the same 20.6% of trades. Half size adds +1.41M.
- **Live data doesn't confirm it yet:** 1,483 live trades give ΔR +0.032, p = 0.31.

**Recommendation, in progress:** run a paper A/B test in `trading_system`.

1. Rank the top strategies and randomly fork 50% of them with `entry_delay_minutes: 30`, an existing setting that needs no new code.
2. Compare each fork with its unchanged parent.
3. Run for 10–20 sessions.

The prompt is in `handoff_prompts/2026-10-14-trading_system-open30-ab-test.md` and was sent to `trading-system-71`. If the paired result holds, the gated versions reach `trading_live` through the normal promotion, which needs no `trading_live` code.

## 5. Something outside this research to look at

The paper strategies lost money overall over the sample: **−8.7M net** across 333,657 closed runs. That's why skipping almost any group of trades looks good, and why every gate above was compared with a random skip rather than with zero. It probably matters more than any gate.

## Where things are

| Item | Status |
|---|---|
| trading_micro recorder | Running on port 4020; PRs #1–#6 merged |
| `trading_backtest` Donchian + OFI study | PR #58, merged; `mix trading_backtest.donchian_ofi` |
| `trading_backtest` volatility-gate study | PR #59, merged; `mix trading_backtest.vol_gate` |
| `trading_system` 10:00 ET A/B test | Prompt sent 2026-10-14 |
| `trading_hub` port registration | PR #150, merged |
| Re-check on the recorder's own data | After 4–6 weeks of `live_second_quotes` |

**Caveat:** all of the history is 24 sessions from September–October 2026, so a single market regime.
