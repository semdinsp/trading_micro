defmodule TradingMicro.StatusExtensionTest do
  use TradingMicro.DataCase, async: true

  import TradingMicro.Fixtures

  alias TradingMicro.Quotes
  alias TradingMicro.StatusExtension

  test "reports flat, per-symbol keys" do
    Quotes.insert_rows([
      row("SPY", DateTime.utc_now() |> DateTime.add(-5) |> DateTime.truncate(:second))
    ])

    metrics = StatusExtension.extra_metrics()

    assert metrics.hub_connected == false
    assert metrics.spy_rows_last_minute == 1
    assert metrics.qqq_rows_last_minute == 0
    assert metrics.spy_gap_open == false
    assert Map.has_key?(metrics, :spy_last_message_age_s)
    refute Enum.any?(Map.values(metrics), &is_map/1)
  end
end
