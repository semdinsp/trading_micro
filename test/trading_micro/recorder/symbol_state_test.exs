defmodule TradingMicro.Recorder.SymbolStateTest do
  use ExUnit.Case, async: true

  alias TradingMicro.Recorder.SymbolState

  # 10:00:00 ET on a regular Tuesday (EDT), inside RTH.
  @t0 ~U[2026-10-13 14:00:00Z]

  defp d(n), do: Decimal.new(to_string(n))
  defp at(ms), do: DateTime.add(@t0, ms, :millisecond)

  defp quote(ms, bid, bid_size, ask, ask_size) do
    %{
      bid: d(bid),
      ask: d(ask),
      bid_size: bid_size && d(bid_size),
      ask_size: ask_size && d(ask_size),
      timestamp: at(ms)
    }
  end

  defp trade(ms, price, extra \\ %{}) do
    Map.merge(%{last: d(price), size: d(100), timestamp: at(ms), conditions: []}, extra)
  end

  defp new, do: SymbolState.new("SPY", @t0)

  defp fold(events, state \\ new()) do
    Enum.reduce(events, state, fn
      {:q, data}, acc -> SymbolState.apply_quote(acc, data, data.timestamp)
      {:t, data}, acc -> SymbolState.apply_trade(acc, data, data.timestamp)
    end)
  end

  # Closes everything at least 10s past t0 with no settle delay.
  defp close_all(state), do: SymbolState.close(state, at(60_000), 0)

  describe "per-second rows" do
    test "NBBO is the last quote of the second; quote_updates counts them" do
      {[row], _} =
        [
          {:q, quote(100, "100.00", 500, "100.02", 500)},
          {:q, quote(400, "100.01", 300, "100.02", 500)},
          {:q, quote(900, "100.01", 200, "100.03", 100)}
        ]
        |> fold()
        |> close_all()

      assert row.symbol == "SPY"
      assert row.ts == @t0
      assert row.bid == d("100.01")
      assert row.ask == d("100.03")
      assert row.bid_size == d(200)
      assert row.ask_size == d(100)
      assert Decimal.equal?(row.mid, d("100.02"))
      assert row.quote_updates == 3
      assert row.rth
    end

    test "OFI sums the second's updates, the first scored against the prior second" do
      {[first, second], _} =
        [
          {:q, quote(0, "100.00", 500, "100.02", 500)},
          # second 1: bid rises (+300), then ask lifted (+500)
          {:q, quote(1_100, "100.01", 300, "100.02", 500)},
          {:q, quote(1_200, "100.01", 300, "100.03", 100)}
        ]
        |> fold()
        |> close_all()

      # The very first quote has nothing to difference against.
      assert first.ofi == nil
      assert Decimal.equal?(second.ofi, d(800))
    end

    test "a quote with a nil size leaves OFI unscored rather than zero" do
      {[_, row], _} =
        [
          {:q, quote(0, "100.00", 500, "100.02", 500)},
          {:q, quote(1_100, "100.01", nil, "100.02", 500)}
        ]
        |> fold()
        |> close_all()

      assert row.ofi == nil
      assert row.bid_size == nil
      assert row.quote_updates == 1
    end

    test "seconds with no data produce no row" do
      {rows, _} =
        [
          {:q, quote(0, "100.00", 500, "100.02", 500)},
          {:q, quote(5_000, "100.00", 500, "100.02", 500)}
        ]
        |> fold()
        |> close_all()

      assert Enum.map(rows, & &1.ts) == [@t0, DateTime.add(@t0, 5)]
    end

    test "a trade-only second is not forward-filled with the prior quote" do
      {[_quote_row, trade_row], _} =
        [
          {:q, quote(0, "100.00", 500, "100.02", 500)},
          {:t, trade(1_500, "100.02")}
        ]
        |> fold()
        |> close_all()

      assert trade_row.bid == nil
      assert trade_row.ask == nil
      assert trade_row.mid == nil
      assert trade_row.quote_updates == 0
      assert trade_row.trade_count == 1
      # ...but the trade was still signed against the prevailing quote.
      assert Decimal.equal?(trade_row.buy_volume, d(100))
    end
  end

  describe "stale references across a break" do
    test "OFI does not difference against a quote older than 5s" do
      {[_, row], _} =
        [
          {:q, quote(0, "100.00", 500, "100.02", 500)},
          {:q, quote(10_000, "101.00", 300, "101.02", 500)}
        ]
        |> fold()
        |> close_all()

      assert row.ofi == nil
    end

    test "the tick rule ignores a trade older than 5s" do
      {[_, row], _} =
        [{:t, trade(0, "100.00")}, {:t, trade(10_000, "100.05")}] |> fold() |> close_all()

      assert Decimal.equal?(row.unknown_volume, d(100))
      assert Decimal.equal?(row.buy_volume, d(0))
    end

    test "nor signs a trade against a quote older than 5s" do
      {[_, row], _} =
        [{:q, quote(0, "100.00", 500, "100.02", 500)}, {:t, trade(10_000, "100.02")}]
        |> fold()
        |> close_all()

      assert Decimal.equal?(row.unknown_volume, d(100))
    end
  end

  describe "trade signing" do
    test "Lee–Ready against the prevailing quote, tick rule at the mid" do
      {[row], _} =
        [
          {:q, quote(0, "100.00", 500, "100.02", 500)},
          {:t, trade(100, "100.02", %{size: d(200)})},
          {:t, trade(200, "100.00", %{size: d(300)})},
          # at the mid (100.01): tick rule, up from 100.00 -> buy
          {:t, trade(300, "100.01", %{size: d(50)})}
        ]
        |> fold()
        |> close_all()

      assert Decimal.equal?(row.buy_volume, d(250))
      assert Decimal.equal?(row.sell_volume, d(300))
      assert Decimal.equal?(row.unknown_volume, d(0))
      assert row.trade_count == 3
    end

    test "a trade with no quote and no prior trade is unknown-side volume" do
      {[row], _} = [{:t, trade(100, "100.01")}] |> fold() |> close_all()

      assert Decimal.equal?(row.unknown_volume, d(100))
      assert row.trade_count == 1
    end

    test "prints excluded from volume by their conditions are skipped" do
      {rows, state} =
        [{:t, trade(100, "100.01", %{updates_volume: false})}] |> fold() |> close_all()

      assert rows == []
      assert state.trades_seen == 0
    end

    test "a print with no size counts as a trade but adds no volume" do
      {[row], _} =
        [{:t, Map.delete(trade(100, "100.01"), :size)}] |> fold() |> close_all()

      assert row.trade_count == 1
      assert Decimal.equal?(row.unknown_volume, d(0))
    end
  end

  describe "closing and lateness" do
    test "a second closes only once it ended settle_ms ago" do
      state = fold([{:q, quote(500, "100.00", 500, "100.02", 500)}])

      {[], state} = SymbolState.close(state, at(2_999), 2_000)
      {[row], _} = SymbolState.close(state, at(3_000), 2_000)
      assert row.ts == @t0
    end

    test "a message for an already-closed second is counted and dropped" do
      state = fold([{:q, quote(500, "100.00", 500, "100.02", 500)}])
      {[_], state} = SymbolState.close(state, at(3_000), 2_000)

      state = fold([{:q, quote(800, "100.01", 500, "100.02", 500)}], state)
      {rows, state} = SymbolState.close(state, at(10_000), 0)

      assert rows == []
      assert state.late_dropped == 1
      # The late quote still updated the prevailing book.
      assert state.quote.bid == d("100.01")
    end

    test "messages outside 04:00-20:00 ET are not recorded" do
      night = ~U[2026-10-14 01:00:00Z]

      state =
        SymbolState.apply_quote(
          new(),
          %{bid: d(1), ask: d(2), bid_size: d(1), ask_size: d(1), timestamp: night},
          night
        )

      {rows, state} = SymbolState.close(state, DateTime.add(night, 60), 0)
      assert rows == []
      assert state.outside_window == 1
    end

    test "pre-market seconds are recorded with rth false" do
      pre = ~U[2026-10-13 12:00:00Z]

      state =
        SymbolState.apply_quote(
          new(),
          %{bid: d(1), ask: d(2), bid_size: d(1), ask_size: d(1), timestamp: pre},
          pre
        )

      {[row], _} = SymbolState.close(state, DateTime.add(pre, 60), 0)
      refute row.rth
    end
  end

  describe "close_all/2" do
    test "closes the current, unsettled second too" do
      state = fold([{:q, quote(500, "100.00", 500, "100.02", 500)}])

      {[row], state} = SymbolState.close_all(state, at(600))
      assert row.ts == @t0
      assert state.buckets == %{}
    end

    test "closes a bucket stamped ahead of the local clock" do
      state = fold([{:q, quote(3_500, "100.00", 500, "100.02", 500)}])

      assert {[%{ts: ts}], _} = SymbolState.close_all(state, at(100))
      assert ts == DateTime.add(@t0, 3)
    end
  end

  describe "check_gap/3" do
    test "opens once after the threshold in RTH, closes when quotes resume" do
      state = SymbolState.new("SPY", @t0)

      assert {:none, state} = SymbolState.check_gap(state, at(30_000), 60)
      assert {{:gap_opened, silent}, state} = SymbolState.check_gap(state, at(61_000), 60)
      assert silent == 61.0
      assert SymbolState.gap_open?(state)

      # Reported once, not every flush.
      assert {:none, state} = SymbolState.check_gap(state, at(70_000), 60)

      state = SymbolState.apply_quote(state, quote(80_000, "1", 1, "2", 1), at(80_000))
      assert {{:gap_closed, gap}, state} = SymbolState.check_gap(state, at(81_000), 60)
      assert gap == 80.0
      refute SymbolState.gap_open?(state)
    end

    test "silence outside RTH is not a gap" do
      evening = ~U[2026-10-13 22:00:00Z]
      state = SymbolState.new("SPY", evening)

      assert {:none, _} = SymbolState.check_gap(state, DateTime.add(evening, 600), 60)
    end
  end
end
