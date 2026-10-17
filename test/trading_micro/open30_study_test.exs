defmodule TradingMicro.Open30StudyTest do
  use ExUnit.Case, async: true

  alias TradingMicro.Open30Study
  alias TradingMicro.Session

  @date ~D[2026-10-15]

  # 390 one-minute bars from the open; price.(i) gives bar i's close.
  defp bars(open_ms, price, volume \\ fn _ -> 1_000 end) do
    Map.new(0..389, fn i ->
      ts = open_ms + i * 60_000
      {ts, %{timestamp: ts, open: price.(i - 1), close: price.(i), volume: volume.(i)}}
    end)
  end

  defp day(date) do
    %{rth: {open, close}} = Session.day(date)
    {open, close, DateTime.to_unix(open, :millisecond)}
  end

  describe "session/4" do
    test "computes r30 and both targets from the bars" do
      {open, close, ms} = day(@date)
      price = fn i -> 100.0 + max(i, -1) * 0.01 end
      index = %{"SPY" => bars(ms, price), "QQQ" => bars(ms, price)}

      assert {:ok, s} = Open30Study.session(@date, open, close, index)
      assert length(s.spy.path) == 31
      assert_in_delta s.spy.r30, :math.log(price.(29) / price.(-1)), 1.0e-12
      assert_in_delta s.spy.rod, :math.log(price.(389) / price.(29)), 1.0e-12
      assert_in_delta s.spy.last30, :math.log(price.(389) / price.(359)), 1.0e-12
      assert s.vix == nil
    end

    test "skips a half day" do
      {open, close, ms} = day(~D[2026-11-27])
      index = %{"SPY" => bars(ms, fn _ -> 100.0 end), "QQQ" => bars(ms, fn _ -> 100.0 end)}
      assert Open30Study.session(~D[2026-11-27], open, close, index) == {:skip, :half_day}
    end

    test "skips a symbol with too many missing opening minutes" do
      {open, close, ms} = day(@date)
      spy = bars(ms, fn _ -> 100.0 end) |> Map.drop(for i <- 1..5, do: ms + i * 60_000)
      index = %{"SPY" => spy, "QQQ" => bars(ms, fn _ -> 100.0 end)}
      assert Open30Study.session(@date, open, close, index) == {:skip, :spy_bars}
    end
  end

  describe "session_features/1" do
    test "A2 is positive when QQQ leads SPY, negative when SPY leads" do
      {open, close, ms} = day(@date)
      wave = fn lag -> fn i -> 100.0 + :math.sin(2 * :math.pi() * (i - lag) / 20) end end

      {:ok, qqq_leads} =
        Open30Study.session(@date, open, close, %{
          "SPY" => bars(ms, wave.(3)),
          "QQQ" => bars(ms, wave.(0))
        })

      {:ok, spy_leads} =
        Open30Study.session(@date, open, close, %{
          "SPY" => bars(ms, wave.(0)),
          "QQQ" => bars(ms, wave.(3))
        })

      assert Open30Study.session_features(qqq_leads)[{"A2", "SPY"}] > 0
      assert Open30Study.session_features(spy_leads)[{"A2", "SPY"}] < 0
    end

    test "A4 is present only with VIX" do
      {open, close, ms} = day(@date)
      up = fn i -> 100.0 + i * 0.01 end
      base = %{"SPY" => bars(ms, up), "QQQ" => bars(ms, up)}

      {:ok, without} = Open30Study.session(@date, open, close, base)

      {:ok, with} =
        Open30Study.session(
          @date,
          open,
          close,
          Map.put(base, "VIX", bars(ms, &(20.0 - &1 * 0.01)))
        )

      refute Map.has_key?(Open30Study.session_features(without), {"A4", "SPY"})
      assert is_float(Open30Study.session_features(with)[{"A4", "QQQ"}])
    end
  end

  describe "logistic/2 and auc/2" do
    test "recovers a known slope" do
      :rand.seed(:exsss, {1, 2, 3})

      {x, y} =
        for _ <- 1..4_000 do
          z = :rand.normal()
          p = 1 / (1 + :math.exp(-(0.5 + 1.5 * z)))
          {[1.0, z], if(:rand.uniform() < p, do: 1.0, else: 0.0)}
        end
        |> Enum.unzip()

      assert {:ok, [b0, b1], [se0, se1]} = Open30Study.logistic(x, y)
      assert_in_delta b0, 0.5, 4 * se0
      assert_in_delta b1, 1.5, 4 * se1
    end

    test "AUC is 1 for perfect ranking, 0.5 for ties, nil for one class" do
      assert Open30Study.auc([0.1, 0.2, 0.8, 0.9], [0.0, 0.0, 1.0, 1.0]) == 1.0
      assert Open30Study.auc([1.0, 1.0, 1.0, 1.0], [0.0, 1.0, 0.0, 1.0]) == 0.5
      assert Open30Study.auc([0.1, 0.2], [1.0, 1.0]) == nil
    end
  end

  test "rotate/2 shifts circularly" do
    assert Open30Study.rotate([1, 2, 3, 4, 5], 2) == [3, 4, 5, 1, 2]
    assert Open30Study.rotate([1, 2, 3], 4) == [2, 3, 1]
  end
end
