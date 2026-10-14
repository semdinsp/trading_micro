defmodule TradingMicro.Session do
  @moduledoc """
  Which seconds the recorder keeps, and which of those are regular hours.

  The recording window is 04:00–20:00 America/New_York on a US-equities
  trading day. Regular hours come from
  `TradingCore.Intraday.RegularSession.bounds/1`, so a holiday has none and
  a half day closes at its early close. Both are DST-correct because the
  conversion goes through the tz database.

  Everything here is pure. `TradingMicro.Recorder.SymbolState` caches one
  `day/1` result per ET date rather than recomputing it per message.
  """

  alias TradingCore.Intraday.RegularSession

  @timezone "America/New_York"
  @window_open ~T[04:00:00]
  @window_close ~T[20:00:00]

  @typedoc "One ET date's bounds, all UTC; `rth` is `nil` on a non-trading day."
  @type day :: %{
          date: Date.t(),
          window: {DateTime.t(), DateTime.t()} | nil,
          rth: {DateTime.t(), DateTime.t()} | nil
        }

  @doc "The ET calendar date `utc` falls on."
  @spec et_date(DateTime.t()) :: Date.t()
  def et_date(%DateTime{} = utc) do
    utc |> DateTime.shift_zone!(@timezone) |> DateTime.to_date()
  end

  @doc "Recording window and RTH bounds for an ET date."
  @spec day(Date.t()) :: day()
  def day(%Date{} = date) do
    case RegularSession.bounds(date) do
      {:ok, open, close} ->
        %{
          date: date,
          window: {utc(date, @window_open), utc(date, @window_close)},
          rth: {open, close}
        }

      :error ->
        %{date: date, window: nil, rth: nil}
    end
  end

  @doc "Whether `utc` is inside `day`'s recording window."
  @spec in_window?(day(), DateTime.t()) :: boolean()
  def in_window?(%{window: nil}, _utc), do: false
  def in_window?(%{window: {open, close}}, utc), do: within?(utc, open, close)

  @doc "Whether `utc` is inside `day`'s regular session."
  @spec rth?(day(), DateTime.t()) :: boolean()
  def rth?(%{rth: nil}, _utc), do: false
  def rth?(%{rth: {open, close}}, utc), do: within?(utc, open, close)

  @doc "`rth?/2` for any instant, looking the day up itself."
  @spec rth_now?(DateTime.t()) :: boolean()
  def rth_now?(%DateTime{} = utc), do: utc |> et_date() |> day() |> rth?(utc)

  # open <= t < close
  defp within?(t, open, close),
    do: DateTime.compare(t, open) != :lt and DateTime.compare(t, close) == :lt

  defp utc(date, time) do
    date |> DateTime.new!(time, @timezone) |> DateTime.shift_zone!("Etc/UTC")
  end
end
