defmodule Mix.Tasks.Micro.Signature do
  @shortdoc "Scores path-signature (Lévy area) features against forward returns"

  @moduledoc """
  Research over recorded RTH seconds: does the Lévy area of order flow
  against price, or of QQQ against SPY, predict the next move? See
  `TradingMicro.SignatureStudy` for the features and scoring.

      mix micro.signature                         # today (ET)
      mix micro.signature 2026-10-15
      mix micro.signature 2026-10-15 2026-10-30   # every trading day in range
      mix micro.signature 2026-10-15 --step 5 --shuffles 500 --seed 7

  Options: `--step` seconds between samples (default 10), `--shuffles`
  for the placebo (default 200, 0 to skip), `--seed` (default 1),
  `--notional` order size in dollars for the cost bar (default 100000).

  Each symbol's cost bar (`TradingMicro.SignatureStudy.round_trip_cost/3`)
  uses its median RTH spread (the median of the days' medians, as
  `mix micro.report` gives them) and its mean RTH mid over the range.

  Read-only. It starts the Repo, not the recorder, so it is safe to run
  next to a live server. Run it after the close: a day's last samples need
  five minutes of forward data.
  """

  use Mix.Task

  alias TradingMicro.Quotes
  alias TradingMicro.Session
  alias TradingMicro.SignatureStudy

  @switches [step: :integer, shuffles: :integer, seed: :integer, notional: :integer]

  @impl true
  def run(args) do
    {opts, dates} = OptionParser.parse!(args, strict: @switches)

    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started([:postgrex, :ecto_sql, :tzdata])
    {:ok, _} = TradingMicro.Repo.start_link(pool_size: 2)

    {from, to} =
      case dates do
        [] -> Session.et_date(DateTime.utc_now()) |> then(&{&1, &1})
        [d] -> Date.from_iso8601!(d) |> then(&{&1, &1})
        [a, b] -> {Date.from_iso8601!(a), Date.from_iso8601!(b)}
      end

    symbols = Application.get_env(:trading_micro, :symbols, [])

    {samples, mids} =
      Enum.flat_map_reduce(Date.range(from, to), %{}, fn date, mids ->
        series = Map.new(symbols, &{&1, Quotes.rth_series(&1, date)})

        mids =
          Enum.reduce(series, mids, fn {symbol, points}, acc ->
            day = for %{mid: mid} when is_float(mid) <- points, do: mid
            Map.update(acc, symbol, day, &(day ++ &1))
          end)

        {SignatureStudy.day_samples(date, series, Keyword.take(opts, [:step])), mids}
      end)

    costs = costs(symbols, from, to, mids, Keyword.get(opts, :notional, 100_000))

    Mix.shell().info(
      SignatureStudy.format(
        SignatureStudy.evaluate(samples, Keyword.take(opts, [:shuffles, :seed])),
        from,
        to,
        costs
      )
    )
  end

  defp costs(symbols, from, to, mids, notional) do
    spreads =
      Date.range(from, to)
      |> Enum.flat_map(&Quotes.session_report(&1, symbols))
      |> Enum.filter(&(Map.get(&1, :median_spread_bps) != nil))
      |> Enum.group_by(& &1.symbol, & &1.median_spread_bps)

    for symbol <- symbols,
        [_ | _] = days <- [Map.get(spreads, symbol, [])],
        [_ | _] = prices <- [Map.get(mids, symbol, [])],
        into: %{} do
      price = Enum.sum(prices) / length(prices)
      {symbol, SignatureStudy.round_trip_cost(median(days), price, notional)}
    end
  end

  defp median(xs) do
    sorted = Enum.sort(xs)
    n = length(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 1,
      do: Enum.at(sorted, mid),
      else: (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
  end
end
