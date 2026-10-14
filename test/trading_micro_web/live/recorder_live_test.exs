defmodule TradingMicroWeb.RecorderLiveTest do
  use TradingMicroWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TradingMicro.Fixtures

  alias TradingMicro.Quotes
  alias TradingMicro.Recorder.Worker

  test "renders the monitor with an empty state per symbol", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")

    assert html =~ "Microstructure Recorder"
    assert has_element?(view, "#card-SPY")
    assert has_element?(view, "#card-QQQ")
    assert has_element?(view, "#rows-SPY-empty", "No seconds recorded yet")
    assert has_element?(view, "#rows-SPY-empty", "Not connected to Trading Hub")
    assert has_element?(view, "#overall-status", "disabled")
  end

  test "shows recorded seconds and adds new ones when a flush is announced", %{conn: conn} do
    t0 = ~U[2026-10-13 14:00:00Z]
    Quotes.insert_rows([row("SPY", t0, %{ofi: d(-300)})])

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#SPY-#{DateTime.to_unix(t0)}", "10:00:00")
    assert has_element?(view, "#SPY-#{DateTime.to_unix(t0)} .text-short", "-300")

    t1 = DateTime.add(t0, 1)
    Quotes.insert_rows([row("SPY", t1)])

    send(view.pid, {:recorder_stats, stats("SPY")})

    assert has_element?(view, "#SPY-#{DateTime.to_unix(t1)} .text-long", "+200")
    assert has_element?(view, "#card-SPY", "100.00")
  end

  defp stats(symbol) do
    %{
      symbol: symbol,
      quotes_seen: 10,
      trades_seen: 2,
      rows_written: 2,
      rows_dropped: 0,
      pending_rows: 0,
      open_seconds: 0,
      late_dropped: 0,
      outside_window: 0,
      last_message_at: nil,
      last_message_age_s: 0.4,
      last_quote_at: nil,
      last_quote_age_s: 0.4,
      gap_open?: false,
      quote: %{bid: d("100.00"), ask: d("100.02"), bid_size: d(500), ask_size: d(400)},
      last_flush_at: nil,
      last_flush_error: nil
    }
  end

  test "stats topic is the worker's" do
    assert Worker.stats_topic() == "micro:recorder_stats"
  end
end
