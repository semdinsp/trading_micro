# Findings and recommendations

*From trading_micro's recorded sessions (2026-10-14 onward) and the 24 sessions of history in `trading_backtest.second_quotes` (SPY and QQQ, 2026-09-08 to 2026-10-09).*

**Summary:** SPY and QQQ seconds show **no direction edge after costs**, including path-signature (Lévy area) features and in both calm and normal volatility, but they do forecast **how big the next move will be**. Testing that on the strategies already running pointed to one gate: **no new entries before 10:00 ET**. It is now being paper A/B tested in `trading_system`. Don't build anything from it in `trading_live` until that test passes.

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
| **Path signatures (Lévy area)** of OFI→mid, net volume→mid and QQQ→SPY over 30 s / 1 m / 5 m (`mix micro.signature`) | Nothing over 26 sessions. The one live hit didn't hold up in history (below) |

**Recommendation:** don't build a strategy from these signals' direction alone in `trading_live` or `trading_system`. The only thing worth a second look is QQQ with OFI above 1σ and a 30 m hold (+1.62 bps, p = 0.03, n = 161), and only after a longer backfill.

### Path signatures: a two-day hit that didn't replicate

The Lévy area of two series over a window measures which one moved first. For example, when OFI moves and then the mid follows, the area is positive. `mix micro.signature` samples it every 10 s and scores it against the 10 s / 1 m / 5 m forward return. It uses a time-rotation placebo, because overlapping samples make a plain shuffle look far more significant than it is.

| QQQ OFI→mid, 5 m window | ρ vs next 1 m | Placebo p | Top − bottom decile, 1 m |
|---|---|---|---|
| Live, 2026-10-14 and 10-15 | 0.097 | 0.005 | +1.41 bps |
| History, 24 sessions 2026-09-08 to 10-09 | −0.009 | 0.33 | −0.26 bps |

- **The live result was most likely chance.** Two days had 5 of 36 cells at p < 0.05, against about 2 expected. In history, every one of the 18 cells has |ρ| ≤ 0.024. The history's OFI was checked against the live data and matches: 52% vs 54% of QQQ seconds positive, similar magnitudes.
- **trading_signal has three research rows** (`massive_qqq_ofi_mid_levy_300s` / `_60s`, `massive_spy_ofi_mid_levy_300s`, live since 2026-10-16, notes say "do not trade"). They are cheap to keep as a live record; retire them if nothing shows up in about two weeks.
- **The recorder now also records IWM and XLE** (PR #10, from 2026-10-15 evening), as controls: a second broad index and a thinner sector name.

**Recommendation:** don't build on the Lévy-area features. Keep running `mix micro.signature` on the live data over time; treat any new hit as needing the 24-session history to agree before it goes to `trading_backtest`.

### What a signature result has to clear

`mix micro.signature` prints each symbol's cost per round trip and the bar its top-minus-bottom decile gap (D10−D1) must clear. It marks any result that clears it with `*`. A taker round trip pays the full spread, plus `TradingCore.CostModel.order_commission/4` on the buy and the sell, which includes IBKR's regulatory fees. Long the top decile and short the bottom, each trade earns about half of D10−D1, so the bar is two round trips. With a $100k order and 2026-10-14..16 prices and spreads:

| | Spread | Commission + fees | Round trip | D10−D1 bar |
|---|---|---|---|---|
| SPY | 0.26 bps | 0.41 bps | 0.67 bps | 1.34 bps |
| QQQ | 0.28 | 0.41 | 0.69 | 1.37 |
| IWM | 0.37 | 0.58 | 0.95 | 1.90 |
| XLE (2026-10-16) | 1.48 | 1.71 | 3.19 | 6.38 |

Market impact and missed fills are not included. Before PR #12 the report said "beat about one spread", which was too lenient: the two-day QQQ result's 1.41 bps only just clears its 1.37 bps bar.

### Split by market regime: no difference

`trading_signal`'s `regime_sessions` labels each session by VIX band and SPY trend. The 26 sessions split 13 calm / 13 normal vol, and 11 up / 11 down / 4 chop trend. The market moved from calm to normal on 2026-10-14, so both live days fall in normal vol. That raised the question of whether the effect only appears in normal-vol markets.

- **It doesn't.** Across all 13 normal-vol sessions, QQQ OFI→mid 5 m has ρ 0.005 (p 0.76). Calm-vol sessions and the up / down / chop splits show nothing either.
- **The only small regularity:** in normal vol, QQQ net volume→mid predicts the next 5 m with ρ ≈ 0.03 (p 0.005–0.015). Its decile gap is 0.1–0.33 bps, far below QQQ's cost bar of about 1.37 bps (see below), so it can't pay. It's one of about 90 cells tested, so it's likely chance.
- **Regime transitions:** `trading_signal` now stores every intraday label change (`regime_transitions`, from 2026-10-15). That allows a by-regime split within a day once some history builds up.

The split was a one-off read-only script over `trading_backtest.second_quotes`, `live_second_quotes` and `trading_signal`'s `regime_sessions`, reusing `TradingMicro.SignatureStudy`.

### Opening 30 minutes vs the rest of the day: one VIX lead-lag lead, not yet robust

`mix micro.open30` computes Lévy areas over 09:30–10:00 ET from Polygon 1-minute bars (2024-01-02 to 2026-10-16: 695 full sessions, 6 half days dropped, 674 with VIX). It asks whether they predict `log(P_close / P_10:00)` (rest of day) or `log(P_close / P_15:30)` (last 30 m) beyond the opening return `r30`. The test is a logistic regression `up ~ r30 + area`, fit on the first 70% of sessions, with AUC measured on the last 30%. The placebo shifts the area series circularly by 5–50 sessions. NYSE TICK isn't on Polygon, so the (SPY, TICK) pair wasn't run.

| Area over 09:30–10:00 | Result |
|---|---|
| A1 (time, log price) | Nothing: \|ρ\| ≤ 0.07, no out-of-sample AUC lift |
| A2 (QQQ, SPY) | Nothing: \|ρ\| ≤ 0.02, lift negative |
| A3 (log price, cumulative volume) | Nothing: \|ρ\| ≤ 0.07, lift not distinguishable from placebo |
| **A4 (SPY, VIX), vs last 30 m** | ρ −0.14 (SPY and QQQ), placebo p 0.021 (the smallest possible). Out-of-sample AUC lift +0.036 SPY (p 0.043), +0.079 QQQ (p 0.021). Top − bottom decile −8.7 / −11.7 bps |

- **Multiple testing:** 16 main cells, about 0.8 chance hits per test. Observed: 2 for ρ and 2 for AUC lift, all A4 vs last 30 m. The SPY and QQQ targets move together, so that's closer to one finding than two. Of the regime cells, 64 had a p, with about 3.2 expected by chance; 7 hit, 6 of them the same A4 last-30-m result in calm, normal and up-trend sessions (regime taken from the previous session's `regime_sessions` label).
- **Not robust to the split:** with training shares of 0.5 / 0.6 / 0.7 / 0.8, A4's last-30-m lift stays positive (+0.04 to +0.08), but its placebo p moves between 0.02 and 0.17. The cells that pass change with the split. `r30` alone has an out-of-sample AUC of only 0.46–0.55.
- **Sign:** the area is negative-associated. When SPY leads VIX in the opening half hour (as the area measures it), the last 30 minutes tend to fall.

**Recommendation:** don't build anything from it yet; no strategy or signal definition was created. The next check, before any `trading_backtest` handoff, is whether A4 adds anything beyond the opening VIX change (ΔVIX 09:30–10:00) and `r30` together, and whether it holds on 2022–2023 bars. A1–A3 can be dropped.

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

**Recommendation, running since 2026-10-14:** a paper A/B test in `trading_system` (PR #460). The prompt is in `handoff_prompts/2026-10-14-trading_system-open30-ab-test.md`.

- **Strategies tested:** 173 discovery and quarantine versions with at least 30 closed trades, positive expectancy R, a close in the last 8 days, and not paused. They were split with seed `20261014`, balanced across signal family × direction (16 groups).
- **Treatment (87):** `entry_delay_minutes: 30`, an existing setting, so no new code.
  - 24 discovery versions were forked, and each is compared with its unchanged parent.
  - 63 quarantine versions were each copied twice into discovery (delay 30 vs unchanged), so both arms share a stage and sizing.
  - That makes 150 new versions, all created with no errors.
- **Secondary control:** the 86 unforked versions.
- **Tags:** `ab:open30 2026-10-14`, plus `ab-open30-treatment` / `-control` / `-unforked` / `-source`.
- **Report:** `cd trading_system && mix trading_system.ab_open30 [--pairs] [--since DATE]`. It runs daily in `CLAUDEDAILY.md`'s market-close routine and shows the paired ΔR (sign test and bootstrap), each arm's stats, the before/after 10:00 split and a permutation test against the unforked half.
- **When to read it:** first data after the 2026-10-15 session. Don't decide before 10 sessions (about 2026-10-28); 20 sessions (about 2026-11-11) is better.
- **Reading it:**
  - **Controls keep their own delay:** most are 3 minutes, some 15. In a 15-minute pair the only difference is entries from 09:45 to 10:00, so split the result by the control's delay rather than letting those pairs dilute it.
  - **If the paired result holds on paper,** the gated versions reach `trading_live` through the normal promotion, which needs no `trading_live` code. Live data hasn't confirmed the effect yet, so promotion is the user's call.

## 5. Something outside this research to look at

The paper strategies lost money overall over the sample: **−8.7M net** across 333,657 closed runs. That's why skipping almost any group of trades looks good, and why every gate above was compared with a random skip rather than with zero. It probably matters more than any gate.

## Where things are

| Item | Status |
|---|---|
| trading_micro recorder | Running on port 4020, recording SPY, QQQ, IWM and XLE; PRs #1–#10 merged |
| Path-signature study | `mix micro.signature [FROM] [TO]`; nothing over 26 sessions |
| Opening-30-minute Lévy-area study | `mix micro.open30 [FROM TO] [--train 0.7]`; only A4 (SPY, VIX) vs the last 30 m shows anything, not robust to the split |
| `trading_signal` Lévy-area research rows | Live from 2026-10-16, do not trade; review around 2026-10-30 |
| `trading_backtest` Donchian + OFI study | PR #58, merged; `mix trading_backtest.donchian_ofi` |
| `trading_backtest` volatility-gate study | PR #59, merged; `mix trading_backtest.vol_gate` |
| `trading_system` 10:00 ET A/B test | Running since 2026-10-14 (PR #460, 87 pairs); review around 2026-10-28 / 2026-11-11 |
| `trading_hub` port registration | PR #150, merged |
| Re-check on the recorder's own data | After 4–6 weeks of `live_second_quotes` |

**Caveat:** the history is 24 sessions from September–October 2026. By `trading_signal`'s labels it covers both calm and normal volatility, but no high-volatility (stressed) session.
