defmodule TradingMicro.Open30Study do
  @moduledoc """
  Research: do Lévy areas over the first 30 minutes of RTH (09:30–10:00
  ET) predict the rest of the day for SPY and QQQ, beyond what the
  first-30-minute return already says? Read-only; `mix micro.open30`
  runs it over Polygon 1-minute bars fetched through trading_hub.

  ## Features

  Per session, the Lévy area of a 31-point path (the 09:30 open, then the
  close of each 1-minute bar to 09:59), computed by
  `TradingCore.Signal.Compute`'s `:signature` kind (each channel z-scored
  within the window, `output: "levy_area"`, pair `[0, 1]`):

    * `A1`: (time, log price), per symbol;
    * `A2`: (QQQ log price, SPY log price), scored against both;
    * `A3`: (log price, cumulative volume), per symbol;
    * `A4`: (SPY log price, VIX level), scored against both.

  The control is `r30 = log(P_10:00 / P_09:30)`.

  ## Targets

    * `rod`: `log(P_close / P_10:00)`;
    * `last30`: `log(P_close / P_15:30)`.

  `P_close` is the close of the 15:59 bar. A missing bar carries the last
  close forward, at most 5 minutes.

  ## Tests, per {feature, target symbol, horizon} cell

    1. Hit rate of sign(feature) against sign(target), Spearman ρ, and the
       top-minus-bottom decile mean target (tercile under 200 sessions).
    2. Logistic regression `up ~ r30 + feature` against `up ~ r30`: the
       feature's standardized coefficient and Wald z, and the AUC lift.
    3. Walk-forward: both models fit on the first 70% of sessions by date;
       the AUCs are measured only on the last 30%.
    4. Placebo: the feature series shifted circularly by k = 5..50
       sessions against the targets, so each placebo keeps the feature's
       distribution and autocorrelation but breaks its pairing with the
       day. ρ's p is two-sided; the AUC lift's is one-sided (placebo lift
       at least the actual).
    5. ρ and hit rate split by the previous session's `regime_sessions`
       label (vol and trend). The previous one, because a session's own
       label is computed from its close.
  """

  alias TradingCore.Signal.Compute
  alias TradingCore.Signal.Spec
  alias TradingMicro.SignatureStudy

  @minutes 30
  @max_carry 5
  @min_bars 27
  @min_vix_bars 25
  @rth_minutes 390
  @shifts 5..50
  @horizons [:rod, :last30]

  @features [
    {"A1", "(time, log price)"},
    {"A2", "(QQQ log price, SPY log price)"},
    {"A3", "(log price, cum volume)"},
    {"A4", "(SPY log price, VIX)"}
  ]

  @doc "Feature names and descriptions, in report order."
  def features, do: @features

  ## Sessions

  @doc """
  One session's inputs, or `{:skip, reason}`. `open` and `close` are the
  RTH bounds (UTC DateTimes, from `TradingMicro.Session.day/1`); `index`
  maps `"SPY"`, `"QQQ"` and optionally `"VIX"` to `%{bar_start_ms => bar}`.
  A half day (shorter than 390 minutes) is skipped.
  """
  @spec session(Date.t(), DateTime.t(), DateTime.t(), %{String.t() => map()}) ::
          {:ok, map()} | {:skip, atom()}
  def session(date, open, close, index) do
    open_ms = DateTime.to_unix(open, :millisecond)

    with :ok <- full_day(open, close),
         {:ok, spy} <- symbol(Map.get(index, "SPY", %{}), open_ms, :spy),
         {:ok, qqq} <- symbol(Map.get(index, "QQQ", %{}), open_ms, :qqq) do
      {:ok, %{date: date, open_ms: open_ms, spy: spy, qqq: qqq, vix: vix(index["VIX"], open_ms)}}
    end
  end

  defp full_day(open, close) do
    if DateTime.diff(close, open, :minute) == @rth_minutes, do: :ok, else: {:skip, :half_day}
  end

  defp symbol(bars, open_ms, name) do
    first = bars[open_ms]
    present = Enum.count(0..(@minutes - 1), &Map.has_key?(bars, open_ms + &1 * 60_000))

    with true <- first != nil and present >= @min_bars,
         {:ok, path} <- path(bars, open_ms, first.open),
         p1530 when p1530 != nil <- close_at(bars, open_ms, @rth_minutes - 31),
         pclose when pclose != nil <- close_at(bars, open_ms, @rth_minutes - 1) do
      p930 = first.open * 1.0
      {p1000, _} = List.last(path)

      {:ok,
       %{
         path: path,
         r30: :math.log(p1000 / p930),
         rod: :math.log(pclose / p1000),
         last30: :math.log(pclose / p1530)
       }}
    else
      _ -> {:skip, :"#{name}_bars"}
    end
  end

  # [{price, volume}] for the 09:30 open and each minute's close to 09:59.
  defp path(bars, open_ms, open_price) do
    {points, _} =
      Enum.map_reduce(0..(@minutes - 1), open_price * 1.0, fn i, last ->
        case bars[open_ms + i * 60_000] do
          %{close: c, volume: v} -> {{c * 1.0, (v || 0) * 1.0}, c * 1.0}
          _ -> {{last, 0.0}, last}
        end
      end)

    {:ok, [{open_price * 1.0, 0.0} | points]}
  end

  # The close of the bar starting `minute` minutes after the open, or of
  # the latest bar up to @max_carry minutes earlier.
  defp close_at(bars, open_ms, minute) do
    Enum.find_value(minute..max(minute - @max_carry, 0)//-1, fn m ->
      case bars[open_ms + m * 60_000] do
        %{close: c} -> c * 1.0
        _ -> nil
      end
    end)
  end

  # 31 VIX levels on the same grid, or nil when too many minutes are missing.
  defp vix(nil, _open_ms), do: nil

  defp vix(bars, open_ms) do
    closes = for i <- 0..(@minutes - 1), do: get_in(bars, [open_ms + i * 60_000, :close])

    first =
      case bars[open_ms] do
        %{open: o} when is_number(o) -> o
        _ -> Enum.find(closes, &is_number/1)
      end

    if Enum.count(closes, &is_number/1) >= @min_vix_bars and is_number(first) do
      {levels, _} =
        Enum.map_reduce(closes, first * 1.0, fn
          c, _last when is_number(c) -> {c * 1.0, c * 1.0}
          _, last -> {last, last}
        end)

      [first * 1.0 | levels]
    end
  end

  ## Features

  @doc """
  `%{{feature, target} => area}` for one session. A2 and A4 are one area
  scored against both targets; A4 is absent without VIX.
  """
  @spec session_features(map()) :: %{{String.t(), String.t()} => float()}
  def session_features(%{spy: spy, qqq: qqq, vix: vix} = s) do
    spy_prices = Enum.map(spy.path, &elem(&1, 0))
    qqq_prices = Enum.map(qqq.path, &elem(&1, 0))

    a2 = area(s, ["reference_log_price", "log_price"], spy_prices, qqq_prices, nil)

    own =
      for {target, sym, prices} <- [{"SPY", spy, spy_prices}, {"QQQ", qqq, qqq_prices}],
          {feature, area} <- [
            {"A1", area(s, ["time", "log_price"], prices, nil, nil)},
            {"A3",
             area(s, ["log_price", "volume"], prices, nil, Enum.map(sym.path, &elem(&1, 1)))}
          ],
          into: %{},
          do: {{feature, target}, area}

    cross =
      for target <- ["SPY", "QQQ"],
          {feature, area} <- [
            {"A2", a2},
            {"A4", vix && area(s, ["log_price", "reference"], spy_prices, vix, nil)}
          ],
          area != nil,
          into: %{},
          do: {{feature, target}, area}

    Map.merge(own, cross)
  end

  # Replays the 31 points through Compute's :signature, one tick per bar.
  defp area(%{open_ms: open_ms}, channels, values, references, volumes) do
    spec = %Spec{
      kind: :signature,
      params: %{
        "channels" => channels,
        "window" => @minutes + 1,
        "output" => "levy_area",
        "pair" => [0, 1]
      }
    }

    {:ok, state} = Compute.init(spec)
    n = length(values)
    references = references || List.duplicate(nil, n)
    volumes = volumes || List.duplicate(nil, n)

    {_state, out} =
      [values, references, volumes]
      |> Enum.zip()
      |> Enum.with_index()
      |> Enum.reduce({state, :warming_up}, fn {{v, r, vol}, k}, {st, _} ->
        tick = %{
          at: DateTime.from_unix!(open_ms + k * 60_000, :millisecond),
          value: v,
          reference: r,
          volume: vol
        }

        Compute.step(spec, st, tick)
      end)

    case out do
      %Decimal{} = d -> Decimal.to_float(d)
      _ -> nil
    end
  end

  ## Evaluation

  @doc """
  Scores `sessions` (from `session/4`). `regimes` maps a session date to
  the previous session's `%{vol: label, trend: label}`. Option `:train`
  is the walk-forward training share (default 0.7).
  """
  @spec evaluate([map()], %{Date.t() => map()}, keyword()) :: map()
  def evaluate(sessions, regimes \\ %{}, opts \\ []) do
    train = Keyword.get(opts, :train, 0.7)
    sessions = Enum.sort_by(sessions, &Date.to_gregorian_days(&1.date))
    rows = Enum.map(sessions, &Map.put(&1, :features, session_features(&1)))

    cells =
      for {feature, _} <- @features,
          target <- ["SPY", "QQQ"],
          horizon <- @horizons,
          data = cell_data(rows, feature, target, horizon),
          length(data) >= 30 do
        score_cell(data, train)
        |> Map.merge(%{feature: feature, target: target, horizon: horizon})
        |> Map.put(:regimes, regime_split(data, regimes))
      end

    controls =
      for target <- ["SPY", "QQQ"], horizon <- @horizons do
        data =
          for %{date: d} = s <- rows,
              sym = sym(s, target),
              do: %{date: d, x: sym.r30, r30: sym.r30, y: sym[horizon]}

        Map.merge(describe(data), %{
          target: target,
          horizon: horizon,
          oos_auc: r30_auc(data, train)
        })
      end

    %{
      sessions: length(sessions),
      from: sessions |> List.first() |> then(&(&1 && &1.date)),
      to: sessions |> List.last() |> then(&(&1 && &1.date)),
      vix_sessions: Enum.count(sessions, & &1.vix),
      train: train,
      cells: cells,
      controls: controls
    }
  end

  defp sym(s, "SPY"), do: s.spy
  defp sym(s, "QQQ"), do: s.qqq

  defp cell_data(rows, feature, target, horizon) do
    for %{date: d, features: f} = s <- rows,
        x = f[{feature, target}],
        x != nil,
        sym = sym(s, target),
        do: %{date: d, x: x, r30: sym.r30, y: sym[horizon]}
  end

  defp score_cell(data, train) do
    xs = Enum.map(data, & &1.x)
    ys = Enum.map(data, & &1.y)
    actual = walk_forward(data, train)

    placebo_rho = for k <- @shifts, do: SignatureStudy.spearman(rotate(xs, k), ys)

    placebo_lift =
      for k <- @shifts,
          shifted = Enum.zip_with(data, rotate(xs, k), &%{&1 | x: &2}),
          wf = walk_forward(shifted, train),
          do: wf.lift

    stats = describe(data)

    Map.merge(stats, %{
      rho_p: p_two_sided(stats.rho, placebo_rho),
      wf: actual,
      lift_p: p_one_sided(actual.lift, placebo_lift),
      placebo_lift_p95: percentile(placebo_lift, 0.95)
    })
  end

  # n, hit rate, Spearman ρ and the extreme-bucket spread (bps) of x vs y.
  defp describe(data) do
    xs = Enum.map(data, & &1.x)
    ys = Enum.map(data, & &1.y)

    signed = Enum.reject(data, &(&1.x == 0 or &1.y == 0))
    hits = Enum.count(signed, &(&1.x > 0 == &1.y > 0))

    %{
      n: length(data),
      up_rate: Enum.count(ys, &(&1 > 0)) / max(length(ys), 1),
      hit: if(signed == [], do: nil, else: hits / length(signed)),
      rho: SignatureStudy.spearman(xs, ys),
      spread_bps: bucket_spread(xs, ys),
      buckets: if(length(data) >= 200, do: 10, else: 3)
    }
  end

  defp bucket_spread(xs, ys) do
    buckets = if length(xs) >= 200, do: 10, else: 3
    pairs = Enum.zip(xs, ys) |> Enum.sort_by(&elem(&1, 0))
    k = div(length(pairs), buckets)

    if k == 0 do
      nil
    else
      mean = fn ps -> Enum.sum(Enum.map(ps, &elem(&1, 1))) / k end
      (mean.(Enum.take(pairs, -k)) - mean.(Enum.take(pairs, k))) * 10_000
    end
  end

  @doc false
  def rotate(xs, k) do
    n = length(xs)
    {head, tail} = Enum.split(xs, rem(k, n))
    tail ++ head
  end

  defp p_two_sided(nil, _), do: nil

  defp p_two_sided(actual, placebo) do
    placebo = Enum.reject(placebo, &is_nil/1)
    (Enum.count(placebo, &(abs(&1) >= abs(actual))) + 1) / (length(placebo) + 1)
  end

  defp p_one_sided(nil, _), do: nil

  defp p_one_sided(actual, placebo) do
    placebo = Enum.reject(placebo, &is_nil/1)
    (Enum.count(placebo, &(&1 >= actual)) + 1) / (length(placebo) + 1)
  end

  defp percentile(xs, q) do
    case xs |> Enum.reject(&is_nil/1) |> Enum.sort() do
      [] -> nil
      sorted -> Enum.at(sorted, min(round(q * (length(sorted) - 1)), length(sorted) - 1))
    end
  end

  ## Walk-forward logistic regression

  defp split(data, train) do
    Enum.split(data, round(length(data) * train))
  end

  defp walk_forward(data, train) do
    {fit, test} = split(data, train)
    ups = fn rows -> Enum.map(rows, &if(&1.y > 0, do: 1.0, else: 0.0)) end

    {m_r, s_r} = mean_sd(Enum.map(fit, & &1.r30))
    {m_x, s_x} = mean_sd(Enum.map(fit, & &1.x))
    z = fn row -> [1.0, (row.r30 - m_r) / s_r, (row.x - m_x) / s_x] end

    x1 = Enum.map(fit, z)
    x0 = Enum.map(x1, &Enum.take(&1, 2))
    y = ups.(fit)

    with {:ok, b1, se1} <- logistic(x1, y),
         {:ok, b0, _} <- logistic(x0, y) do
      y_test = ups.(test)
      test1 = Enum.map(test, z)
      auc1 = auc(Enum.map(test1, &dot(&1, b1)), y_test)
      auc0 = auc(Enum.map(test1, &dot(Enum.take(&1, 2), b0)), y_test)

      %{
        fit_n: length(fit),
        test_n: length(test),
        coef: Enum.at(b1, 2),
        coef_z: Enum.at(b1, 2) / Enum.at(se1, 2),
        auc_r30: auc0,
        auc_both: auc1,
        lift: auc1 && auc0 && auc1 - auc0
      }
    else
      _ ->
        %{
          fit_n: length(fit),
          test_n: length(test),
          coef: nil,
          coef_z: nil,
          auc_r30: nil,
          auc_both: nil,
          lift: nil
        }
    end
  end

  defp r30_auc(data, train) do
    {fit, test} = split(data, train)
    {m, s} = mean_sd(Enum.map(fit, & &1.r30))
    ups = fn rows -> Enum.map(rows, &if(&1.y > 0, do: 1.0, else: 0.0)) end

    case logistic(Enum.map(fit, &[1.0, (&1.r30 - m) / s]), ups.(fit)) do
      {:ok, b, _} -> auc(Enum.map(test, &dot([1.0, (&1.r30 - m) / s], b)), ups.(test))
      _ -> nil
    end
  end

  defp mean_sd(xs) do
    n = length(xs)
    mean = Enum.sum(xs) / n
    sd = :math.sqrt(Enum.sum(Enum.map(xs, &((&1 - mean) ** 2))) / n)
    {mean, if(sd == 0.0, do: 1.0, else: sd)}
  end

  defp dot(a, b), do: Enum.zip_reduce(a, b, 0.0, fn x, y, acc -> acc + x * y end)

  @doc """
  Logistic regression by Newton–Raphson. `x` is a list of rows (include a
  1.0 column for the intercept), `y` 0/1 floats. Returns
  `{:ok, coefficients, standard_errors}` or `:error` if it doesn't converge.
  """
  @spec logistic([[float()]], [float()]) :: {:ok, [float()], [float()]} | :error
  def logistic(x, y), do: newton(x, y, List.duplicate(0.0, length(hd(x))), 0)

  defp newton(_x, _y, _b, 50), do: :error

  defp newton(x, y, b, iter) do
    d = length(b)

    {grad, hess} =
      Enum.zip_reduce(x, y, {List.duplicate(0.0, d), zeros(d)}, fn row, yi, {g, h} ->
        p = 1 / (1 + :math.exp(-dot(row, b)))
        w = p * (1 - p)

        {Enum.zip_with(g, row, &(&1 + (yi - p) * &2)),
         for({hrow, ri} <- Enum.zip(h, row), do: Enum.zip_with(hrow, row, &(&1 + w * ri * &2)))}
      end)

    # A tiny ridge keeps a separable or flat column from making H singular.
    hess = for {row, i} <- Enum.with_index(hess), do: List.update_at(row, i, &(&1 + 1.0e-8))

    case solve(hess, grad) do
      nil ->
        :error

      step ->
        b = Enum.zip_with(b, step, &(&1 + &2))

        if Enum.all?(step, &(abs(&1) < 1.0e-10)) do
          se = for i <- 0..(d - 1), do: :math.sqrt(abs(Enum.at(solve(hess, unit(d, i)), i)))
          {:ok, b, se}
        else
          newton(x, y, b, iter + 1)
        end
    end
  end

  defp zeros(d), do: List.duplicate(List.duplicate(0.0, d), d)
  defp unit(d, i), do: for(j <- 0..(d - 1), do: if(i == j, do: 1.0, else: 0.0))

  # Gaussian elimination with partial pivoting; nil if singular.
  defp solve(a, b) do
    rows = Enum.zip_with(a, b, &(&1 ++ [&2]))
    d = length(b)

    Enum.reduce_while(0..(d - 1), rows, fn col, rows ->
      {pivot_row, pivot_i} =
        rows
        |> Enum.with_index()
        |> Enum.drop(col)
        |> Enum.max_by(&abs(Enum.at(elem(&1, 0), col)))

      pivot = Enum.at(pivot_row, col)

      if abs(pivot) < 1.0e-14 do
        {:halt, nil}
      else
        rows =
          rows |> List.replace_at(pivot_i, Enum.at(rows, col)) |> List.replace_at(col, pivot_row)

        norm = Enum.map(pivot_row, &(&1 / pivot))

        rows =
          rows
          |> Enum.with_index()
          |> Enum.map(fn
            {_row, ^col} -> norm
            {row, _} -> Enum.zip_with(row, norm, &(&1 - Enum.at(row, col) * &2))
          end)

        {:cont, rows}
      end
    end)
    |> case do
      nil -> nil
      rows -> Enum.map(rows, &List.last/1)
    end
  end

  @doc "Area under the ROC curve of `scores` for 0/1 `labels` (Mann–Whitney, ties averaged)."
  @spec auc([float()], [float()]) :: float() | nil
  def auc(scores, labels) do
    n1 = Enum.count(labels, &(&1 == 1.0))
    n0 = length(labels) - n1

    if n1 == 0 or n0 == 0 do
      nil
    else
      rank_sum =
        scores
        |> SignatureStudy.ranks()
        |> Enum.zip(labels)
        |> Enum.reduce(0.0, fn {r, l}, acc -> if l == 1.0, do: acc + r, else: acc end)

      (rank_sum - n1 * (n1 + 1) / 2) / (n1 * n0)
    end
  end

  ## Regime split

  defp regime_split(data, regimes) do
    for axis <- [:vol, :trend],
        {label, rows} <-
          data
          |> Enum.group_by(&get_in(regimes, [&1.date, axis]))
          |> Enum.reject(fn {label, _} -> is_nil(label) end)
          |> Enum.sort(),
        length(rows) >= 30 do
      xs = Enum.map(rows, & &1.x)
      ys = Enum.map(rows, & &1.y)
      stats = describe(rows)

      placebo =
        if length(rows) > 2 * Enum.max(@shifts),
          do: for(k <- @shifts, do: SignatureStudy.spearman(rotate(xs, k), ys))

      Map.merge(stats, %{
        axis: axis,
        label: label,
        rho_p: placebo && p_two_sided(stats.rho, placebo)
      })
    end
  end

  ## Output

  @doc "The report printed by `mix micro.open30`. `notes` are printed under the header."
  @spec format(map(), [String.t()]) :: String.t()
  def format(result, notes \\ [])

  def format(%{sessions: 0}, notes), do: Enum.join(["No sessions." | notes], "\n")

  def format(r, notes) do
    cells = r.cells
    main_tests = length(cells)
    rho_hits = Enum.count(cells, &(is_number(&1.rho_p) and &1.rho_p < 0.05))
    lift_hits = Enum.count(cells, &(is_number(&1.lift_p) and &1.lift_p < 0.05))
    adds = Enum.filter(cells, &(is_number(&1.wf.lift) and &1.wf.lift > 0 and &1.lift_p < 0.05))
    regime_cells = Enum.flat_map(cells, & &1.regimes)
    regime_hits = Enum.count(regime_cells, &(is_number(&1.rho_p) and &1.rho_p < 0.05))
    regime_tested = Enum.count(regime_cells, &is_number(&1.rho_p))

    """
    Opening-30-minute Lévy-area study, #{r.from} to #{r.to}
    #{r.sessions} full sessions (#{r.vix_sessions} with VIX). Walk-forward: fit on the first #{pct(r.train)}, AUC on the last #{pct(1 - r.train)}.
    #{Enum.map_join(notes, "\n", &("  " <> &1))}

    Features (Lévy area, 09:30–10:00, channels z-scored, TradingCore.Signal.Compute :signature):
    #{Enum.map_join(@features, "\n", fn {f, d} -> "  #{f}  #{d}" end)}
    Targets: rod = log(P_close / P_10:00), last30 = log(P_close / P_15:30). Control: r30 = log(P_10:00 / P_09:30).

    ## Control: r30 alone
    target  horizon     n    up%    hit     ρ   spread bps  OOS AUC
    #{Enum.map_join(r.controls, "\n", &control_row/1)}

    ## 1–4. Each feature: in-sample association, then walk-forward AUC over r30
    feature target horizon     n    hit      ρ   p(ρ)  spread bps |  coef     z | AUC r30  AUC both    lift  p(lift)  placebo95
    #{Enum.map_join(cells, "\n", &cell_row/1)}

    ## 5. ρ by previous session's regime (cells with ≥ 30 sessions; p only with > 100)
    feature target horizon  axis   label        n    hit      ρ   p(ρ)
    #{Enum.map_join(cells, "\n", &regime_rows/1)}

    ## 6. Multiple testing
    Main cells: #{main_tests}. At p < 0.05 chance gives about #{fmt(main_tests * 0.05, 1)} per test.
      ρ placebo p < 0.05: #{rho_hits}
      AUC-lift placebo p < 0.05: #{lift_hits}
    Regime cells with a p: #{regime_tested}; chance gives about #{fmt(regime_tested * 0.05, 1)}. Observed: #{regime_hits}.
    Placebo p's come from #{Enum.count(@shifts)} day shifts, so the smallest possible is #{fmt(1 / (Enum.count(@shifts) + 1), 3)}.

    #{verdict(adds)}

    hit: share of sessions where sign(feature) = sign(target) (r30 row: sign(r30)). 50% is no information; below 50% is information with the opposite sign.
    spread: mean target of the top #{bucket_word(r)} of the feature minus the bottom, in bps.
    coef / z: the feature's standardized coefficient in up ~ r30 + feature, and its Wald z, on the training sessions.
    lift: out-of-sample AUC(r30 + feature) − AUC(r30). p(lift): share of day-shift placebos with at least that lift. placebo95: their 95th percentile.
    """
  end

  defp verdict([]),
    do:
      "Verdict: no feature adds out-of-sample AUC over r30 (no cell with lift > 0 and placebo p < 0.05). Stopping here, per the plan."

  defp verdict(adds) do
    "Cells with lift > 0 and placebo p < 0.05: " <>
      Enum.map_join(adds, ", ", &"#{&1.feature} #{&1.target} #{&1.horizon}") <>
      ". Compare the count with the chance count above before reading anything into them."
  end

  defp bucket_word(%{cells: [%{buckets: 10} | _]}), do: "decile"
  defp bucket_word(_), do: "tercile"

  defp control_row(c) do
    pad(c.target, 7) <>
      pad(to_string(c.horizon), 8) <>
      lpad(Integer.to_string(c.n), 6) <>
      num(c.up_rate * 100, 7, 1) <>
      num(c.hit && c.hit * 100, 7, 1) <>
      num(c.rho, 7, 3) <>
      num(c.spread_bps, 12, 1) <>
      num(c.oos_auc, 9, 3)
  end

  defp cell_row(c) do
    pad(c.feature, 8) <>
      pad(c.target, 7) <>
      pad(to_string(c.horizon), 7) <>
      lpad(Integer.to_string(c.n), 6) <>
      num(c.hit && c.hit * 100, 7, 1) <>
      num(c.rho, 7, 3) <>
      num(c.rho_p, 7, 3) <>
      num(c.spread_bps, 12, 1) <>
      " |" <>
      num(c.wf.coef, 6, 3) <>
      num(c.wf.coef_z, 6, 2) <>
      " |" <>
      num(c.wf.auc_r30, 8, 3) <>
      num(c.wf.auc_both, 10, 3) <>
      num(c.wf.lift, 8, 3) <>
      num(c.lift_p, 9, 3) <>
      num(c.placebo_lift_p95, 11, 3)
  end

  defp regime_rows(c) do
    Enum.map_join(c.regimes, "\n", fn g ->
      pad(c.feature, 8) <>
        pad(c.target, 7) <>
        pad(to_string(c.horizon), 8) <>
        pad(to_string(g.axis), 7) <>
        pad(g.label, 9) <>
        lpad(Integer.to_string(g.n), 6) <>
        num(g.hit && g.hit * 100, 7, 1) <>
        num(g.rho, 7, 3) <>
        num(g.rho_p, 7, 3)
    end)
  end

  defp pct(x), do: "#{round(x * 100)}%"
  defp pad(s, w), do: String.pad_trailing(s, w)
  defp lpad(s, w), do: String.pad_leading(s, w)
  defp fmt(x, d), do: :erlang.float_to_binary(x * 1.0, decimals: d)

  defp num(nil, width, _), do: lpad("n/a", width)
  defp num(x, width, d), do: lpad(fmt(x, d), width)
end
