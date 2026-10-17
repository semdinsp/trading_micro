defmodule Mix.Tasks.Micro.Open30 do
  @shortdoc "Scores 09:30–10:00 Lévy areas against SPY/QQQ rest-of-day returns"

  @moduledoc """
  Research over Polygon 1-minute bars: do Lévy areas of the first 30
  minutes of RTH predict the rest of the day beyond the 30-minute return?
  See `TradingMicro.Open30Study` for the features, targets and tests.

      mix micro.open30                          # 2024-01-02 to yesterday (ET)
      mix micro.open30 2024-06-01 2026-10-16
      mix micro.open30 --train 0.7

  Bars for SPY, QQQ and I:VIX come from trading_hub's
  `TradingHub.Polygon.Handler.fetch_aggregates_sync/5`, a month at a
  time over `:erpc` (the hub rate-limits Polygon to one call per 12s, so
  an uncached two-year run takes about 20 minutes; the hub caches settled
  ranges for 24 hours). The regime split reads `regime_sessions` from
  trading_signal (`TradingSignal.Regime.sessions_between/2`) on the same
  host. Without trading_signal it runs without the split.

  NYSE TICK is not on Polygon, so the (SPY, TICK) pair isn't computed.

  Read-only. It starts a distributed node under a unique name, not the
  Repo or the recorder, so it is safe to run next to a live server.
  """

  use Mix.Task

  alias TradingMicro.Open30Study
  alias TradingMicro.Session

  @switches [train: :float]
  @symbols [{"SPY", "SPY"}, {"QQQ", "QQQ"}, {"VIX", "I:VIX"}]
  @default_from ~D[2024-01-02]

  @impl true
  def run(args) do
    {opts, dates} = OptionParser.parse!(args, strict: @switches)

    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:tzdata)

    hub = Application.fetch_env!(:trading_micro, :hub_node)
    [_, host] = hub |> Atom.to_string() |> String.split("@")
    signal = :"trading_signal@#{host}"

    {:ok, _} =
      Node.start(:"micro_open30_#{System.unique_integer([:positive])}@#{host}", :longnames)

    unless Node.connect(hub), do: Mix.raise("Can't reach #{hub}; is trading_hub running?")

    {from, to} =
      case dates do
        [] -> {@default_from, Date.add(Session.et_date(DateTime.utc_now()), -1)}
        [a, b] -> {Date.from_iso8601!(a), Date.from_iso8601!(b)}
      end

    {sessions, skips, notes} = load_sessions(hub, from, to)
    {regimes, regime_note} = regimes(signal, from, to)

    notes =
      [
        "Skipped: #{inspect(skips)}.",
        "NYSE TICK: not available from Polygon; the (SPY, TICK) pair is skipped.",
        regime_note | notes
      ]

    result = Open30Study.evaluate(sessions, regimes, Keyword.take(opts, [:train]))
    Mix.shell().info(Open30Study.format(result, notes))
  end

  # Month by month, so at most one month of raw bars is held at a time.
  defp load_sessions(hub, from, to) do
    from
    |> months(to)
    |> Enum.reduce({[], %{}, []}, fn {m_from, m_to}, {sessions, skips, notes} ->
      Mix.shell().info("Fetching #{m_from}..#{m_to}")

      {index, notes} =
        Enum.reduce(@symbols, {%{}, notes}, fn {key, ticker}, {index, notes} ->
          case fetch(hub, ticker, m_from, m_to) do
            {:ok, bars} ->
              {Map.put(index, key, Map.new(bars, &{&1.timestamp, &1})), notes}

            {:error, reason} ->
              {index, ["#{ticker} #{m_from}..#{m_to}: #{inspect(reason)}" | notes]}
          end
        end)

      Date.range(m_from, m_to)
      |> Enum.reduce({sessions, skips, notes}, fn date, {sessions, skips, notes} ->
        case Session.day(date) do
          %{rth: nil} ->
            {sessions, skips, notes}

          %{rth: {open, close}} ->
            case Open30Study.session(date, open, close, index) do
              {:ok, s} -> {[s | sessions], skips, notes}
              {:skip, why} -> {sessions, Map.update(skips, why, 1, &(&1 + 1)), notes}
            end
        end
      end)
    end)
    |> then(fn {sessions, skips, notes} ->
      {Enum.reverse(sessions), skips, Enum.reverse(notes)}
    end)
  end

  defp months(from, to) do
    Stream.unfold(Date.beginning_of_month(from), fn m ->
      if Date.compare(m, to) == :gt, do: nil, else: {m, Date.shift(m, month: 1)}
    end)
    |> Enum.map(fn m ->
      {Enum.max([m, from], Date), Enum.min([Date.end_of_month(m), to], Date)}
    end)
  end

  defp fetch(hub, ticker, from, to) do
    :erpc.call(
      hub,
      TradingHub.Polygon.Handler,
      :fetch_aggregates_sync,
      [ticker, "minute", 1, Date.to_iso8601(from), Date.to_iso8601(to)],
      :timer.minutes(5)
    )
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  # %{session_date => previous session's %{vol:, trend:}}.
  defp regimes(signal, from, to) do
    rows =
      :erpc.call(
        signal,
        TradingSignal.Regime,
        :sessions_between,
        [Date.add(from, -10), to],
        :timer.seconds(30)
      )

    map =
      rows
      |> Enum.chunk_every(2, 1, :discard)
      |> Map.new(fn [prev, cur] ->
        {cur.session_date, %{vol: prev.vol_state, trend: prev.trend_state}}
      end)

    {map,
     "Regimes: #{map_size(map)} sessions labelled from trading_signal's regime_sessions (previous session's label)."}
  catch
    kind, reason -> {%{}, "Regimes: unavailable (#{inspect({kind, reason})}); no regime split."}
  end
end
