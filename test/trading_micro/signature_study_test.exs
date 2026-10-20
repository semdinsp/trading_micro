defmodule TradingMicro.SignatureStudyTest do
  use ExUnit.Case, async: true

  alias TradingMicro.SignatureStudy

  @day ~D[2026-10-15]
  @t0 1_792_071_000

  # A series of n seconds; fun.(i) returns {mid, cum_flow}. ofi and
  # net_volume are the per-second increments of cum_flow.
  defp series(n, fun) do
    {points, _} =
      Enum.map_reduce(0..(n - 1), 0.0, fn i, prev ->
        {mid, cum} = fun.(i)
        {%{t: @t0 + i, mid: mid, ofi: cum - prev, net_volume: cum - prev}, cum}
      end)

    points
  end

  defp wave(i, lag), do: :math.sin(2 * :math.pi() * (i - lag) / 120)

  defp mean_value(samples, feature, window) do
    vals = for s <- samples, s.feature == feature, s.window == window, do: s.value
    Enum.sum(vals) / length(vals)
  end

  describe "day_samples/3 Lévy area sign" do
    test "flow that leads price gives a positive area" do
      spy = series(900, fn i -> {100 + 0.05 * wave(i, 10), 1_000 * wave(i, 0)} end)
      samples = SignatureStudy.day_samples(@day, %{"SPY" => spy})

      assert mean_value(samples, "ofi→mid", 60) > 0
      assert mean_value(samples, "nv→mid", 60) > 0
    end

    test "price that leads flow gives a negative area" do
      spy = series(900, fn i -> {100 + 0.05 * wave(i, 0), 1_000 * wave(i, 10)} end)
      samples = SignatureStudy.day_samples(@day, %{"SPY" => spy})

      assert mean_value(samples, "ofi→mid", 60) < 0
    end

    test "QQQ→SPY is positive when QQQ moves first, and is scored on both targets" do
      spy = series(900, fn i -> {100 + 0.05 * wave(i, 10), 0.0} end)
      qqq = series(900, fn i -> {200 + 0.1 * wave(i, 0), 0.0} end)
      samples = SignatureStudy.day_samples(@day, %{"SPY" => spy, "QQQ" => qqq})

      assert mean_value(samples, "QQQ→SPY", 60) > 0

      targets = for s <- samples, s.feature == "QQQ→SPY", uniq: true, do: s.target
      assert Enum.sort(targets) == ["QQQ", "SPY"]
    end

    test "no cross feature with one symbol" do
      spy = series(900, fn i -> {100 + 0.01 * i, 0.0} end)
      samples = SignatureStudy.day_samples(@day, %{"SPY" => spy})
      refute Enum.any?(samples, &(&1.feature == "QQQ→SPY"))
    end
  end

  describe "day_samples/3 sampling" do
    test "samples start one long window after the open and stop 300s before the close" do
      spy = series(1_000, fn i -> {100 + 0.01 * i, 0.0} end)
      samples = SignatureStudy.day_samples(@day, %{"SPY" => spy}, step: 10)

      # Sample times 300, 310, ..., 690 seconds after t0.
      n_times = div(690 - 300, 10) + 1
      assert length(samples) == n_times * 3 * 2
      assert samples |> Enum.map(& &1.window) |> Enum.uniq() |> Enum.sort() == [30, 60, 300]
    end

    test "forward returns are mid-to-mid in bps" do
      spy = series(1_000, fn i -> {100 + 0.01 * i, 0.0} end)
      [s | _] = SignatureStudy.day_samples(@day, %{"SPY" => spy}, step: 10)

      # First sample is at i = 300, mid 103.
      assert_in_delta s.fwd[10], (103.1 / 103 - 1) * 10_000, 1.0e-9
      assert_in_delta s.fwd[300], (106.0 / 103 - 1) * 10_000, 1.0e-9
    end

    test "a sample whose current or forward mid is more than 5s stale is dropped" do
      # No mid for seconds 305..330. Samples at 300 (its 10s horizon, 310,
      # only sees 304) and 310..330 (their current mid is 304) are dropped.
      # At 340 the 30s window holds 331..340, 10 seconds, under half.
      spy =
        series(1_000, fn i -> {100 + 0.01 * i, 0.0} end)
        |> Enum.map(fn p -> if (p.t - @t0) in 305..330, do: %{p | mid: nil}, else: p end)

      samples = SignatureStudy.day_samples(@day, %{"SPY" => spy}, step: 10)

      times = fn window ->
        for s <- samples, s.feature == "ofi→mid", s.window == window, do: s.t - @t0
      end

      assert times.(60) == Enum.to_list(340..690//10)
      assert times.(30) == Enum.to_list(350..690//10)
    end

    test "a window with fewer than half its seconds is skipped" do
      # Mids only every 3rd second: a 30s window holds 10 (needs 15).
      spy =
        series(1_000, fn i -> {100 + 0.01 * i, 0.0} end)
        |> Enum.map(fn p -> if rem(p.t - @t0, 3) == 0, do: p, else: %{p | mid: nil} end)

      windows =
        for s <- SignatureStudy.day_samples(@day, %{"SPY" => spy}), uniq: true, do: s.window

      refute 30 in windows
    end

    test "cumulative flow includes seconds without a mid" do
      # Flow arrives only on mid-less seconds; the area still sees it.
      spy =
        series(900, fn i -> {100 + 0.05 * wave(i, 10), 1_000 * wave(i, 0)} end)
        |> Enum.map(fn p -> if rem(p.t - @t0, 2) == 1, do: %{p | mid: nil}, else: p end)

      samples = SignatureStudy.day_samples(@day, %{"SPY" => spy})
      assert mean_value(samples, "ofi→mid", 60) > 0
    end

    test "an empty day has no samples" do
      assert SignatureStudy.day_samples(@day, %{"SPY" => [], "QQQ" => []}) == []
    end
  end

  describe "ranks/1 and spearman/2" do
    test "ties get the average rank" do
      assert SignatureStudy.ranks([10, 20, 20, 5]) == [2.0, 3.5, 3.5, 1.0]
    end

    test "monotone is 1, reversed is -1, constant is nil" do
      assert SignatureStudy.spearman([1, 2, 3, 4], [1, 4, 9, 16]) == 1.0
      assert SignatureStudy.spearman([1, 2, 3, 4], [4, 3, 2, 1]) == -1.0
      assert SignatureStudy.spearman([1, 2, 3, 4], [5, 5, 5, 5]) == nil
    end
  end

  describe "evaluate/2" do
    defp sample(day, value, r) do
      %{
        day: day,
        target: "SPY",
        feature: "ofi→mid",
        window: 60,
        value: value,
        fwd: %{10 => r, 60 => r, 300 => r},
        t: System.unique_integer([:positive, :monotonic])
      }
    end

    test "a feature that orders the forward return is significant" do
      samples = for i <- 1..200, do: sample(@day, i * 1.0, i * 0.01)
      [r] = SignatureStudy.evaluate(samples, shuffles: 99, seed: 3)

      assert r.n == 200
      assert r.days == 1
      assert_in_delta r.rho[60], 1.0, 1.0e-12
      assert r.p[60] == 1 / 100
      # Top 20 average 1.905 bps, bottom 20 average 0.105.
      assert_in_delta r.decile_spread_60, 1.8, 1.0e-9
    end

    test "noise is not significant and the shuffle is reproducible" do
      :rand.seed(:exsss, {42, 0, 0})
      samples = for _ <- 1..300, do: sample(@day, :rand.normal(), :rand.normal())

      [a] = SignatureStudy.evaluate(samples, shuffles: 199, seed: 5)
      [b] = SignatureStudy.evaluate(samples, shuffles: 199, seed: 5)

      assert a.p == b.p
      assert a.p[60] > 0.05
    end

    test "two unrelated persistent series are not called significant" do
      # Overlapping samples make both the area and the forward return
      # persistent (here AR(1), φ = 0.95), and unrelated persistent series
      # correlate by accident: ρ ≈ −0.16 for this seed. A plain shuffle
      # breaks the persistence and puts that at p ≈ 0.005; rotating in time
      # keeps it, so the placebo sees accidental ρ that size too.
      :rand.seed(:exsss, {3, 0, 0})
      ar = fn -> Enum.scan(1..600, 0.0, fn _, acc -> 0.95 * acc + :rand.normal() end) end
      xs = ar.()
      ys = ar.()

      samples = Enum.zip_with(xs, ys, fn x, y -> sample(@day, x, y) end)
      [r] = SignatureStudy.evaluate(samples, shuffles: 199, seed: 2)

      assert abs(r.rho[60]) > 0.1
      assert r.p[60] > 0.2
    end

    test "the placebo stays within each day" do
      # Day 1's values are all larger and its returns all larger, but within
      # each day there is no relation. A pooled shuffle would put the p at
      # its floor, 1/200 (no shuffle reaches ρ > 0.5); a within-day shuffle
      # keeps the day effect in every shuffle, so the p is well above it.
      :rand.seed(:exsss, {7, 0, 0})
      day1 = for _ <- 1..150, do: sample(@day, 100 + :rand.normal(), 10 + :rand.normal())

      day2 =
        for _ <- 1..150, do: sample(Date.add(@day, 1), :rand.normal(), :rand.normal())

      [r] = SignatureStudy.evaluate(day1 ++ day2, shuffles: 199, seed: 1)

      assert r.days == 2
      assert r.rho[60] > 0.5
      assert r.p[60] > 0.02
    end

    test "groups by target, feature and window" do
      samples =
        for t <- ["QQQ", "SPY"], w <- [30, 60], i <- 1..20 do
          %{sample(@day, i * 1.0, i * 0.1) | target: t, window: w}
        end

      results = SignatureStudy.evaluate(samples, shuffles: 0)

      assert Enum.map(results, &{&1.target, &1.window}) ==
               [{"QQQ", 30}, {"QQQ", 60}, {"SPY", 30}, {"SPY", 60}]

      assert Enum.all?(results, &(&1.p[60] == nil))
    end
  end

  describe "round_trip_cost/3" do
    test "spread plus buy and sell commission, with the bar at two round trips" do
      c = SignatureStudy.round_trip_cost(0.26, 768.0)

      assert c.shares == 130
      assert c.spread_bps == 0.26

      buy = TradingCore.CostModel.order_commission(Decimal.new(130), Decimal.new("768.0"), "buy")

      sell =
        TradingCore.CostModel.order_commission(Decimal.new(130), Decimal.new("768.0"), "sell")

      expected = Decimal.to_float(Decimal.add(buy, sell)) / (130 * 768.0) * 10_000

      assert_in_delta c.commission_bps, expected, 1.0e-9
      assert_in_delta c.round_trip_bps, 0.26 + expected, 1.0e-9
      assert_in_delta c.bar_bps, 2 * c.round_trip_bps, 1.0e-12
    end

    test "a small order pays the minimum, so costs more in bps" do
      big = SignatureStudy.round_trip_cost(0.3, 70.0)
      small = SignatureStudy.round_trip_cost(0.3, 70.0, 1_000)

      assert small.shares == 14
      assert small.commission_bps > big.commission_bps
    end
  end

  describe "format/3" do
    test "prints a table per target and handles missing numbers" do
      results =
        SignatureStudy.evaluate(for(i <- 1..20, do: sample(@day, i * 1.0, i * 0.1)), shuffles: 0)

      out = SignatureStudy.format(results, @day, @day)

      assert out =~ "2026-10-15, 1 day(s)"
      assert out =~ "SPY\nfeature"
      assert out =~ "ofi→mid     60s    20"
      assert out =~ "n/a"
    end

    test "with costs, prints the cost line and marks a D10-D1 over the bar" do
      # D10-D1 is 1.8 bps (see "a feature that orders the forward return").
      results =
        SignatureStudy.evaluate(for(i <- 1..200, do: sample(@day, i * 1.0, i * 0.01)),
          shuffles: 0
        )

      cheap = %{"SPY" => SignatureStudy.round_trip_cost(0.2, 700.0)}
      dear = %{"SPY" => SignatureStudy.round_trip_cost(1.0, 700.0)}

      out = SignatureStudy.format(results, @day, @day, cheap)

      assert out =~
               ~r/round trip 0\.\d\d bps \(spread 0\.20 \+ commission 0\.\d\d, 142 sh at \$700\.00\)/

      assert out =~ "1.80*"

      refute SignatureStudy.format(results, @day, @day, dear) =~ "1.80*"
    end

    test "says so when there is nothing" do
      assert SignatureStudy.format([], @day, Date.add(@day, 3)) =~
               "No RTH samples for 2026-10-15 to 2026-10-18."
    end
  end

  describe "time_bucket/2" do
    test "places a second by its minutes after the open" do
      %{rth: {open, _}} = TradingMicro.Session.day(~D[2026-10-15])
      at = fn minutes -> DateTime.to_unix(open) + minutes * 60 end

      assert SignatureStudy.time_bucket(~D[2026-10-15], at.(0)) == {0, "09:30-10:00"}
      assert SignatureStudy.time_bucket(~D[2026-10-15], at.(30)) == {30, "10:00-11:30"}
      assert SignatureStudy.time_bucket(~D[2026-10-15], at.(269)) == {120, "11:30-14:00"}
      assert SignatureStudy.time_bucket(~D[2026-10-15], at.(389)) == {360, "15:30-16:00"}
    end
  end
end
