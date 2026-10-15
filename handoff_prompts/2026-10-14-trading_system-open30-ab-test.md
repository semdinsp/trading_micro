# trading_system: A/B test "no new entries before 10:00 ET" on forks of the top strategies

**From:** trading_micro, 2026-10-14, at the user's request. This is a paper A/B test only: no live promotion, and no change to `trading_live`.

## Why

`trading_backtest` PR #59 (`mix trading_backtest.vol_gate`) replayed this app's closed `strategy_runs` from 2026-09-08 to 2026-10-09: 302,707 runs across 1,876 versions, excluding `invalid_session` and `is_churn`. Of every gate it tried, the only one that beat both placebos was **no new entries in the first 30 minutes (09:30–10:00 ET)**:

- **Entries before 10:00 vs after:** R −0.079 vs −0.033. The version-weighted mean ΔR is −0.056 (median −0.026).
- **Breadth:** skipping them helps 58% of 1,448 versions and 16 of 21 days, with placebo p = 0.000 within day×version and within version.
- **P&L:** skipping them adds +2.82M net, against about +1.80M for skipping a random 20.6% of trades. Half size adds +1.41M.
- **Stops:** stop-out rate is 29% before 10:00 vs 6% after.
- **Live check:** on 1,483 trades, `trading_live` does **not** confirm it yet (ΔR +0.032, p = 0.31). That's why this is a paper A/B test rather than a rollout.
- **Volatility gates:** gating on SPY/QQQ realized volatility or quote rate did **not** beat the placebo once the open was accounted for. Don't add one.

## What to do

1. **Pick the top strategies.** Use your own ranking, e.g. rating or recent net R / expectancy over a meaningful number of closed runs, among discovery and quarantine versions that are trading. Aim for a large set, at least 100 if that many qualify, because the expected effect is small (about 0.03–0.06 R per trade). Note the criteria you used.
2. **Randomly assign 50% of them to treatment.** Use a seeded random split, and record the seed and both lists. Stratify by `primary_signal_family` and direction if practical. Don't hand-pick.
3. **Fork each treatment version** with everything identical (rules, params, target pool, sizing, `usage_conditions`, `time_box_exit_et`, `close_after_hours`) **except `entry_delay_minutes: 30`**. The existing setting already means "no new entry until N minutes after the target exchange session's real open; exits never delayed", so no new code should be needed. Use `fork_strategy_version/2` (or the fork API). Quarantine and test_portfolio versions refuse forks with `{:error, :quarantined}`, so for those use `duplicate_quarantine_version_to_discovery/2`, or leave them out and say so.
4. **Controls:**
   - **Primary, paired:** each treatment fork against its own unchanged parent. Same signals, targets and days; only the 30-minute delay differs. Parents keep running as they are, with their default delay of 3 minutes.
   - **Secondary:** the 50% of top strategies that weren't forked.
   - A fork may land in a different `lifecycle_stage` or `deploy_batch` than its parent. If that changes how it trades (gating, quarantine counting, sizing), make the control the same, or report the difference.
5. **Tag every fork and its parent** so the test can be found and torn down together, e.g. `fork_directive`/notes `"ab:open30 2026-10-14"`, or a tag if you have one. Don't use `marked_for_fork` for anything else in this test.
6. **Report:** add a simple query, mix task or report (whatever fits this app) that prints for each pair and pooled:
   - closed runs, mean/median R, net P&L per run, win rate and stop-out share;
   - paired ΔR (fork − parent) with a version-weighted mean, the share of pairs where the fork is better, and a sign test or paired bootstrap p-value;
   - the same split by entry time, as a check: the parent's trades before 10:00 should be the only ones the fork skips;
   - the secondary comparison against the un-forked 50%.

## How long to run it

Run it for at least 10 sessions, and preferably 20, before calling it. Nothing should be promoted to `trading_live` from this test until the paired result holds on paper and the user decides.

## Expected and acceptable side effects

- Forks take fewer trades (about 20% fewer) and miss any good opening trades. That's the point of the test.
- If forks increase load or paper capacity in a way that matters, say so before creating them.

## Out of scope

- No changes to `trading_live`, `trading_signal`, `trading_core`, `trading_backtest` or `trading_micro`.
- No promotion of forks.
- No change to any existing version's `entry_delay_minutes`.

Follow this repo's branch, test and PR rules, and don't merge without the user's go-ahead. Creating forks in the dev database is a live data change, so confirm with the user before running it if your session's rules require that. Please report back with the number of pairs created, the selection criteria, the seed, and how to run the report.
