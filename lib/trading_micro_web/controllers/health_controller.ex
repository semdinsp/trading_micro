defmodule TradingMicroWeb.HealthController do
  use TradingMicroWeb, :controller

  alias TradingMicro.Health

  @doc """
  Always 200 while the app is up, so a port check succeeds; recorder health
  is in the body's `status` (`ok` | `degraded` | `disabled`) and per-symbol
  detail. See `TradingMicro.Health`.
  """
  def show(conn, _params) do
    json(conn, Map.put(Health.snapshot(), :app, "trading_micro"))
  end
end
