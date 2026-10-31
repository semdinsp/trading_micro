defmodule TradingMicro.Recorder.WorkerTest do
  # Not async: the worker is its own process and writes through the shared
  # sandbox connection.
  use TradingMicro.DataCase, async: false

  import ExUnit.CaptureLog
  import TradingMicro.Fixtures

  alias TradingMicro.Quotes.SecondQuote
  alias TradingMicro.Recorder.Worker

  # 10:00 ET on a regular Tuesday.
  @t0 ~U[2026-10-13 14:00:00Z]

  # Supervised so ExUnit stops the worker before the clock (reverse start
  # order) and before the sandbox owner exits: its terminate/2 flush needs both.
  setup do
    clock = start_supervised!({Agent, fn -> @t0 end})
    %{clock: clock}
  end

  defp set_clock(clock, %DateTime{} = t), do: Agent.update(clock, fn _ -> t end)

  defp start_worker(clock, symbol \\ "TST", opts \\ []) do
    opts =
      Keyword.merge(
        [
          symbol: symbol,
          name: nil,
          auto_flush?: false,
          clock: fn -> Agent.get(clock, & &1) end,
          settle_ms: 2_000,
          gap_warn_seconds: 15,
          gap_alarm_seconds: 60
        ],
        opts
      )

    # name: nil → unregistered, so tests never collide with the app's own.
    start_supervised!(%{id: Worker, start: {GenServer, :start_link, [Worker, opts]}})
  end

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(
      TradingHub.PubSub,
      TradingContract.Topics.prices_polygon(message.symbol),
      message
    )
  end

  test "records hub quotes and trades as one row per second", %{clock: clock} do
    pid = start_worker(clock)

    broadcast(hub_quote("TST", DateTime.add(@t0, 100, :millisecond), "100.00", "100.02"))
    broadcast(hub_quote("TST", DateTime.add(@t0, 600, :millisecond), "100.01", "100.02", 300))
    broadcast(hub_trade("TST", DateTime.add(@t0, 700, :millisecond), "100.02", 200))
    broadcast(hub_quote("TST", DateTime.add(@t0, 1_200, :millisecond), "100.01", "100.03"))

    set_clock(clock, DateTime.add(@t0, 10))
    stats = Worker.flush(pid)

    assert stats.rows_written == 2
    assert stats.quotes_seen == 3
    assert stats.trades_seen == 1

    [first, second] = Repo.all(from q in SecondQuote, order_by: q.ts)
    assert first.symbol == "TST"
    assert first.ts == @t0
    assert first.quote_updates == 2
    assert Decimal.equal?(first.bid, d("100.01"))
    assert Decimal.equal?(first.buy_volume, d(200))
    assert first.trade_count == 1
    assert first.rth
    assert second.ts == DateTime.add(@t0, 1)
  end

  test "dispatches on data_type: aggregates and other symbols are ignored", %{clock: clock} do
    pid = start_worker(clock)

    broadcast(%{
      symbol: "TST",
      data: %{volume: 1_000, cumulative_volume: nil, timestamp: @t0},
      metadata: %{data_type: :ws_aggregate}
    })

    send(pid, hub_quote("OTHER", @t0, "1", "2"))
    send(pid, :unrelated)

    set_clock(clock, DateTime.add(@t0, 10))
    stats = Worker.flush(pid)

    assert stats.quotes_seen == 0
    assert stats.rows_written == 0
  end

  test "an unsettled second waits for the next flush", %{clock: clock} do
    pid = start_worker(clock)
    broadcast(hub_quote("TST", DateTime.add(@t0, 500, :millisecond), "100.00", "100.02"))

    set_clock(clock, DateTime.add(@t0, 2))
    assert Worker.flush(pid).rows_written == 0

    set_clock(clock, DateTime.add(@t0, 3))
    assert Worker.flush(pid).rows_written == 1
  end

  test "a quote delayed past a flush lands in its second within settle_ms", %{clock: clock} do
    pid = start_worker(clock, "TST", settle_ms: 10_000)

    set_clock(clock, DateTime.add(@t0, 5))
    Worker.flush(pid)

    # Stamped 0.5s, delivered 8s later.
    set_clock(clock, DateTime.add(@t0, 8))
    broadcast(hub_quote("TST", DateTime.add(@t0, 500, :millisecond), "100.00", "100.02"))

    set_clock(clock, DateTime.add(@t0, 12))
    stats = Worker.flush(pid)
    assert stats.late_dropped == 0
    assert stats.rows_written == 1
    assert [%{ts: ts}] = Repo.all(SecondQuote)
    assert ts == @t0
  end

  test "publishes stats on TradingMicro.PubSub after each flush", %{clock: clock} do
    Phoenix.PubSub.subscribe(TradingMicro.PubSub, Worker.stats_topic())
    pid = start_worker(clock)

    Worker.flush(pid)
    assert_receive {:recorder_stats, %{symbol: "TST"}}
  end

  test "writes open seconds on shutdown, settled or not", %{clock: clock} do
    pid = start_worker(clock)
    broadcast(hub_quote("TST", DateTime.add(@t0, 500, :millisecond), "100.00", "100.02"))

    # Still inside the quote's own second: it must be written anyway.
    set_clock(clock, DateTime.add(@t0, 600, :millisecond))
    # Sync point: the broadcast is handled before stop is.
    Worker.stats(pid)
    stop_supervised!(Worker)

    assert Repo.aggregate(SecondQuote, :count) == 1
  end

  test "logs an RTH quote gap loudly, once, and its end", %{clock: clock} do
    pid = start_worker(clock)

    set_clock(clock, DateTime.add(@t0, 61))

    log = capture_log(fn -> assert Worker.flush(pid).gap_open? end)
    assert log =~ "NO QUOTES for 61s during RTH"

    set_clock(clock, DateTime.add(@t0, 75))
    assert capture_log(fn -> Worker.flush(pid) end) == ""

    broadcast(hub_quote("TST", DateTime.add(@t0, 75), "100.00", "100.02"))
    # Sync point: received at 75s, before the clock moves.
    Worker.stats(pid)
    set_clock(clock, DateTime.add(@t0, 76))
    log = capture_log(fn -> refute Worker.flush(pid).gap_open? end)
    assert log =~ "quotes resumed after a 75s gap; 0 late messages dropped"
  end

  test "logs a gap shorter than the alarm only when it closes", %{clock: clock} do
    pid = start_worker(clock)

    set_clock(clock, DateTime.add(@t0, 20))
    assert capture_log(fn -> refute Worker.flush(pid).gap_open? end) == ""

    set_clock(clock, DateTime.add(@t0, 29))
    broadcast(hub_quote("TST", DateTime.add(@t0, 29), "100.00", "100.02"))
    Worker.stats(pid)
    set_clock(clock, DateTime.add(@t0, 30))
    log = capture_log(fn -> Worker.flush(pid) end)
    assert log =~ "quotes resumed after a 29s gap"
    refute log =~ "NO QUOTES"
  end

  test "a gap's closing log counts the backlog that arrived late", %{clock: clock} do
    pid = start_worker(clock)
    broadcast(hub_quote("TST", DateTime.add(@t0, 1), "100.00", "100.02"))
    Worker.stats(pid)

    set_clock(clock, DateTime.add(@t0, 20))
    Worker.flush(pid)

    # The stall clears: three quotes stamped for closed seconds, then a live one.
    set_clock(clock, DateTime.add(@t0, 25))

    for s <- [5, 6, 7, 24] do
      broadcast(hub_quote("TST", DateTime.add(@t0, s), "100.00", "100.02"))
    end

    Worker.stats(pid)
    log = capture_log(fn -> Worker.flush(pid) end)
    assert log =~ "quotes resumed after a 25s gap; 3 late messages dropped"
  end

  test "stats/1 by symbol is nil when no worker runs" do
    assert Worker.stats("NOPE") == nil
  end
end
