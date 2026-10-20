defmodule TradingMicro.BreakoutStudyTest do
  use ExUnit.Case, async: true

  alias TradingMicro.BreakoutStudy

  @date ~D[2026-10-15]
  @open 1_792_071_000

  # One point per second for `n` seconds; mid.(i) and ofi.(i) per second.
  defp points(n, mid, ofi \\ fn _ -> 0.0 end) do
    for i <- 0..(n - 1), do: %{t: @open + i, mid: mid.(i), ofi: ofi.(i), net_volume: 0.0}
  end

  # A slow slide for 25 minutes (always at the low, so no fresh signal),
  # then a climb that clears the 20-minute high at about second 1609.
  defp breakout_up(i) when i < 1500, do: 100.0 - 0.0001 * i
  defp breakout_up(i), do: 99.85 + (i - 1500) * 0.001

  test "finds an upside breakout after the warm-up and scores its forward returns" do
    [b] = BreakoutStudy.day_breakouts(@date, points(5_000, &breakout_up/1))

    assert b.dir == 1
    assert b.t - @open >= 20 * 60
    assert b.fwd[300] > 0
    assert b.fwd[1800] > b.fwd[300]
  end

  test "no breakout before the 20-minute warm-up" do
    assert BreakoutStudy.day_breakouts(@date, points(1_000, &(100.0 + &1 * 0.01))) == []
  end

  test "order flow that leads the climb gives a positive area, so the breakout is confirmed" do
    # Buying pressure starts 60s before the mid moves.
    ofi = fn i -> if i >= 1440, do: 100.0, else: 0.0 end
    [b] = BreakoutStudy.day_breakouts(@date, points(5_000, &breakout_up/1, ofi))

    assert b.areas[300] > 0
    assert b.ofi_1m > 0
    th = BreakoutStudy.thresholds([b])
    assert BreakoutStudy.pass?(b, {:confirm, 300}, th)
    refute BreakoutStudy.pass?(b, {:against, 300}, th)
    assert BreakoutStudy.pass?(b, :ofi_agree, th)
  end

  test "evaluate/2 and format/5 run end to end" do
    breakouts =
      for d <- 0..9, k <- 0..5 do
        dir = if rem(k, 2) == 0, do: 1, else: -1
        area = (k - 2.5) / 3

        %{
          day: Date.add(@date, d),
          t: @open + 1500 + k * 600,
          dir: dir,
          areas: %{30 => area, 60 => area, 300 => nil},
          ofi_1m: dir * 1.0,
          fwd: %{300 => dir * area, 900 => 1.0, 1800 => -1.0}
        }
      end

    rows = BreakoutStudy.evaluate(breakouts, shuffles: 50)
    all_5m = Enum.find(rows, &(&1.filter == :all and &1.hold == 300))
    assert all_5m.n == 60
    assert all_5m.p == nil
    assert Enum.find(rows, &(&1.filter == {:confirm, 300})).n == 0

    report =
      BreakoutStudy.format(%{"SPY" => rows}, @date, Date.add(@date, 9), %{
        "SPY" => %{round_trip_bps: 0.67}
      })

    assert report =~ "SPY (60 breakouts, round trip 0.67 bps)"
    refute report =~ ~r/\bedge\b/i
  end
end
