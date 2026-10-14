defmodule TradingMicro.Health do
  @moduledoc """
  One snapshot of recorder health, shared by `GET /health`, app_status's
  `/status` and the dashboard so all three agree.

  `status` is `"ok"` when every symbol wrote a row in the last minute, or
  when it is outside the recording window and quiet is expected. It is
  `"degraded"` when the hub is unreachable, or during RTH when any symbol
  has an open gap or wrote nothing in the last minute. `"disabled"` when
  the recorder is switched off.
  """

  alias TradingMicro.HubSubscription
  alias TradingMicro.Quotes
  alias TradingMicro.Recorder
  alias TradingMicro.Recorder.Worker
  alias TradingMicro.Session

  @spec snapshot(DateTime.t()) :: map()
  def snapshot(now \\ DateTime.utc_now()) do
    rows = safe(fn -> Quotes.rows_since(now, 60) end, %{})
    hub = safe(fn -> HubSubscription.status() end, nil)
    rth? = Session.rth_now?(now)

    symbols =
      Map.new(Recorder.symbols(), fn symbol ->
        stats = Worker.stats(symbol) || %{}
        sub = hub && get_in(hub, [:symbols, symbol])

        {symbol,
         %{
           rows_last_minute: Map.get(rows, symbol, 0),
           last_message_age_s: Map.get(stats, :last_message_age_s),
           last_quote_age_s: Map.get(stats, :last_quote_age_s),
           gap_open: Map.get(stats, :gap_open?, false),
           subscription: sub && sub.state,
           hub_lists_symbol: sub && sub.listed?
         }}
      end)

    hub_connected = (hub && hub.connected?) || false

    %{
      status: status(Recorder.enabled?(), hub_connected, rth?, symbols),
      rth: rth?,
      hub_node: hub && hub.hub_node,
      hub_connected: hub_connected,
      symbols: symbols
    }
  end

  defp status(false, _hub, _rth?, _symbols), do: "disabled"
  defp status(true, false, _rth?, _symbols), do: "degraded"

  defp status(true, true, true, symbols) do
    bad? = Enum.any?(symbols, fn {_, s} -> s.gap_open or s.rows_last_minute == 0 end)
    if bad?, do: "degraded", else: "ok"
  end

  defp status(true, true, false, _symbols), do: "ok"

  defp safe(fun, default) do
    fun.()
  rescue
    _ -> default
  catch
    :exit, _ -> default
  end
end
