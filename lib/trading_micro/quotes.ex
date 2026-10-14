defmodule TradingMicro.Quotes do
  @moduledoc """
  Reads and writes `live_second_quotes`. See
  `TradingMicro.Quotes.SecondQuote` for the columns.
  """

  import Ecto.Query

  alias TradingMicro.Quotes.SecondQuote
  alias TradingMicro.Repo
  alias TradingMicro.Session

  # Postgres caps a statement at 65_535 parameters; a row has 15 columns.
  @chunk 2_000

  @doc """
  Inserts closed-second rows. A row for an existing `(symbol, ts)` replaces
  it, so retrying a batch after a partial failure is safe. Returns the
  number of rows written.
  """
  @spec insert_rows([map()]) :: non_neg_integer()
  def insert_rows([]), do: 0

  def insert_rows(rows) do
    rows
    |> Enum.chunk_every(@chunk)
    |> Enum.reduce(0, fn chunk, acc ->
      {count, _} =
        Repo.insert_all(SecondQuote, chunk,
          on_conflict: {:replace_all_except, [:symbol, :ts]},
          conflict_target: [:symbol, :ts]
        )

      acc + count
    end)
  end

  @doc "Rows per symbol with `ts` in the last `seconds` before `now`."
  @spec rows_since(DateTime.t(), pos_integer()) :: %{String.t() => non_neg_integer()}
  def rows_since(%DateTime{} = now, seconds) do
    since = DateTime.add(now, -seconds, :second)

    from(q in SecondQuote,
      where: q.ts >= ^since,
      group_by: q.symbol,
      select: {q.symbol, count()}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc "The newest `limit` rows for `symbol`, newest first."
  @spec recent(String.t(), pos_integer()) :: [SecondQuote.t()]
  def recent(symbol, limit) do
    from(q in SecondQuote, where: q.symbol == ^symbol, order_by: [desc: q.ts], limit: ^limit)
    |> Repo.all()
  end

  @doc """
  The "done means" session report for `symbols` on ET `date`:

    * `rows` — every recorded second;
    * `rth_rows`, `rth_seconds` and `rth_quote_coverage` — share of RTH
      seconds with at least one quote;
    * `median_spread_bps` — over RTH seconds with a usable quote;
    * `largest_rth_gap_s` and `largest_rth_gap_at` — the longest run of RTH
      seconds without a quote, including the open and close edges.
  """
  @spec session_report(Date.t(), [String.t()]) :: [map()]
  def session_report(%Date{} = date, symbols) do
    day = Session.day(date)
    Enum.map(symbols, &symbol_report(&1, day))
  end

  defp symbol_report(symbol, %{window: nil} = day) do
    %{symbol: symbol, date: day.date, trading_day: false}
  end

  defp symbol_report(symbol, %{window: {w_open, w_close}, rth: {open, close}} = day) do
    rows =
      Repo.aggregate(
        from(q in SecondQuote,
          where: q.symbol == ^symbol and q.ts >= ^w_open and q.ts < ^w_close
        ),
        :count
      )

    rth = from(q in SecondQuote, where: q.symbol == ^symbol and q.ts >= ^open and q.ts < ^close)
    rth_rows = Repo.aggregate(rth, :count)

    quoted_ts =
      from(q in rth, where: q.quote_updates > 0, order_by: q.ts, select: q.ts)
      |> Repo.all()

    median_spread_bps =
      from(q in rth,
        where: q.quote_updates > 0 and q.ask > q.bid and q.bid > 0,
        select:
          fragment(
            "percentile_cont(0.5) WITHIN GROUP (ORDER BY ((? - ?) / ((? + ?) / 2)) * 10000)",
            q.ask,
            q.bid,
            q.ask,
            q.bid
          )
      )
      |> Repo.one()

    rth_seconds = DateTime.diff(close, open)
    {gap_s, gap_at} = largest_gap(quoted_ts, open, close)

    %{
      symbol: symbol,
      date: day.date,
      trading_day: true,
      rows: rows,
      rth_rows: rth_rows,
      rth_seconds: rth_seconds,
      rth_quote_coverage: length(quoted_ts) / rth_seconds,
      median_spread_bps: median_spread_bps && to_float(median_spread_bps),
      largest_rth_gap_s: gap_s,
      largest_rth_gap_at: gap_at
    }
  end

  @doc """
  Longest run of seconds in `[open, close)` with no entry in `quoted`
  (sorted). Returns `{seconds, start}`; `{0, nil}` when every second has one.
  """
  @spec largest_gap([DateTime.t()], DateTime.t(), DateTime.t()) ::
          {non_neg_integer(), DateTime.t() | nil}
  def largest_gap(quoted, open, close) do
    # Sentinels one second either side make the edges count as gaps too.
    points = [DateTime.add(open, -1)] ++ quoted ++ [close]

    points
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce({0, nil}, fn [a, b], {best, best_at} ->
      missing = DateTime.diff(b, a) - 1

      if missing > best, do: {missing, DateTime.add(a, 1)}, else: {best, best_at}
    end)
  end

  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(n) when is_number(n), do: n * 1.0
end
