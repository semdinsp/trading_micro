defmodule TradingMicro.HubSubscription do
  @moduledoc """
  Connects this node to `trading_hub` and holds one Polygon subscription
  per configured symbol on the hub's `TradingHub.Polygon.WebSocketClient`.

  Listening (`TradingMicro.Recorder.Worker`) and subscribing (here) are
  separate on purpose, as in trading_system's `PolygonRelay` /
  `PolygonSubscription` pair: listening alone yields a topic nobody
  publishes to if no other app happens to have asked for the symbol.

  ## One caller tag for the app

  The hub refcounts by `{symbol, caller}`. This module subscribes each
  symbol exactly once under `"trading_micro:recorder"`, so SPY/QQQ keep
  flowing for the recorder even when trading_system releases its own hold,
  and re-subscribing on recovery is an idempotent no-op on the hub side.

  ## Recovery

  Re-subscribes on `{:nodeup, hub}` (hub restart) and on the hub's
  `system:health` `:resubscribe` broadcast (Polygon re-auth, hub node
  still up). Neither alone covers both cases.

  ## Silent failure modes this guards against

    * **A rejected subscribe looks like success.** `subscribe_symbol/2` is a
      cast and returns `:ok` regardless. Polygon's rejection arrives later
      as a `:subscribe_rejected` health broadcast, which flips the symbol
      to `:rejected` here and is logged at error level.
    * **Accepted is not flowing.** Every `@verify_ms` this checks the hub's
      `get_subscriptions/0` lists each symbol, and logs when one is missing.
      Whether data actually arrives is the recorder's gap alarm's job.

  No compile-time dependency on trading_hub: every call is `:erpc` by
  module name, and broadcasts are matched as plain maps.
  """

  use GenServer

  require Logger

  @caller_tag "trading_micro:recorder"
  @hub_module TradingHub.Polygon.WebSocketClient
  @retry_ms 5_000
  @verify_ms 30_000

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The caller tag this app subscribes under."
  def caller_tag, do: @caller_tag

  @doc """
  `%{hub_node:, connected?:, symbols: %{symbol => %{state:, listed?:}}}`.
  `state` is `:pending | :subscribed | :rejected | :error`; `listed?` is the
  hub's last answer, `nil` before the first check.
  """
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    # Once, here: monitor_nodes/1 stacks, so calling it per reconnect would
    # deliver N copies of every nodeup.
    :net_kernel.monitor_nodes(true)
    Phoenix.PubSub.subscribe(TradingHub.PubSub, TradingContract.Topics.system_health())

    symbols = Keyword.fetch!(opts, :symbols)

    state = %{
      hub_node: Keyword.get(opts, :hub_node),
      rpc: Keyword.get(opts, :rpc, &default_rpc/3),
      connect: Keyword.get(opts, :connect, &Node.connect/1),
      connected?: false,
      symbols: Map.new(symbols, &{&1, %{state: :pending, listed?: nil}})
    }

    if state.hub_node, do: send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, Map.take(state, [:hub_node, :connected?, :symbols]), state}
  end

  @impl true
  def handle_info(:connect, state) do
    if state.connect.(state.hub_node) == true do
      Logger.info("HubSubscription: connected to #{state.hub_node}")
      send(self(), :verify)
      {:noreply, subscribe_all(%{state | connected?: true})}
    else
      Process.send_after(self(), :connect, @retry_ms)
      {:noreply, %{state | connected?: false}}
    end
  end

  def handle_info(:verify, %{connected?: true} = state) do
    Process.send_after(self(), :verify, @verify_ms)

    case state.rpc.(state.hub_node, :get_subscriptions, []) do
      listed when is_list(listed) ->
        {:noreply, mark_listed(state, listed)}

      other ->
        Logger.warning("HubSubscription: could not read hub subscriptions: #{inspect(other)}")
        {:noreply, state}
    end
  end

  def handle_info(:verify, state), do: {:noreply, state}

  def handle_info({:nodeup, node}, %{hub_node: node} = state) do
    Logger.info("HubSubscription: #{node} back up, re-subscribing")
    {:noreply, subscribe_all(%{state | connected?: true})}
  end

  def handle_info({:nodedown, node}, %{hub_node: node} = state) do
    Logger.error("HubSubscription: lost #{node}; recording stops until it returns")
    Process.send_after(self(), :connect, @retry_ms)
    {:noreply, %{state | connected?: false, symbols: reset(state.symbols)}}
  end

  def handle_info(%{type: :health, data: %{component: :polygon_websocket} = data}, state) do
    case data do
      %{action: :resubscribe} ->
        Logger.info("HubSubscription: polygon re-authed on the hub, re-subscribing")
        {:noreply, subscribe_all(state)}

      %{status: :subscribe_rejected, symbol: symbol} when is_map_key(state.symbols, symbol) ->
        Logger.error(
          "HubSubscription: polygon REJECTED #{symbol} (#{inspect(Map.get(data, :detail))}); " <>
            "nothing will be recorded for it until the next resubscribe"
        )

        {:noreply, put_symbol(state, symbol, :rejected)}

      _ ->
        {:noreply, state}
    end
  end

  # Required: system:health carries broadcasts for every component.
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{connected?: true} = state) do
    for {symbol, %{state: :subscribed}} <- state.symbols do
      state.rpc.(state.hub_node, :unsubscribe_symbol, [symbol, @caller_tag])
    end

    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp subscribe_all(state) do
    Enum.reduce(Map.keys(state.symbols), state, fn symbol, acc ->
      case acc.rpc.(acc.hub_node, :subscribe_symbol, [symbol, @caller_tag]) do
        :ok ->
          put_symbol(acc, symbol, :subscribed)

        other ->
          Logger.error("HubSubscription: subscribe #{symbol} failed: #{inspect(other)}")
          put_symbol(acc, symbol, :error)
      end
    end)
  end

  defp mark_listed(state, listed) do
    symbols =
      Map.new(state.symbols, fn {symbol, entry} ->
        listed? = symbol in listed

        if not listed? and entry.state == :subscribed do
          Logger.warning("HubSubscription: hub does not list #{symbol} as subscribed")
        end

        {symbol, %{entry | listed?: listed?}}
      end)

    %{state | symbols: symbols}
  end

  defp put_symbol(state, symbol, value) do
    %{state | symbols: Map.update!(state.symbols, symbol, &%{&1 | state: value})}
  end

  defp reset(symbols),
    do: Map.new(symbols, fn {s, _} -> {s, %{state: :pending, listed?: nil}} end)

  defp default_rpc(node, fun, args) do
    :erpc.call(node, @hub_module, fun, args, 10_000)
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
