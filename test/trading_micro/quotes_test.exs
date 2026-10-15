defmodule TradingMicro.QuotesTest do
  use TradingMicro.DataCase, async: true

  import TradingMicro.Fixtures

  alias TradingMicro.Quotes
  alias TradingMicro.Quotes.SecondQuote

  @open ~U[2026-10-13 13:30:00Z]

  describe "insert_rows/1" do
    test "writes rows and round-trips every column" do
      assert Quotes.insert_rows([row("SPY", @open, %{ofi: nil, bid_size: nil})]) == 1

      [stored] = Repo.all(SecondQuote)
      assert stored.symbol == "SPY"
      assert stored.ts == @open
      assert Decimal.equal?(stored.bid, d("100.00"))
      assert stored.bid_size == nil
      assert stored.ofi == nil
      assert stored.quote_updates == 3
      assert stored.rth
    end

    test "re-inserting the same (symbol, ts) replaces rather than duplicates" do
      Quotes.insert_rows([row("SPY", @open)])
      Quotes.insert_rows([row("SPY", @open, %{quote_updates: 9})])

      assert [%{quote_updates: 9}] = Repo.all(SecondQuote)
    end

    test "empty input is a no-op" do
      assert Quotes.insert_rows([]) == 0
    end

    test "large batches are chunked under the parameter limit" do
      rows = for i <- 0..4_999, do: row("SPY", DateTime.add(@open, i))
      assert Quotes.insert_rows(rows) == 5_000
    end
  end

  test "rows_since/2 counts per symbol" do
    now = DateTime.add(@open, 120)

    Quotes.insert_rows([
      row("SPY", DateTime.add(now, -10)),
      row("SPY", DateTime.add(now, -20)),
      row("QQQ", DateTime.add(now, -30)),
      row("QQQ", DateTime.add(now, -90))
    ])

    assert Quotes.rows_since(now, 60) == %{"SPY" => 2, "QQQ" => 1}
  end

  test "recent/2 is newest first and limited" do
    Quotes.insert_rows(for i <- 0..4, do: row("SPY", DateTime.add(@open, i)))

    assert [a, b] = Quotes.recent("SPY", 2)
    assert a.ts == DateTime.add(@open, 4)
    assert b.ts == DateTime.add(@open, 3)
  end

  describe "rth_series/2" do
    test "RTH rows only, oldest first, as floats with nil OFI as 0" do
      Quotes.insert_rows([
        row("SPY", ~U[2026-10-13 13:29:59Z], %{rth: false}),
        row("SPY", DateTime.add(@open, 1), %{
          ofi: nil,
          mid: nil,
          buy_volume: d(0),
          sell_volume: d(30)
        }),
        row("SPY", @open),
        row("SPY", ~U[2026-10-13 20:00:00Z], %{rth: false}),
        row("QQQ", @open)
      ])

      assert [first, second] = Quotes.rth_series("SPY", ~D[2026-10-13])

      assert first == %{t: DateTime.to_unix(@open), mid: 100.01, ofi: 200.0, net_volume: 100.0}
      assert second == %{t: DateTime.to_unix(@open) + 1, mid: nil, ofi: 0.0, net_volume: -30.0}
    end

    test "a holiday has no series" do
      assert Quotes.rth_series("SPY", ~D[2026-11-26]) == []
    end
  end

  describe "largest_gap/3" do
    test "finds the longest run with no quoted second, edges included" do
      open = ~U[2026-10-13 13:30:00Z]
      close = DateTime.add(open, 10)
      quoted = [open, DateTime.add(open, 1), DateTime.add(open, 5), DateTime.add(open, 6)]

      # Missing 2,3,4 (3s) and 7,8,9 (3s): the first one wins.
      assert Quotes.largest_gap(quoted, open, close) == {3, DateTime.add(open, 2)}
    end

    test "counts a silent open" do
      open = ~U[2026-10-13 13:30:00Z]
      assert Quotes.largest_gap([DateTime.add(open, 4)], open, DateTime.add(open, 5)) == {4, open}
    end

    test "full coverage is no gap" do
      open = ~U[2026-10-13 13:30:00Z]
      quoted = for i <- 0..4, do: DateTime.add(open, i)
      assert Quotes.largest_gap(quoted, open, DateTime.add(open, 5)) == {0, nil}
    end
  end

  describe "session_report/2" do
    test "reports rows, coverage, median spread and the largest gap" do
      pre = ~U[2026-10-13 12:00:00Z]

      Quotes.insert_rows(
        [row("SPY", pre, %{rth: false})] ++
          for(i <- 0..9, do: row("SPY", DateTime.add(@open, i))) ++
          [row("SPY", DateTime.add(@open, 100), %{quote_updates: 0, bid: nil, ask: nil})]
      )

      [report] = Quotes.session_report(~D[2026-10-13], ["SPY"])

      assert report.trading_day
      assert report.rows == 12
      assert report.rth_rows == 11
      assert report.rth_seconds == 23_400
      assert_in_delta report.rth_quote_coverage, 10 / 23_400, 1.0e-9
      # (0.02 / 100.01) * 10_000
      assert_in_delta report.median_spread_bps, 1.9998, 1.0e-3
      # From second 10 to the close.
      assert report.largest_rth_gap_s == 23_390
      assert report.largest_rth_gap_at == DateTime.add(@open, 10)
    end

    test "a holiday is reported as not a trading day" do
      assert [%{trading_day: false}] = Quotes.session_report(~D[2026-11-26], ["SPY"])
    end
  end
end
