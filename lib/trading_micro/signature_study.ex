defmodule TradingMicro.SignatureStudy do
  @moduledoc """
  Research: does the Lévy area of a recorded path predict the next move?
  Read-only. `mix micro.signature` runs it over `live_second_quotes`.

  ## Features

  Every `step` seconds of RTH, over trailing windows of 30s, 60s and 300s,
  the Lévy area (`TradingCore.Signals.Signature`, channels z-scored within
  the window, like `Compute`'s `:signature` default) of:

    * `ofi→mid`: cumulative OFI against mid, per symbol;
    * `nv→mid`: cumulative net volume (buy − sell) against mid, per symbol;
    * `QQQ→SPY`: QQQ mid against SPY mid, on seconds where both have one,
      scored against each symbol's forward return.

  The first channel is the leader: a positive area means it moved first
  and the second followed.

  ## Scoring

  Per feature and window:

    * Spearman ρ with the forward mid return over 10s, 60s and 300s;
    * a two-sided placebo p-value for ρ at 60s and 300s. Each placebo
      rotates the feature series within each day by a random offset (at
      least a tenth of the day's samples) against the returns. That breaks
      the timing but keeps each day's level and the series' own
      autocorrelation. Samples 10s apart with 60s and 300s horizons
      overlap, so a plain shuffle would make ρ look far more significant
      than it is;
    * the mean 60s forward return of the top decile minus the bottom decile,
      in bps. Compare it with the spread: it has to beat about one spread
      to pay;
    * Spearman of |area| with |60s return|, which shows whether the area
      carries volatility rather than direction information.

  A window is used only when at least half its seconds have a mid (and at
  least 10 do). The first sample of a day is one full long window after the
  open, and the last is 300s before the close, so every sample has every
  window and horizon. Nothing crosses a day boundary.
  """

  alias TradingCore.Signals.Signature

  @windows [30, 60, 300]
  @horizons [10, 60, 300]
  @tests [60, 300]
  @min_points 10
  # A forward mid is taken from the last second with one at or before
  # t + h, but no more than this many seconds earlier.
  @max_stale 5

  @type point :: %{t: integer(), mid: float() | nil, ofi: float(), net_volume: float()}

  @doc "The trailing windows, in seconds."
  def windows, do: @windows

  @doc "The forward-return horizons, in seconds."
  def horizons, do: @horizons

  @doc """
  Samples for one ET day. `series` maps each symbol to its
  `TradingMicro.Quotes.rth_series/2` list. Each sample is
  `%{day: date, t: unix_seconds, target: symbol, feature: name, window: s, value: area, fwd: %{h => bps}}`.
  """
  @spec day_samples(Date.t(), %{String.t() => [point()]}, keyword()) :: [map()]
  def day_samples(date, series, opts \\ []) do
    step = Keyword.get(opts, :step, 10)

    tracks = Map.new(series, fn {symbol, points} -> {symbol, track(points)} end)

    own =
      for {symbol, track} <- tracks,
          {feature, channel} <- [{"ofi→mid", :cum_ofi}, {"nv→mid", :cum_nv}],
          sample <- symbol_samples(track, channel, step) do
        Map.merge(sample, %{day: date, target: symbol, feature: feature})
      end

    own ++ cross_samples(date, tracks, step)
  end

  # Points with a mid, as a tuple of {t, mid, cum_ofi, cum_nv}. Cumulative
  # flow runs over every second, mid or not.
  defp track(points) do
    {kept, _} =
      Enum.reduce(points, {[], {0.0, 0.0}}, fn p, {acc, {co, cn}} ->
        co = co + p.ofi
        cn = cn + p.net_volume
        acc = if p.mid, do: [{p.t, p.mid, co, cn} | acc], else: acc
        {acc, {co, cn}}
      end)

    kept |> Enum.reverse() |> List.to_tuple()
  end

  defp symbol_samples(track, channel, step) do
    idx = if channel == :cum_ofi, do: 2, else: 3

    for t <- sample_times(track, step),
        fwd = forward(track, t),
        fwd != nil,
        {window, path} <- window_paths(track, t, fn p -> [elem(p, idx), elem(p, 1)] end),
        do: %{t: t, window: window, value: levy(path), fwd: fwd}
  end

  defp cross_samples(date, %{"SPY" => spy, "QQQ" => qqq}, step) do
    qqq_mid = Map.new(Tuple.to_list(qqq), fn p -> {elem(p, 0), elem(p, 1)} end)

    # {t, spy_mid, qqq_mid} on seconds where both have a mid.
    joint =
      spy
      |> Tuple.to_list()
      |> Enum.flat_map(fn {t, mid, _, _} ->
        case qqq_mid do
          %{^t => q} -> [{t, mid, q}]
          _ -> []
        end
      end)
      |> List.to_tuple()

    for t <- sample_times(joint, step),
        {window, path} <- window_paths(joint, t, fn {_, s, q} -> [q, s] end),
        {target, track} <- [{"SPY", spy}, {"QQQ", qqq}],
        fwd = forward(track, t),
        fwd != nil do
      %{
        day: date,
        t: t,
        target: target,
        feature: "QQQ→SPY",
        window: window,
        value: levy(path),
        fwd: fwd
      }
    end
  end

  defp cross_samples(_date, _tracks, _step), do: []

  defp sample_times(track, _step) when tuple_size(track) == 0, do: []

  defp sample_times(track, step) do
    first = elem(elem(track, 0), 0)
    last = elem(elem(track, tuple_size(track) - 1), 0)
    from = first + Enum.max(@windows)
    to = last - Enum.max(@horizons)
    if from <= to, do: Enum.take_every(from..to, step), else: []
  end

  # {window, path} for each window with enough points ending at t.
  defp window_paths(track, t, to_point) do
    hi = last_at_or_before(track, t)

    for window <- @windows,
        hi != nil,
        lo = first_after(track, t - window),
        count = hi - lo + 1,
        count >= max(@min_points, div(window, 2)) do
      {window, for(i <- lo..hi, do: to_point.(elem(track, i)))}
    end
  end

  defp levy(path),
    do: path |> Signature.normalize() |> Signature.signature() |> Signature.levy_area(0, 1)

  # %{h => forward return in bps}, or nil when t has no current mid or any
  # horizon has no mid within @max_stale seconds.
  defp forward(track, t) do
    with i when i != nil <- last_at_or_before(track, t),
         {ti, mid, _, _} when t - ti <= @max_stale <- elem(track, i) do
      Enum.reduce_while(@horizons, %{}, fn h, acc ->
        case fwd_mid(track, t + h) do
          nil -> {:halt, nil}
          m -> {:cont, Map.put(acc, h, (m / mid - 1) * 10_000)}
        end
      end)
    else
      _ -> nil
    end
  end

  defp fwd_mid(track, at) do
    with i when i != nil <- last_at_or_before(track, at),
         {ti, mid, _, _} when at - ti <= @max_stale <- elem(track, i) do
      mid
    else
      _ -> nil
    end
  end

  # Index of the last element with t <= at, or nil.
  defp last_at_or_before(track, at) do
    case first_after(track, at) do
      0 -> nil
      i -> i - 1
    end
  end

  # Index of the first element with t > at (tuple_size when none).
  defp first_after(track, at), do: bisect(track, at, 0, tuple_size(track))

  defp bisect(_track, _at, lo, hi) when lo >= hi, do: lo

  defp bisect(track, at, lo, hi) do
    mid = div(lo + hi, 2)

    if elem(elem(track, mid), 0) <= at,
      do: bisect(track, at, mid + 1, hi),
      else: bisect(track, at, lo, mid)
  end

  ## Scoring

  @doc """
  Scores `samples` grouped by `{target, feature, window}`. Options:
  `:shuffles` (placebo count, default 200; 0 skips p) and `:seed` (default 1).
  """
  @spec evaluate([map()], keyword()) :: [map()]
  def evaluate(samples, opts \\ []) do
    shuffles = Keyword.get(opts, :shuffles, 200)
    seed = Keyword.get(opts, :seed, 1)

    samples
    |> Enum.group_by(&{&1.target, &1.feature, &1.window})
    |> Enum.sort_by(fn {{target, feature, window}, _} -> {target, feature, window} end)
    |> Enum.map(fn {{target, feature, window}, group} ->
      score(group, shuffles, seed)
      |> Map.merge(%{target: target, feature: feature, window: window})
    end)
  end

  defp score(group, shuffles, seed) do
    group = Enum.sort_by(group, &{Date.to_gregorian_days(&1.day), &1.t})
    values = Enum.map(group, & &1.value)
    days = Enum.map(group, & &1.day)
    x = ranks(values)

    rho = Map.new(@horizons, fn h -> {h, pearson(x, ranks(Enum.map(group, & &1.fwd[h])))} end)

    p =
      Map.new(@tests, fn h ->
        y = ranks(Enum.map(group, & &1.fwd[h]))
        {h, shuffle_p(x, y, days, rho[h], shuffles, seed)}
      end)

    %{
      n: length(group),
      days: days |> Enum.uniq() |> length(),
      rho: rho,
      p: p,
      decile_spread_60: decile_spread(values, Enum.map(group, & &1.fwd[60])),
      rho_abs_60:
        pearson(
          ranks(Enum.map(values, &abs/1)),
          ranks(Enum.map(group, &abs(&1.fwd[60])))
        )
    }
  end

  @doc "Spearman correlation of two equal-length lists (average ranks for ties)."
  @spec spearman([number()], [number()]) :: float() | nil
  def spearman(xs, ys), do: pearson(ranks(xs), ranks(ys))

  @doc "Average ranks, 1-based, in the input order."
  @spec ranks([number()]) :: [float()]
  def ranks(xs) do
    xs
    |> Enum.with_index()
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.chunk_by(&elem(&1, 0))
    |> Enum.reduce({[], 1}, fn tied, {acc, next} ->
      k = length(tied)
      avg = next + (k - 1) / 2
      {Enum.map(tied, fn {_, i} -> {i, avg} end) ++ acc, next + k}
    end)
    |> elem(0)
    |> Enum.sort()
    |> Enum.map(&elem(&1, 1))
  end

  defp pearson(xs, ys) do
    n = length(xs)

    if n < 3 do
      nil
    else
      mx = Enum.sum(xs) / n
      my = Enum.sum(ys) / n

      {sxy, sxx, syy} =
        Enum.zip_reduce(xs, ys, {0.0, 0.0, 0.0}, fn x, y, {a, b, c} ->
          dx = x - mx
          dy = y - my
          {a + dx * dy, b + dx * dx, c + dy * dy}
        end)

      if sxx == 0.0 or syy == 0.0, do: nil, else: sxy / :math.sqrt(sxx * syy)
    end
  end

  # Share of placebos whose |ρ| reaches |actual|. Each placebo rotates x
  # within each day by a random offset, so x's autocorrelation survives.
  defp shuffle_p(_x, _y, _days, nil, _shuffles, _seed), do: nil
  defp shuffle_p(_x, _y, _days, _actual, 0, _seed), do: nil

  defp shuffle_p(x, y, days, actual, shuffles, seed) do
    :rand.seed(:exsss, {seed, 0, 0})

    # Each day's values in time order (score/3 sorts the group by time).
    groups =
      x
      |> Enum.zip(days)
      |> Enum.chunk_by(&elem(&1, 1))
      |> Enum.map(fn chunk -> Enum.map(chunk, &elem(&1, 0)) end)

    hits =
      Enum.count(1..shuffles, fn _ ->
        rotated = Enum.flat_map(groups, &rotate/1)
        r = pearson(rotated, y)
        r != nil and abs(r) >= abs(actual)
      end)

    (hits + 1) / (shuffles + 1)
  end

  defp rotate(values) do
    n = length(values)
    min = max(div(n, 10), 1)

    if n < 2 * min + 1 do
      Enum.shuffle(values)
    else
      k = min + :rand.uniform(n - 2 * min) - 1
      {head, tail} = Enum.split(values, k)
      tail ++ head
    end
  end

  defp decile_spread(values, fwd) do
    pairs = Enum.zip(values, fwd) |> Enum.sort_by(&elem(&1, 0))
    k = div(length(pairs), 10)

    if k == 0 do
      nil
    else
      bottom = pairs |> Enum.take(k) |> Enum.map(&elem(&1, 1))
      top = pairs |> Enum.take(-k) |> Enum.map(&elem(&1, 1))
      Enum.sum(top) / k - Enum.sum(bottom) / k
    end
  end

  ## Output

  @doc "The report printed by `mix micro.signature`."
  @spec format([map()], Date.t(), Date.t()) :: String.t()
  def format([], from, to), do: "No RTH samples for #{range(from, to)}."

  def format(results, from, to) do
    days = results |> Enum.map(& &1.days) |> Enum.max()

    header =
      String.pad_trailing("feature", 10) <>
        "  win     n" <>
        Enum.map_join(@horizons, &"   ρ#{pad_h(&1)}") <>
        "    p60   p300   D10-D1 60s  ρ|A|,|r60|"

    tables =
      results
      |> Enum.group_by(& &1.target)
      |> Enum.sort()
      |> Enum.map_join("\n", fn {target, rows} ->
        "#{target}\n" <> header <> "\n" <> Enum.map_join(rows, "\n", &row/1)
      end)

    """
    Path-signature study, #{range(from, to)}, #{days} day(s), RTH only

    #{tables}

    ρ: Spearman of the Lévy area with the forward mid return (bps) over 10s/60s/300s.
    p: placebo p of ρ, two-sided: the area rotated in time within each day.
    D10-D1: top-decile minus bottom-decile mean 60s return, in bps; it has to
    beat about one spread (`mix micro.report` gives each median) to pay.
    ρ|A|,|r60|: whether the area's size carries volatility, not direction.
    The leader is the first name: a positive area means it moved first.
    """
  end

  defp row(r) do
    String.pad_trailing(r.feature, 10) <>
      String.pad_leading("#{r.window}s", 5) <>
      String.pad_leading(Integer.to_string(r.n), 6) <>
      Enum.map_join(@horizons, &num(r.rho[&1], 7, 3)) <>
      num(r.p[60], 7, 3) <>
      num(r.p[300], 7, 3) <>
      num(r.decile_spread_60, 13, 2) <>
      num(r.rho_abs_60, 12, 3)
  end

  defp pad_h(h), do: String.pad_trailing(Integer.to_string(h), 3)

  defp num(nil, width, _), do: String.pad_leading("n/a", width)

  defp num(x, width, d),
    do: String.pad_leading(:erlang.float_to_binary(x * 1.0, decimals: d), width)

  defp range(from, to) when from == to, do: Date.to_iso8601(from)
  defp range(from, to), do: "#{from} to #{to}"
end
