defmodule TradingMicro.MicrostructureTest do
  use ExUnit.Case, async: true

  alias TradingCore.Signal.{Compute, Spec}
  alias TradingMicro.Microstructure

  defp d(n), do: Decimal.new(to_string(n))

  defp q(bid, bid_size, ask, ask_size),
    do: %{bid: d(bid), bid_size: d(bid_size), ask: d(ask), ask_size: d(ask_size)}

  # bid 100.00 x500, ask 100.02 x500
  defp base, do: q("100.00", 500, "100.02", 500)

  describe "ofi_contribution/2: the six CKS cases, positive = buy pressure" do
    test "bid rises: the whole new bid size counts" do
      assert Microstructure.ofi_contribution(base(), q("100.01", 300, "100.02", 500)) == d(300)
    end

    test "bid unchanged: only the size change counts" do
      assert Microstructure.ofi_contribution(base(), q("100.00", 800, "100.02", 500)) == d(300)
    end

    test "bid falls: the whole previous level was pulled" do
      assert Microstructure.ofi_contribution(base(), q("99.99", 300, "100.02", 500)) == d(-500)
    end

    test "ask falls: sellers improving is sell pressure" do
      assert Microstructure.ofi_contribution(base(), q("100.00", 500, "100.01", 200)) == d(-200)
    end

    test "ask unchanged: added offer size is sell pressure" do
      assert Microstructure.ofi_contribution(base(), q("100.00", 500, "100.02", 700)) == d(-200)
    end

    test "ask rises: the previous offer was lifted" do
      assert Microstructure.ofi_contribution(base(), q("100.00", 500, "100.03", 100)) == d(500)
    end
  end

  describe "ofi_contribution/2 with missing data" do
    test "no previous quote scores nothing" do
      assert Microstructure.ofi_contribution(nil, base()) == nil
    end

    test "a nil size on either quote is unknown, not zero" do
      assert Microstructure.ofi_contribution(%{base() | bid_size: nil}, base()) == nil
      assert Microstructure.ofi_contribution(base(), %{base() | ask_size: nil}) == nil
    end

    test "a nil price is unknown" do
      assert Microstructure.ofi_contribution(base(), %{base() | bid: nil}) == nil
    end
  end

  describe "trade_side/4 (Lee–Ready)" do
    test "above the mid is a buy, below is a sell" do
      assert Microstructure.trade_side(d("100.02"), base(), nil, nil) == :buy
      assert Microstructure.trade_side(d("100.00"), base(), nil, nil) == :sell
    end

    test "at the mid falls back to the tick rule" do
      assert Microstructure.trade_side(d("100.01"), base(), d("100.00"), nil) == :buy
      assert Microstructure.trade_side(d("100.01"), base(), d("100.02"), nil) == :sell
    end

    test "a zero tick inherits the previous side" do
      assert Microstructure.trade_side(d("100.01"), base(), d("100.01"), :sell) == :sell
    end

    test "a zero tick with no previous side is unknown" do
      assert Microstructure.trade_side(d("100.01"), base(), d("100.01"), nil) == :unknown
    end

    test "no quote and no previous trade is unknown" do
      assert Microstructure.trade_side(d("100.01"), nil, nil, nil) == :unknown
    end

    test "a locked or crossed book is not a usable quote" do
      locked = q("100.01", 1, "100.01", 1)
      crossed = q("100.02", 1, "100.01", 1)

      assert Microstructure.trade_side(d("100.05"), locked, d("100.10"), nil) == :sell
      assert Microstructure.trade_side(d("100.05"), crossed, d("100.00"), nil) == :buy
    end
  end

  describe "a zero price is Polygon's empty side, not a price" do
    test "no mid, no raw mid" do
      assert Microstructure.mid(q("0", 0, "100.02", 500)) == nil
      assert Microstructure.raw_mid(d(0), d("100.02")) == nil
    end

    test "Lee–Ready falls back to the tick rule" do
      assert Microstructure.trade_side(d("100.01"), q("0", 0, "100.02", 5), d("100.02"), nil) ==
               :sell
    end

    test "OFI is unscored" do
      assert Microstructure.ofi_contribution(q("0", 0, "100.02", 5), base()) == nil
    end
  end

  describe "mid/1 and raw_mid/2" do
    test "mid needs ask > bid; raw_mid only needs both sides" do
      assert Microstructure.mid(base()) == d("100.01")
      assert Microstructure.mid(q("100.01", 1, "100.01", 1)) == nil
      assert Microstructure.raw_mid(d("100.01"), d("100.01")) == d("100.01")
      assert Microstructure.raw_mid(nil, d("100.01")) == nil
    end
  end

  # The point of these: the recorder must agree with the same feature
  # computed by trading_core everywhere else in the workspace. Any drift in
  # either implementation fails here.
  describe "parity with TradingCore.Signal.Compute" do
    @start ~U[2026-10-13 14:00:00Z]

    defp quotes(n, seed) do
      :rand.seed(:exsss, {seed, seed, seed})

      Enum.map_reduce(1..n, {10_000, 2}, fn i, {bid_cents, spread} ->
        bid_cents = bid_cents + Enum.random(-1..1)
        spread = max(1, spread + Enum.random(-1..1))

        quote = %{
          at: DateTime.add(@start, i * 10, :millisecond),
          bid: Decimal.div(d(bid_cents), 100),
          ask: Decimal.div(d(bid_cents + spread), 100),
          bid_size: d(Enum.random(1..9) * 100),
          ask_size: d(Enum.random(1..9) * 100)
        }

        {quote, {bid_cents, spread}}
      end)
      |> elem(0)
    end

    test "summed OFI matches Compute's :ofi over the same quotes" do
      ticks = quotes(500, 7)

      spec = %Spec{kind: :ofi, symbol: "SPY", window_ms: 3_600_000}
      {:ok, state} = Compute.init(spec)

      {_state, expected} =
        Enum.reduce(ticks, {state, nil}, fn tick, {acc, _} ->
          Compute.step(spec, acc, Map.put(tick, :value, nil))
        end)

      {ours, _prev} =
        Enum.reduce(ticks, {Decimal.new(0), nil}, fn tick, {sum, prev} ->
          curr = Map.take(tick, [:bid, :ask, :bid_size, :ask_size])

          sum =
            case Microstructure.ofi_contribution(prev, curr) do
              nil -> sum
              c -> Decimal.add(sum, c)
            end

          {sum, curr}
        end)

      assert Decimal.equal?(ours, expected)
    end

    test "buy minus sell volume matches Compute's lee_ready :signed_volume" do
      :rand.seed(:exsss, {11, 11, 11})

      # Interleave trades between quotes; prices land at, inside and outside
      # the quote, and sometimes repeat, so every branch is exercised.
      events =
        quotes(400, 11)
        |> Enum.flat_map(fn quote ->
          if :rand.uniform() < 0.5 do
            offset = Enum.random([-1, 0, 0, 1, 2]) |> d() |> Decimal.div(100)
            price = quote.bid |> Decimal.add(quote.ask) |> Decimal.div(2) |> Decimal.add(offset)
            size = d(Enum.random(1..5) * 100)
            [quote, %{at: DateTime.add(quote.at, 1, :millisecond), value: price, volume: size}]
          else
            [quote]
          end
        end)

      spec = %Spec{
        kind: :signed_volume,
        symbol: "SPY",
        window_ms: 3_600_000,
        params: %{"classifier" => "lee_ready"}
      }

      {:ok, state} = Compute.init(spec)

      {_state, expected} =
        Enum.reduce(events, {state, nil}, fn event, {acc, last} ->
          case Compute.step(spec, acc, event) do
            {acc, :warming_up} -> {acc, last}
            {acc, value} -> {acc, value}
          end
        end)

      {net, _} =
        Enum.reduce(events, {Decimal.new(0), %{quote: nil, price: nil, side: nil}}, fn
          %{value: price, volume: size}, {net, s} ->
            side = Microstructure.trade_side(price, s.quote, s.price, s.side)

            net =
              case side do
                :buy -> Decimal.add(net, size)
                :sell -> Decimal.sub(net, size)
                :unknown -> net
              end

            {net, %{s | price: price, side: if(side == :unknown, do: s.side, else: side)}}

          quote, {net, s} ->
            {net, %{s | quote: Map.take(quote, [:bid, :ask, :bid_size, :ask_size])}}
        end)

      assert Decimal.equal?(net, expected)
    end
  end
end
