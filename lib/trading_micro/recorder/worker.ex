defmodule TradingMicro.Recorder.Worker do
  @moduledoc """
  Records one symbol: listens on the hub's Polygon topic, folds every quote
  and trade into `TradingMicro.Recorder.SymbolState`, and every
  `flush_interval_ms` writes the seconds that have closed.

  ## Dispatch on `metadata.data_type`, never on key presence

  Trades and quotes share `TradingContract.Topics.prices_polygon/1` and
  carry disjoint payloads (`:ws_trade` has `last`, `:ws_quote` has
  `bid`/`ask`). A clause matching `%{data: %{last: _}}` would silently drop
  every quote. Per-minute aggregates go to `volume_polygon/1`, which this
  module does not subscribe to: it builds volume from the trades.

  ## Failure handling

  A failed insert keeps its rows and retries them on the next flush,
  capped at `@max_pending` rows (about 17 minutes of one busy symbol) so a
  long database outage cannot grow memory without bound; overflow is
  dropped oldest first and logged. A gap in RTH quotes past
  `gap_alarm_seconds` is logged at error level; every gap past
  `gap_warn_seconds` is logged as a warning when it closes, with the count
  of late messages that tells delayed data from missing data.

  On shutdown every open second is written, settled or not, including the
  current one.
  """

  use GenServer

  require Logger

  alias TradingMicro.Quotes
  alias TradingMicro.Recorder.SymbolState

  @max_pending 1_000

  @doc "Topic on `TradingMicro.PubSub` carrying each worker's stats after a flush."
  def stats_topic, do: "micro:recorder_stats"

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :symbol)},
      start: {__MODULE__, :start_link, [opts]},
      # Room for terminate/2's final write to outlast a slow DB checkout.
      shutdown: 20_000
    }
  end

  def start_link(opts) do
    symbol = Keyword.fetch!(opts, :symbol)
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, via(symbol)))
  end

  defp via(symbol), do: {:via, Registry, {TradingMicro.Recorder.Registry, symbol}}

  @doc "The live stats for `symbol`'s worker, or `nil` when none is running."
  @spec stats(String.t() | GenServer.server()) :: map() | nil
  def stats(symbol) when is_binary(symbol) do
    stats(via(symbol))
  end

  # app_status polls from its own application, which can start before this
  # app's Registry exists; a missing registry raises rather than exits.
  # Short timeout: a worker blocked in a slow insert must not stall the
  # dashboard or /health; they show "no stats" instead.
  def stats(server) do
    GenServer.call(server, :stats, 1_000)
  rescue
    ArgumentError -> nil
  catch
    :exit, _ -> nil
  end

  @doc "Runs a flush now (tests, and shutdown)."
  def flush(server), do: GenServer.call(server, :flush)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    symbol = Keyword.fetch!(opts, :symbol)
    config = Application.get_env(:trading_micro, TradingMicro.Recorder, [])
    clock = Keyword.get(opts, :clock, &DateTime.utc_now/0)

    if Keyword.get(opts, :subscribe?, true) do
      Phoenix.PubSub.subscribe(TradingHub.PubSub, TradingContract.Topics.prices_polygon(symbol))
    end

    state = %{
      symbol: symbol,
      clock: clock,
      flush_interval_ms: opt(opts, config, :flush_interval_ms, 5_000),
      settle_ms: opt(opts, config, :settle_ms, 2_000),
      gap_warn_seconds: opt(opts, config, :gap_warn_seconds, 15),
      gap_alarm_seconds: opt(opts, config, :gap_alarm_seconds, 60),
      auto_flush?: Keyword.get(opts, :auto_flush?, true),
      fold: SymbolState.new(symbol, clock.()),
      pending: [],
      rows_written: 0,
      rows_dropped: 0,
      last_flush_at: nil,
      last_flush_error: nil
    }

    schedule(state)
    {:ok, state}
  end

  defp opt(opts, config, key, default),
    do: Keyword.get(opts, key, Keyword.get(config, key, default))

  @impl true
  def handle_info(
        %{symbol: symbol, metadata: %{data_type: data_type}, data: %{} = data},
        %{symbol: symbol} = state
      ) do
    fold =
      case data_type do
        :ws_quote -> SymbolState.apply_quote(state.fold, data, state.clock.())
        :ws_trade -> SymbolState.apply_trade(state.fold, data, state.clock.())
        _ -> state.fold
      end

    {:noreply, %{state | fold: fold}}
  end

  def handle_info(:flush, state) do
    state = do_flush(state, state.settle_ms)
    schedule(state)
    {:noreply, state}
  end

  # Another symbol, an aggregate, or a shape added later: ignored.
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_call(:stats, _from, state), do: {:reply, build_stats(state), state}

  def handle_call(:flush, _from, state) do
    state = do_flush(state, state.settle_ms)
    {:reply, build_stats(state), state}
  end

  @impl true
  def terminate(_reason, state) do
    {rows, fold} = SymbolState.close_all(state.fold, state.clock.())
    write(%{state | fold: fold, pending: state.pending ++ rows}, state.clock.())
    :ok
  end

  defp schedule(%{auto_flush?: true, flush_interval_ms: ms}),
    do: Process.send_after(self(), :flush, ms)

  defp schedule(_state), do: :ok

  defp do_flush(state, settle_ms) do
    now = state.clock.()
    {rows, fold} = SymbolState.close(state.fold, now, settle_ms)
    state = write(%{state | fold: fold, pending: state.pending ++ rows}, now)
    state = check_gap(state, now)

    Phoenix.PubSub.broadcast(
      TradingMicro.PubSub,
      stats_topic(),
      {:recorder_stats, build_stats(state)}
    )

    state
  end

  defp write(%{pending: []} = state, now), do: %{state | last_flush_at: now}

  defp write(state, now) do
    count = Quotes.insert_rows(state.pending)

    %{
      state
      | pending: [],
        rows_written: state.rows_written + count,
        last_flush_at: now,
        last_flush_error: nil
    }
  rescue
    error ->
      Logger.error(
        "Recorder #{state.symbol}: insert of #{length(state.pending)} rows failed, " <>
          "will retry: #{Exception.message(error)}"
      )

      cap_pending(%{state | last_flush_error: Exception.message(error)})
  end

  defp cap_pending(%{pending: pending} = state) when length(pending) <= @max_pending, do: state

  defp cap_pending(state) do
    overflow = length(state.pending) - @max_pending

    Logger.error("Recorder #{state.symbol}: dropping #{overflow} unwritten rows (pending cap)")

    %{
      state
      | pending: Enum.drop(state.pending, overflow),
        rows_dropped: state.rows_dropped + overflow
    }
  end

  defp check_gap(state, now) do
    case SymbolState.check_gap(
           state.fold,
           now,
           state.gap_warn_seconds,
           state.gap_alarm_seconds
         ) do
      {{:gap_alarmed, silent}, fold} ->
        Logger.error(
          "Recorder #{state.symbol}: NO QUOTES for #{round(silent)}s during RTH. " <>
            "Data is not being recorded. Check trading_hub's Polygon feed and " <>
            "TradingMicro.HubSubscription.status/0."
        )

        %{state | fold: fold}

      {{:gap_closed, gap, late}, fold} ->
        Logger.warning(
          "Recorder #{state.symbol}: quotes resumed after a #{round(gap)}s gap; " <>
            "#{late} late messages dropped meanwhile " <>
            "(many: the feed stalled and delivered its backlog late; " <>
            "near zero: the data never arrived)"
        )

        %{state | fold: fold}

      {{:gap_opened, _silent}, fold} ->
        %{state | fold: fold}

      {:none, fold} ->
        %{state | fold: fold}
    end
  end

  defp build_stats(state) do
    fold = state.fold
    now = state.clock.()

    %{
      symbol: state.symbol,
      quotes_seen: fold.quotes_seen,
      trades_seen: fold.trades_seen,
      rows_written: state.rows_written,
      rows_dropped: state.rows_dropped,
      pending_rows: length(state.pending),
      open_seconds: map_size(fold.buckets),
      late_dropped: fold.late_dropped,
      outside_window: fold.outside_window,
      last_message_at: fold.last_message_at,
      last_message_age_s: age(now, fold.last_message_at),
      last_quote_at: fold.last_quote_at,
      last_quote_age_s: age(now, fold.last_quote_at),
      gap_open?: SymbolState.gap_open?(fold),
      quote: fold.quote,
      last_flush_at: state.last_flush_at,
      last_flush_error: state.last_flush_error
    }
  end

  defp age(_now, nil), do: nil
  defp age(now, at), do: DateTime.diff(now, at, :millisecond) / 1000
end
