defmodule TradingMicro.BreakoutStudy do
  @moduledoc """
  Research: does order flow leading price confirm a Donchian breakout?
  Read-only; nothing here trades. `mix micro.breakout` runs it.

  ## Breakouts

  `TradingCore.Signal.Compute` kind `:donchian` with a 20-minute window,
  the same code `trading_signal` runs, stepped with each RTH second's mid
  (seconds without a mid are skipped). A breakout is a second whose value is
  ±1 when the previous quoted second's was 0, at least 20 minutes after the
  open. One in the same direction within 5 minutes of the last is ignored.
  The rules match `trading_backtest`'s `DonchianOfiStudy`, which tested raw
  1-minute OFI as the filter (PR #58).

  ## Confirmation

  At the breakout second, over trailing windows of 30s, 60s and 300s, the
  Lévy area of (cumulative OFI, mid), as in `TradingMicro.SignatureStudy`:
  positive when order flow moved first and the mid followed. The breakout
  is *confirmed* when the area's sign matches its direction, *against*
  when it doesn't, and *strong* when it is confirmed and `|area|` is in the
  top third of that symbol and window's breakouts (a threshold set on the
  whole sample, so it looks ahead). `ofi agree` is PR #58's filter for
  comparison: 1-minute OFI on the breakout's side.

  ## Trades

  Each breakout is an independent trade (trades may overlap), entered at
  the first quoted second at least 1s after the signal second and held
  5, 15 or 30 minutes (or to the last quote). Returns are mid to mid in bps,
  signed by direction; `net` subtracts one taker round trip
  (`SignatureStudy.round_trip_cost/3`).

  ## Placebo

  The confirmation features are permuted across each day's breakouts and
  the filter re-applied; p is the share of placebo means at or above the
  actual mean. That asks whether the filter picks better breakouts than a
  random subset of the same day's breakouts of the same size.
  """

  alias TradingCore.Signal.Compute
  alias TradingCore.Signal.Spec
  alias TradingCore.Signals.Signature

  @window_ms 20 * 60 * 1000
  @warmup_s 20 * 60
  @repeat_s 5 * 60
  @delay_s 1
  @windows [30, 60, 300]
  @holds [300, 900, 1800]
  @min_points 10

  @doc "The trailing windows for the Lévy area, in seconds."
  def windows, do: @windows

  @doc "The holding periods, in seconds."
  def holds, do: @holds

  @doc "Filter names, in report order."
  def filters,
    do: [:all, :ofi_agree] ++ for(w <- @windows, f <- [:confirm, :against, :strong], do: {f, w})

  @doc """
  The breakouts in one symbol's `TradingMicro.Quotes.rth_series/3` for
  ET `date`. Each is `%{day:, t:, dir:, areas: %{window => float | nil},
  ofi_1m:, fwd: %{hold => bps}}`.
  """
  @spec day_breakouts(Date.t(), [map()]) :: [map()]
  def day_breakouts(date, points) do
    track = track(points)

    if tuple_size(track) == 0 do
      []
    else
      open = elem(elem(track, 0), 0)

      track
      |> breakouts(open)
      |> Enum.flat_map(fn {i, dir} ->
        {t, _, _} = elem(track, i)

        case entry(track, i, t + @delay_s) do
          nil ->
            []

          e ->
            [
              %{
                day: date,
                t: t,
                dir: dir,
                areas: Map.new(@windows, &{&1, area(track, i, t, &1)}),
                ofi_1m: ofi_since(track, i, t - 60),
                fwd: Map.new(@holds, &{&1, forward(track, e, dir, &1)})
              }
            ]
        end
      end)
    end
  end

  # {t, mid, cum_ofi} for seconds with a mid; cumulative OFI runs over every
  # second, mid or not.
  defp track(points) do
    {kept, _} =
      Enum.reduce(points, {[], 0.0}, fn p, {acc, co} ->
        co = co + p.ofi
        {if(p.mid, do: [{p.t, p.mid, co} | acc], else: acc), co}
      end)

    kept |> Enum.reverse() |> List.to_tuple()
  end

  defp breakouts(track, open) do
    spec = %Spec{kind: :donchian, window_ms: @window_ms}
    {:ok, state} = Compute.init(spec)

    {events, _} =
      Enum.reduce(0..(tuple_size(track) - 1), {[], {state, nil, %{}}}, fn i,
                                                                          {events,
                                                                           {state, prev, last}} ->
        {t, mid, _} = elem(track, i)
        {state, value} = Compute.step(spec, state, %{at: DateTime.from_unix!(t), value: mid})
        value = int_value(value)

        fresh? =
          value in [1, -1] and prev == 0 and t - open >= @warmup_s and
            (last[value] == nil or t - last[value] >= @repeat_s)

        if fresh?,
          do: {[{i, value} | events], {state, value, Map.put(last, value, t)}},
          else: {events, {state, value, last}}
      end)

    Enum.reverse(events)
  end

  defp int_value(%Decimal{} = v), do: Decimal.to_integer(v)
  defp int_value(_warming_up), do: nil

  defp entry(track, i, at) do
    Enum.find((i + 1)..(tuple_size(track) - 1)//1, fn j -> elem(elem(track, j), 0) >= at end)
  end

  defp forward(track, e, dir, hold) do
    {te, me, _} = elem(track, e)
    last = tuple_size(track) - 1
    x = Enum.find(e..last//1, last, fn j -> elem(elem(track, j), 0) >= te + hold end)
    {_, mx, _} = elem(track, x)
    dir * (mx / me - 1) * 10_000
  end

  defp area(track, i, t, window) do
    lo = Enum.find(i..0//-1, fn j -> j == 0 or elem(elem(track, j - 1), 0) <= t - window end)
    count = i - lo + 1

    if count >= max(@min_points, div(window, 2)) do
      for(j <- lo..i, do: elem(track, j) |> then(fn {_, mid, co} -> [co, mid] end))
      |> Signature.normalize()
      |> Signature.signature()
      |> Signature.levy_area(0, 1)
    end
  end

  # Cumulative OFI now minus at the last quoted second at or before `since`.
  defp ofi_since(track, i, since) do
    {_, _, now} = elem(track, i)

    base =
      case Enum.find(i..0//-1, fn j -> elem(elem(track, j), 0) <= since end) do
        nil -> 0.0
        j -> elem(elem(track, j), 2)
      end

    now - base
  end

  ## Scoring

  @doc """
  Strong-confirmation thresholds: `%{window => the 2/3 quantile of |area|}`
  over `breakouts`.
  """
  @spec thresholds([map()]) :: %{pos_integer() => float()}
  def thresholds(breakouts) do
    Map.new(@windows, fn w ->
      sorted = for(%{areas: %{^w => a}} when is_float(a) <- breakouts, do: abs(a)) |> Enum.sort()
      {w, if(sorted == [], do: 0.0, else: Enum.at(sorted, div(2 * length(sorted), 3)))}
    end)
  end

  @doc "Whether breakout `b` (or `b` with substituted `features`) passes `filter`."
  def pass?(b, filter, thresholds, features \\ nil)
  def pass?(_b, :all, _th, _f), do: true

  def pass?(%{dir: dir} = b, :ofi_agree, _th, f),
    do: dir * (f || b).ofi_1m > 0

  def pass?(%{dir: dir} = b, {kind, w}, th, f) do
    case (f || b).areas[w] do
      a when is_float(a) ->
        case kind do
          :confirm -> dir * a > 0
          :against -> dir * a < 0
          :strong -> dir * a > 0 and abs(a) >= th[w]
        end

      _ ->
        false
    end
  end

  @doc """
  One row per filter and hold for one symbol's `breakouts`: `n`, `mean`,
  `win`, `days`, `days_up`, `ex_best_day` (the total without the best day),
  and the placebo `p` (nil for `:all`). Options: `:shuffles` (default 500),
  `:seed` (default 1).
  """
  @spec evaluate([map()], keyword()) :: [map()]
  def evaluate(breakouts, opts \\ []) do
    shuffles = Keyword.get(opts, :shuffles, 500)
    seed = Keyword.get(opts, :seed, 1)
    th = thresholds(breakouts)
    by_day = breakouts |> Enum.group_by(& &1.day) |> Map.values()
    placebos = placebo_features(by_day, shuffles, seed)

    for filter <- filters(), hold <- @holds do
      passing = for b <- breakouts, pass?(b, filter, th), do: {b.day, b.fwd[hold]}
      summary = summarize(passing)

      p =
        if filter != :all and summary.mean do
          means =
            for features <- placebos,
                vs =
                  for(
                    {b, f} <- Enum.zip(List.flatten(by_day), features),
                    pass?(b, filter, th, f),
                    do: b.fwd[hold]
                  ),
                vs != [],
                do: Enum.sum(vs) / length(vs)

          if means == [],
            do: nil,
            else: (Enum.count(means, &(&1 >= summary.mean)) + 1) / (length(means) + 1)
        end

      Map.merge(summary, %{filter: filter, hold: hold, p: p})
    end
  end

  # `shuffles` lists of features, each permuted within its day, aligned
  # with `List.flatten(by_day)`.
  defp placebo_features(by_day, shuffles, seed) do
    :rand.seed(:exsss, {seed, 3, 5})

    for _ <- 1..shuffles//1 do
      Enum.flat_map(by_day, fn day ->
        day |> Enum.map(&Map.take(&1, [:areas, :ofi_1m])) |> Enum.shuffle()
      end)
    end
  end

  defp summarize(by_day) do
    values = Enum.map(by_day, &elem(&1, 1))
    n = length(values)

    day_totals =
      by_day
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {d, v} -> {d, Enum.sum(v)} end)

    total = Enum.sum(values)

    %{
      n: n,
      mean: if(n > 0, do: total / n),
      win: if(n > 0, do: Enum.count(values, &(&1 > 0)) / n),
      days: map_size(day_totals),
      days_up: Enum.count(day_totals, fn {_, v} -> v > 0 end),
      ex_best_day: if(n > 0, do: total - Enum.max(Map.values(day_totals)))
    }
  end

  ## Output

  @doc """
  The report for `results` (`%{symbol => evaluate/2 rows}`). `costs` maps a
  symbol to its `SignatureStudy.round_trip_cost/3`.
  """
  @spec format(%{String.t() => [map()]}, Date.t(), Date.t(), map(), [String.t()]) :: String.t()
  def format(results, from, to, costs, notes \\ []) do
    tables =
      results
      |> Enum.sort()
      |> Enum.map_join("\n", fn {symbol, rows} ->
        cost = costs[symbol]
        rt = cost && cost.round_trip_bps

        header =
          "filter            " <>
            Enum.map_join(@holds, fn h ->
              String.pad_leading("#{div(h, 60)}m: n  mean   net  win%    p", 34)
            end)

        body =
          rows
          |> Enum.group_by(& &1.filter)
          |> then(fn g -> Enum.map(filters(), &{&1, g[&1]}) end)
          |> Enum.map_join("\n", fn {filter, cells} ->
            String.pad_trailing(label(filter), 18) <>
              Enum.map_join(Enum.sort_by(cells, & &1.hold), &cell(&1, rt))
          end)

        "#{symbol} (#{breakout_count(rows)} breakouts, round trip #{num(rt, 0, 2)} bps)\n" <>
          header <> "\n" <> body <> "\n"
      end)

    hits =
      for {_, rows} <- results, r <- rows, r.p != nil, do: r.p < 0.05

    """
    Donchian 20m breakout × order-flow-led-price (Lévy area), #{from} to #{to}, RTH only

    #{tables}
    Cells with a placebo p: #{length(hits)}; p < 0.05: #{Enum.count(hits, & &1)} (about #{Float.round(length(hits) * 0.05, 1)} expected by chance).

    mean: mean return per breakout, mid to mid, bps, before costs. net: mean minus one
    taker round trip. win%: share of trades above 0 before costs. p: one-sided placebo,
    the filter's features permuted across each day's breakouts.
    confirm/against: the Lévy area of (cumulative OFI, mid) over the window agrees /
    disagrees with the breakout's direction. strong: confirm with |area| in the top
    third. ofi agree: 1m OFI on the breakout's side (trading_backtest PR #58's filter).
    #{Enum.map_join(notes, "\n", & &1)}
    """
  end

  defp breakout_count(rows),
    do: rows |> Enum.find(&(&1.filter == :all)) |> Map.get(:n)

  defp label(:all), do: "all"
  defp label(:ofi_agree), do: "ofi agree"
  defp label({kind, w}), do: "#{kind} #{w}s"

  defp cell(r, rt) do
    net = if r.mean && rt, do: r.mean - rt

    String.pad_leading(Integer.to_string(r.n), 11) <>
      num(r.mean, 6, 2) <>
      num(net, 6, 2) <>
      num(r.win && r.win * 100, 6, 0) <>
      num(r.p, 5, 2)
  end

  defp num(nil, width, _), do: String.pad_leading("n/a", width)

  defp num(x, width, d),
    do: String.pad_leading(:erlang.float_to_binary(x * 1.0, decimals: d), width)
end
