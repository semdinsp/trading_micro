# trading_micro

Records SPY/QQQ top of book and trade flow from `trading_hub`'s Polygon
feed into Postgres, one row per symbol per UTC second
(`trading_micro_dev.live_second_quotes`). Phase 1 only records: no
prediction, no orders, and nothing is broadcast onto `TradingHub.PubSub`.

The table has the same shape as `trading_backtest`'s historical
`second_quotes`, so live and historical seconds compare directly. The
columns are documented in `TradingMicro.Quotes.SecondQuote`.

## Run

```bash
mix setup
elixir --name trading_micro@Scotts-Mac-mini.local -S mix phx.server
```

- Dashboard: http://localhost:4020/
- `GET /health`: always 200; `status` is `ok`, `degraded` or `disabled`, with per-symbol rows in the last minute, last message age, gap flag and hub subscription state.
- `GET /status`, `/status/metrics`: app_status, with the same recorder metrics as flat gauges.
- `mix micro.report [YYYY-MM-DD]`: the end-of-session report (rows, RTH quote coverage, median spread in bps, largest RTH gap). It is read-only and safe to run next to the server.

Port **4020** must also be registered in trading_hub's `cluster_app_ports`
(see `handoff_prompts/`).

**Tailwind on this Mac:** the downloaded `_build/tailwind-macos-arm64-4.3.0`
binary has an invalid signature and macOS SIGKILLs it (exit 137). Re-sign it
ad hoc after every fresh download:
`codesign --force --sign - _build/tailwind-macos-arm64-4.3.0`.
Older tailwind versions can't resolve Phoenix 1.8.13's package imports.

## How it works

| Module | Job |
|---|---|
| `TradingMicro.HubSubscription` | Connects to the hub node and subscribes each symbol on `TradingHub.Polygon.WebSocketClient` under the caller tag `trading_micro:recorder`. It re-subscribes on `nodeup` and on the hub's `:resubscribe`, marks Polygon rejections, and checks every 30s that the hub still lists each symbol. |
| `TradingMicro.Recorder.Worker` | One per symbol. It listens on `TradingContract.Topics.prices_polygon/1`, dispatches on `metadata.data_type`, and writes closed seconds every 5s. |
| `TradingMicro.Recorder.SymbolState` | A pure fold that turns messages into per-second rows, with lateness, session window and gap tracking. |
| `TradingMicro.Microstructure` | Per-event OFI and Lee–Ready trade side. These mirror `TradingCore.Signal.Compute`'s `:ofi` and `:signed_volume`, and a test checks the two agree. |
| `TradingMicro.Session` | The 04:00–20:00 ET recording window and the RTH flag (via `TradingCore.Intraday.RegularSession`, so it handles holidays and half days). |

Symbols are set in `config :trading_micro, :symbols`; adding one is a
one-line change. Set `config :trading_micro, TradingMicro.Recorder, enabled: false`
to switch the recorder off.

### Rules the data follows

- Rows are bucketed by Polygon's SIP timestamp, not arrival time. A second closes 2s after it ends. A later message for that second is counted in `late_dropped` and not recorded.
- A second with no messages has no row. Nothing is forward-filled: a second with trades but no quotes has `nil` bid/ask.
- `ofi` is Cont–Kukanov–Stoikov, and **positive means buying pressure**. An update with a `nil` size isn't scored, and if no update in a second can be scored, `ofi` is `nil`, not 0.
- Trades are signed by Lee–Ready against the quote prevailing when the trade arrives, with the tick rule used at the mid. Volume that can't be signed goes to `unknown_volume`. Prints the hub flags `updates_volume: false` are skipped.
- **Units:** sizes are stored exactly as Polygon sends them. Check whether Polygon's `bs`/`as` are shares or round lots before you compare `ofi` with trade volume.
- A quote gap of more than 60s during RTH is logged at error level once when it opens and once when it closes, and it shows on `/health` and the dashboard.
