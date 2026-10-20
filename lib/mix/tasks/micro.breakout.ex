defmodule Mix.Tasks.Micro.Breakout do
  @shortdoc "Scores Donchian breakouts confirmed by order flow leading price"

  @moduledoc """
  Research over recorded RTH seconds: does a 20-minute Donchian breakout
  do better when the Lévy area of (cumulative OFI, mid) says order flow
  moved first in the breakout's direction? See `TradingMicro.BreakoutStudy`.

      mix micro.breakout                          # today (ET)
      mix micro.breakout 2026-10-14 2026-10-19
      mix micro.breakout 2026-09-08 2026-10-09 --source history

  Options: `--source live|history` as in `mix micro.signature`,
  `--shuffles` for the placebo (default 500), `--seed` (default 1),
  `--notional` order size in dollars for the cost (default 100000).

  Read-only. It starts the Repo, not the recorder, so it is safe to run
  next to a live server. Run it after the close.
  """

  use Mix.Task

  alias TradingMicro.BreakoutStudy
  alias TradingMicro.Quotes
  alias TradingMicro.Session
  alias TradingMicro.SignatureStudy

  @switches [shuffles: :integer, seed: :integer, notional: :integer, source: :string]
  @history_database "trading_backtest_dev"

  @impl true
  def run(args) do
    {opts, dates} = OptionParser.parse!(args, strict: @switches)

    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started([:postgrex, :ecto_sql, :tzdata])

    {table, repo_opts, symbols} =
      case Keyword.get(opts, :source, "live") do
        "live" ->
          {"live_second_quotes", [], Application.get_env(:trading_micro, :symbols, [])}

        "history" ->
          {"second_quotes", [database: @history_database], ~w(SPY QQQ)}

        other ->
          Mix.raise("--source must be live or history, got #{other}")
      end

    {:ok, _} = TradingMicro.Repo.start_link([pool_size: 2] ++ repo_opts)

    {from, to} =
      case dates do
        [] -> Session.et_date(DateTime.utc_now()) |> then(&{&1, &1})
        [d] -> Date.from_iso8601!(d) |> then(&{&1, &1})
        [a, b] -> {Date.from_iso8601!(a), Date.from_iso8601!(b)}
      end

    {breakouts, mids} =
      for date <- Date.range(from, to),
          symbol <- symbols,
          points = Quotes.rth_series(symbol, date, table),
          points != [],
          reduce: {%{}, %{}} do
        {acc, mids} ->
          day = for %{mid: mid} when is_float(mid) <- points, do: mid
          found = BreakoutStudy.day_breakouts(date, points)

          {Map.update(acc, symbol, found, &(&1 ++ found)),
           Map.update(mids, symbol, day, &(day ++ &1))}
      end

    costs =
      SignatureStudy.costs(symbols, from, to, mids, Keyword.get(opts, :notional, 100_000), table)

    eval_opts = Keyword.take(opts, [:shuffles, :seed])

    results =
      Map.new(breakouts, fn {symbol, bs} -> {symbol, BreakoutStudy.evaluate(bs, eval_opts)} end)

    days = for {_, bs} <- breakouts, b <- bs, uniq: true, do: b.day

    Mix.shell().info(
      BreakoutStudy.format(results, from, to, costs, [
        "Source: #{table}, #{length(days)} session(s) with breakouts."
      ])
    )
  end
end
