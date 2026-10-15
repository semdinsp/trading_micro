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
  for the placebo (default 200, 0 to skip), `--seed` (default 1).

  Read-only. It starts the Repo, not the recorder, so it is safe to run
  next to a live server. Run it after the close: a day's last samples need
  five minutes of forward data.
  """

  use Mix.Task

  alias TradingMicro.Quotes
  alias TradingMicro.Session
  alias TradingMicro.SignatureStudy

  @switches [step: :integer, shuffles: :integer, seed: :integer]

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

    samples =
      Enum.flat_map(Date.range(from, to), fn date ->
        series = Map.new(symbols, &{&1, Quotes.rth_series(&1, date)})
        SignatureStudy.day_samples(date, series, Keyword.take(opts, [:step]))
      end)

    Mix.shell().info(
      SignatureStudy.format(
        SignatureStudy.evaluate(samples, Keyword.take(opts, [:shuffles, :seed])),
        from,
        to
      )
    )
  end
end
