defmodule TradingMicro.StatusExtension do
  @moduledoc """
  Adds recorder health to app_status's `/status` report: hub connection,
  and per symbol the rows written in the last minute, the age of the last
  message, and whether an RTH quote gap is open. Flat keys, so every value
  is also a Prometheus gauge on `/status/metrics`.
  """

  @behaviour AppStatus.Extension

  alias TradingMicro.Health

  @impl true
  def extra_metrics do
    health = Health.snapshot()

    Enum.reduce(health.symbols, %{hub_connected: health.hub_connected}, fn {symbol, s}, acc ->
      prefix = String.downcase(symbol)

      acc
      |> Map.put(:"#{prefix}_rows_last_minute", s.rows_last_minute)
      |> Map.put(:"#{prefix}_last_message_age_s", s.last_message_age_s)
      |> Map.put(:"#{prefix}_gap_open", s.gap_open)
    end)
  end
end
