defmodule TradingMicro.Recorder.SymbolState do
  @moduledoc """
  The pure fold behind one symbol's recorder: quotes and trades in, closed
  per-second rows out. `TradingMicro.Recorder.Worker` owns one of these and
  does the I/O around it.

  ## Seconds and lateness

  A message lands in the second of its own SIP timestamp, not of its
  arrival. `close/3` closes every second that ended at least `settle_ms`
  ago and hands back its row. A message for a second that is already
  closed is counted in `late_dropped` and otherwise ignored, so a row is
  written once and never rewritten.

  Messages outside 04:00–20:00 ET on a trading day are counted in
  `outside_window` and not recorded (see `TradingMicro.Session`).

  ## State that crosses seconds

  The latest quote is kept regardless of which second it fell in, or
  whether it was recorded at all, because it is the prevailing book: the
  next quote's OFI is differenced against it, and the next trade is signed
  against it. It is never written into a later second's row.

  ## Gaps

  `check_gap/3` tracks silence: no quote received for `threshold_s`
  seconds during regular hours opens a gap, and the next quote closes it.
  It reports the transition once each way so the caller can log loudly
  without repeating itself every flush.
  """

  alias TradingMicro.Microstructure
  alias TradingMicro.Session

  @zero Decimal.new(0)

  # A previous quote or trade older than this (by SIP time) is not a usable
  # reference: differencing against it would book a whole overnight or
  # outage book change as one second's OFI, and tick-rule against a stale
  # price. Liquid ETFs quote many times a second, so 5s of silence is a
  # break, not a pause.
  @reference_max_age_ms 5_000

  defstruct [
    :symbol,
    :quote,
    :quote_ts,
    :last_trade_price,
    :last_trade_ts,
    :last_side,
    :closed_through,
    :last_quote_at,
    :last_message_at,
    :watch_since,
    :gap_since,
    buckets: %{},
    days: %{},
    late_dropped: 0,
    outside_window: 0,
    quotes_seen: 0,
    trades_seen: 0,
    rows_closed: 0
  ]

  @type t :: %__MODULE__{}

  @doc "Fresh state; `now` starts the gap clock, so a feed that never delivers still alarms."
  @spec new(String.t(), DateTime.t()) :: t()
  def new(symbol, %DateTime{} = now), do: %__MODULE__{symbol: symbol, watch_since: now}

  @doc """
  Folds one quote (`data` from a hub `:ws_quote` message). `received_at` is
  wall-clock arrival, used for health and gaps; the bucket comes from
  `data.timestamp`.
  """
  @spec apply_quote(t(), map(), DateTime.t()) :: t()
  def apply_quote(state, %{timestamp: %DateTime{} = ts} = data, %DateTime{} = received_at) do
    quote = %{
      bid: Map.get(data, :bid),
      ask: Map.get(data, :ask),
      bid_size: Map.get(data, :bid_size),
      ask_size: Map.get(data, :ask_size)
    }

    ofi = Microstructure.ofi_contribution(fresh(state.quote, state.quote_ts, ts), quote)

    state = %{
      state
      | quote: quote,
        quote_ts: ts,
        quotes_seen: state.quotes_seen + 1,
        last_message_at: received_at
    }

    with_bucket(state, ts, fn state -> %{state | last_quote_at: received_at} end, fn bucket ->
      %{
        bucket
        | bid: quote.bid,
          ask: quote.ask,
          bid_size: quote.bid_size,
          ask_size: quote.ask_size,
          quote_updates: bucket.quote_updates + 1,
          ofi: add_ofi(bucket.ofi, ofi)
      }
    end)
  end

  def apply_quote(state, _data, _received_at), do: state

  @doc """
  Folds one trade (`data` from a hub `:ws_trade` message). Prints whose
  conditions exclude them from volume (`updates_volume: false`) are
  skipped entirely; a missing flag means the hub's condition table had
  not loaded, which it documents as "counts".
  """
  @spec apply_trade(t(), map(), DateTime.t()) :: t()
  def apply_trade(
        state,
        %{timestamp: %DateTime{} = ts, last: %Decimal{} = price} = data,
        received_at
      ) do
    if Map.get(data, :updates_volume, true) == false do
      state
    else
      last_price = fresh(state.last_trade_price, state.last_trade_ts, ts)

      side =
        Microstructure.trade_side(
          price,
          fresh(state.quote, state.quote_ts, ts),
          last_price,
          last_price && state.last_side
        )

      size = Map.get(data, :size)

      state = %{
        state
        | last_trade_price: price,
          last_trade_ts: ts,
          last_side: if(side == :unknown, do: state.last_side, else: side),
          trades_seen: state.trades_seen + 1,
          last_message_at: received_at
      }

      with_bucket(state, ts, & &1, fn bucket ->
        bucket
        |> Map.update!(:trade_count, &(&1 + 1))
        |> add_volume(side, size)
      end)
    end
  end

  def apply_trade(state, _data, _received_at), do: state

  @doc """
  Closes every open second that ended at least `settle_ms` before `now`.
  Returns the rows, oldest first, ready for `Repo.insert_all/3`.
  """
  @spec close(t(), DateTime.t(), non_neg_integer()) :: {[map()], t()}
  def close(state, %DateTime{} = now, settle_ms) do
    # Second S covers [S, S+1); it closes once (S+1)*1000 + settle <= now.
    cutoff = div(DateTime.to_unix(now, :millisecond) - settle_ms, 1000) - 1

    {closing, open} = Map.split_with(state.buckets, fn {sec, _} -> sec <= cutoff end)

    rows =
      closing
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {sec, bucket} -> to_row(state.symbol, sec, bucket) end)

    closed_through = max(state.closed_through || cutoff, cutoff)

    {rows,
     %{
       state
       | buckets: open,
         closed_through: closed_through,
         rows_closed: state.rows_closed + length(rows),
         days: prune_days(state.days, now)
     }}
  end

  @doc """
  Closes every open second regardless of settle or clock, for shutdown:
  nothing received is left unwritten.
  """
  @spec close_all(t(), DateTime.t()) :: {[map()], t()}
  def close_all(state, %DateTime{} = now) do
    # close/3 with settle 0 closes seconds before `at`'s second, so pick a
    # second past both now and the newest bucket (which can be ahead of the
    # local clock).
    newest = state.buckets |> Map.keys() |> Enum.max(fn -> 0 end)
    at = max(newest, DateTime.to_unix(now)) + 1
    {rows, state} = close(state, DateTime.from_unix!(at), 0)
    {rows, %{state | days: prune_days(state.days, now)}}
  end

  @doc """
  Updates gap tracking at `now`. Returns `{event, state}` where `event` is
  `{:gap_opened, silent_seconds}`, `{:gap_closed, gap_seconds}` or `:none`.
  """
  @spec check_gap(t(), DateTime.t(), pos_integer()) ::
          {{:gap_opened, number()} | {:gap_closed, number()} | :none, t()}
  def check_gap(state, %DateTime{} = now, threshold_s) do
    reference = state.last_quote_at || state.watch_since
    silent = DateTime.diff(now, reference, :millisecond) / 1000

    cond do
      state.gap_since && reference && DateTime.compare(reference, state.gap_since) == :gt ->
        {{:gap_closed, DateTime.diff(reference, state.gap_since, :millisecond) / 1000},
         %{state | gap_since: nil}}

      is_nil(state.gap_since) and silent > threshold_s and Session.rth_now?(now) ->
        {{:gap_opened, silent}, %{state | gap_since: reference}}

      true ->
        {:none, state}
    end
  end

  @doc "Whether a gap is currently open."
  @spec gap_open?(t()) :: boolean()
  def gap_open?(state), do: not is_nil(state.gap_since)

  # The reference value when it is recent enough to difference against.
  defp fresh(_value, nil, _ts), do: nil

  defp fresh(value, %DateTime{} = at, %DateTime{} = ts) do
    if abs(DateTime.diff(ts, at, :millisecond)) <= @reference_max_age_ms, do: value
  end

  # -- buckets ---------------------------------------------------------------

  # Runs `on_recorded` on the state and `fun` on ts's bucket when ts is
  # recordable; counts and skips it otherwise.
  defp with_bucket(state, ts, on_recorded, fun) do
    sec = DateTime.to_unix(ts)
    {day, state} = day_for(state, ts)

    cond do
      state.closed_through && sec <= state.closed_through ->
        %{state | late_dropped: state.late_dropped + 1}

      not Session.in_window?(day, ts) ->
        %{state | outside_window: state.outside_window + 1}

      true ->
        bucket = Map.get_lazy(state.buckets, sec, fn -> new_bucket(Session.rth?(day, ts)) end)
        state = on_recorded.(state)
        %{state | buckets: Map.put(state.buckets, sec, fun.(bucket))}
    end
  end

  defp new_bucket(rth?) do
    %{
      bid: nil,
      ask: nil,
      bid_size: nil,
      ask_size: nil,
      quote_updates: 0,
      ofi: nil,
      buy_volume: @zero,
      sell_volume: @zero,
      unknown_volume: @zero,
      trade_count: 0,
      rth: rth?
    }
  end

  defp add_ofi(acc, nil), do: acc
  defp add_ofi(nil, contribution), do: contribution
  defp add_ofi(acc, contribution), do: Decimal.add(acc, contribution)

  defp add_volume(bucket, _side, nil), do: bucket

  defp add_volume(bucket, side, %Decimal{} = size) do
    key =
      case side do
        :buy -> :buy_volume
        :sell -> :sell_volume
        :unknown -> :unknown_volume
      end

    Map.update!(bucket, key, &Decimal.add(&1, size))
  end

  defp to_row(symbol, sec, bucket) do
    bucket
    |> Map.merge(%{
      symbol: symbol,
      ts: DateTime.from_unix!(sec),
      mid: Microstructure.raw_mid(bucket.bid, bucket.ask)
    })
  end

  # -- day cache -------------------------------------------------------------

  defp day_for(state, ts) do
    date = Session.et_date(ts)

    case state.days do
      %{^date => day} ->
        {day, state}

      days ->
        day = Session.day(date)
        {day, %{state | days: Map.put(days, date, day)}}
    end
  end

  # Keeps yesterday and today; anything older can't receive an on-time message.
  defp prune_days(days, now) do
    keep_from = now |> Session.et_date() |> Date.add(-1)
    Map.filter(days, fn {date, _} -> Date.compare(date, keep_from) != :lt end)
  end
end
