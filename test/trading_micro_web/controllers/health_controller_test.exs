defmodule TradingMicroWeb.HealthControllerTest do
  use TradingMicroWeb.ConnCase, async: true

  test "GET /health answers 200 with recorder health per symbol", %{conn: conn} do
    body = conn |> get(~p"/health") |> json_response(200)

    assert body["app"] == "trading_micro"
    # The recorder is disabled in test.
    assert body["status"] == "disabled"
    assert body["hub_connected"] == false
    assert Map.keys(body["symbols"]) |> Enum.sort() == ["QQQ", "SPY"]
    assert body["symbols"]["SPY"]["rows_last_minute"] == 0
  end

  test "GET /status is served by app_status", %{conn: conn} do
    body = conn |> get("/status") |> json_response(200)
    assert body["app"] == "trading_micro"
  end
end
