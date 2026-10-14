defmodule Mix.Tasks.Micro.Report do
  @shortdoc "Prints the recorder's session report for an ET date"

  @moduledoc """
  The "done means" report for one recorded session:

      mix micro.report              # today (ET)
      mix micro.report 2026-10-14

  Per symbol: rows, RTH quote coverage, median RTH spread in bps, and the
  largest RTH gap. Read-only; it starts the Repo, not the recorder, so it
  is safe to run next to a live server.
  """

  use Mix.Task

  alias TradingMicro.Quotes
  alias TradingMicro.Session

  @impl true
  def run(args) do
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started([:postgrex, :ecto_sql, :tzdata])
    {:ok, _} = TradingMicro.Repo.start_link(pool_size: 2)

    date =
      case args do
        [iso] -> Date.from_iso8601!(iso)
        [] -> Session.et_date(DateTime.utc_now())
      end

    symbols = Application.get_env(:trading_micro, :symbols, [])

    Mix.shell().info("trading_micro session report — #{date} (ET)\n")

    for report <- Quotes.session_report(date, symbols) do
      Mix.shell().info(format(report))
    end
  end

  defp format(%{trading_day: false} = r), do: "#{r.symbol}: not a trading day"

  defp format(r) do
    """
    #{r.symbol}
      rows (04:00-20:00 ET)   #{r.rows}
      RTH rows                #{r.rth_rows} of #{r.rth_seconds} seconds
      RTH quote coverage      #{pct(r.rth_quote_coverage)}
      median RTH spread       #{bps(r.median_spread_bps)}
      largest RTH gap         #{r.largest_rth_gap_s}s#{gap_at(r.largest_rth_gap_at)}
    """
  end

  defp pct(x), do: :erlang.float_to_binary(x * 100, decimals: 2) <> "%"
  defp bps(nil), do: "n/a"
  defp bps(x), do: :erlang.float_to_binary(x, decimals: 3) <> " bps"

  defp gap_at(nil), do: ""

  defp gap_at(at) do
    " from " <>
      (at |> DateTime.shift_zone!("America/New_York") |> Calendar.strftime("%H:%M:%S ET"))
  end
end
