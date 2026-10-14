defmodule TradingMicro.Fixtures do
  @moduledoc "Row and hub-message builders shared by tests."

  def d(n), do: Decimal.new(to_string(n))

  @doc "A closed-second row as SymbolState.close/3 emits it."
  def row(symbol, ts, attrs \\ %{}) do
    Map.merge(
      %{
        symbol: symbol,
        ts: ts,
        bid: d("100.00"),
        ask: d("100.02"),
        bid_size: d(500),
        ask_size: d(400),
        mid: d("100.01"),
        quote_updates: 3,
        ofi: d(200),
        buy_volume: d(100),
        sell_volume: d(0),
        unknown_volume: d(0),
        trade_count: 1,
        rth: true
      },
      attrs
    )
  end

  @doc "A hub `:ws_quote` broadcast, shaped like TradingHub.Message."
  def hub_quote(symbol, %DateTime{} = ts, bid, ask, bid_size \\ 500, ask_size \\ 500) do
    %{
      source: :polygon,
      type: :price,
      symbol: symbol,
      data: %{
        bid: d(bid),
        ask: d(ask),
        bid_size: bid_size && d(bid_size),
        ask_size: ask_size && d(ask_size),
        timestamp: ts
      },
      metadata: %{source: "polygon.io", data_type: :ws_quote}
    }
  end

  @doc "A hub `:ws_trade` broadcast."
  def hub_trade(symbol, %DateTime{} = ts, price, size \\ 100) do
    %{
      source: :polygon,
      type: :price,
      symbol: symbol,
      data: %{last: d(price), size: d(size), timestamp: ts, conditions: []},
      metadata: %{source: "polygon.io", data_type: :ws_trade}
    }
  end
end
