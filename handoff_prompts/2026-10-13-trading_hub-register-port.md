# trading_hub: register trading_micro (port 4020) as a sibling app

**From:** trading_micro, 2026-10-13. Docs and config only; no behaviour change.

`trading_micro` is a new sibling app that records SPY/QQQ per-second NBBO and trade flow from the hub's Polygon feed. It runs as `trading_micro@Scotts-Mac-mini.local` on **port 4020**. Its `config/dev.exs` already defaults to 4020, and it serves `GET /health` (always 200, JSON) like the other siblings.

Please:

1. Add `"trading_micro" => 4020` to `:trading_hub, :cluster_app_ports` in `config/dev.exs`.
2. Add this row to the README's "Sibling app ports" table:
   `| trading_micro | 4020 | PORT env var, default 4020 — microstructure recorder (live_second_quotes) |`
3. Optionally, add a note to the CLAUDE.md topic list or the Polygon WS docs: `trading_micro` holds its own refcount on `TradingHub.Polygon.WebSocketClient` under the caller tag `"trading_micro:recorder"` for SPY and QQQ. So those symbols now stay subscribed when no other app holds them.

The hub's Polygon code needs no change. trading_micro only calls `subscribe_symbol/2`, `unsubscribe_symbol/2` and `get_subscriptions/0` over `:erpc`, and listens on `prices:polygon:SYMBOL`.
