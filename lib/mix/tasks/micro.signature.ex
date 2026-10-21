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
      mix micro.signature 2026-09-08 2026-10-09 --source history --by-time

  Options: `--step` seconds between samples (default 10), `--shuffles`
  for the placebo (default 200, 0 to skip), `--seed` (default 1),
  `--notional` order size in dollars for the cost bar (default 100000).

  `--source history` reads trading_backtest's `second_quotes` (SPY and
  QQQ, 2026-09-08 to 2026-10-09) from the `trading_backtest_dev` database
  on the same server instead of `live_second_quotes`. `--by-time` prints
  one report per time of day (`TradingMicro.SignatureStudy.time_buckets/0`),
  each sample placed by its own time.

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

  @switches [
    step: :integer,
    shuffles: :integer,
    seed: :integer,
    notional: :integer,
    source: :string,
    by_time: :boolean
  ]
  @history_database "trading_backtest_dev"

  @impl true
  def run(args) do
    {opts, dates} = OptionParser.parse!(args, strict: @switches)

    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started([:postgrex, :ecto_sql, :tzdata])

    {table, repo_opts} =
      case Keyword.get(opts, :source, "live") do
        "live" -> {"live_second_quotes", []}
        "history" -> {"second_quotes", [database: @history_database]}
        other -> Mix.raise("--source must be live or history, got #{other}")
      end

    {:ok, _} = TradingMicro.Repo.start_link([pool_size: 2] ++ repo_opts)

    {from, to} =
      case dates do
        [] -> Session.et_date(DateTime.utc_now()) |> then(&{&1, &1})
        [d] -> Date.from_iso8601!(d) |> then(&{&1, &1})
        [a, b] -> {Date.from_iso8601!(a), Date.from_iso8601!(b)}
      end

    symbols = Application.get_env(:trading_micro, :symbols, [])
    symbols = if table == "second_quotes", do: ~w(SPY QQQ), else: symbols

    {samples, mids} =
      Enum.flat_map_reduce(Date.range(from, to), %{}, fn date, mids ->
        series = Map.new(symbols, &{&1, Quotes.rth_series(&1, date, table)})

        mids =
          Enum.reduce(series, mids, fn {symbol, points}, acc ->
            day = for %{mid: mid} when is_float(mid) <- points, do: mid
            Map.update(acc, symbol, day, &(day ++ &1))
          end)

        {SignatureStudy.day_samples(date, series, Keyword.take(opts, [:step])), mids}
      end)

    costs =
      SignatureStudy.costs(symbols, from, to, mids, Keyword.get(opts, :notional, 100_000), table)

    eval_opts = Keyword.take(opts, [:shuffles, :seed])

    if opts[:by_time] do
      samples
      |> Enum.group_by(&SignatureStudy.time_bucket(&1.day, &1.t))
      |> Enum.sort()
      |> Enum.each(fn {{_, label}, group} ->
        Mix.shell().info("== #{label} ET ==")

        Mix.shell().info(
          SignatureStudy.format(SignatureStudy.evaluate(group, eval_opts), from, to, costs)
        )
      end)
    else
      Mix.shell().info(
        SignatureStudy.format(SignatureStudy.evaluate(samples, eval_opts), from, to, costs)
      )
    end
  end
end
