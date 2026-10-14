defmodule TradingMicro.HubSubscriptionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias TradingMicro.HubSubscription

  @hub :"trading_hub@test-host"

  # A fake hub: every :erpc call is reported to the test process and
  # answered from `replies`.
  defp start(opts \\ []) do
    test = self()
    listed = Keyword.get(opts, :listed, ["SPY", "QQQ"])
    connect = Keyword.get(opts, :connect, fn _ -> true end)

    rpc = fn node, fun, args ->
      send(test, {:rpc, node, fun, args})

      case fun do
        :get_subscriptions -> listed
        _ -> :ok
      end
    end

    {:ok, pid} =
      GenServer.start_link(HubSubscription,
        name: nil,
        symbols: ["SPY", "QQQ"],
        hub_node: @hub,
        rpc: rpc,
        connect: connect
      )

    pid
  end

  test "connects and subscribes every symbol under the app's caller tag" do
    pid = start()
    tag = HubSubscription.caller_tag()

    assert_receive {:rpc, @hub, :subscribe_symbol, ["SPY", ^tag]}
    assert_receive {:rpc, @hub, :subscribe_symbol, ["QQQ", ^tag]}
    assert_receive {:rpc, @hub, :get_subscriptions, []}

    status = HubSubscription.status(pid)
    assert status.connected?
    assert status.symbols["SPY"] == %{state: :subscribed, listed?: true}
  end

  test "warns when the hub does not list a subscribed symbol" do
    log =
      capture_log(fn ->
        pid = start(listed: ["SPY"])
        assert_receive {:rpc, @hub, :get_subscriptions, []}
        assert HubSubscription.status(pid).symbols["QQQ"].listed? == false
      end)

    assert log =~ "hub does not list QQQ"
  end

  test "an unreachable hub is retried, not subscribed" do
    pid = start(connect: fn _ -> false end)

    refute_receive {:rpc, _, :subscribe_symbol, _}, 50
    refute HubSubscription.status(pid).connected?
  end

  test "re-subscribes when the hub node comes back" do
    pid = start()
    assert_receive {:rpc, @hub, :subscribe_symbol, ["QQQ", _]}

    capture_log(fn ->
      send(pid, {:nodedown, @hub})
      assert HubSubscription.status(pid).symbols["SPY"].state == :pending

      send(pid, {:nodeup, @hub})
      assert_receive {:rpc, @hub, :subscribe_symbol, ["SPY", _]}
      assert HubSubscription.status(pid).symbols["SPY"].state == :subscribed
    end)
  end

  test "re-subscribes on the hub's polygon :resubscribe health broadcast" do
    pid = start()
    assert_receive {:rpc, @hub, :subscribe_symbol, ["QQQ", _]}

    Phoenix.PubSub.broadcast(TradingHub.PubSub, TradingContract.Topics.system_health(), %{
      type: :health,
      data: %{component: :polygon_websocket, action: :resubscribe}
    })

    assert_receive {:rpc, @hub, :subscribe_symbol, ["SPY", _]}
    assert HubSubscription.status(pid).connected?
  end

  test "a polygon rejection marks the symbol rejected and logs an error" do
    pid = start()
    assert_receive {:rpc, @hub, :subscribe_symbol, ["QQQ", _]}

    log =
      capture_log(fn ->
        send(pid, %{
          type: :health,
          data: %{
            component: :polygon_websocket,
            status: :subscribe_rejected,
            symbol: "SPY",
            detail: "not permitted"
          }
        })

        assert HubSubscription.status(pid).symbols["SPY"].state == :rejected
      end)

    assert log =~ "REJECTED SPY"
  end

  test "ignores unrelated broadcasts and other nodes" do
    pid = start()
    send(pid, %{type: :health, data: %{component: :ibkr, status: :down}})
    send(pid, {:nodedown, :other@host})
    send(pid, :whatever)

    assert HubSubscription.status(pid).connected?
  end

  test "unsubscribes on shutdown" do
    pid = start()
    assert_receive {:rpc, @hub, :subscribe_symbol, ["QQQ", _]}

    GenServer.stop(pid)

    assert_receive {:rpc, @hub, :unsubscribe_symbol, ["SPY", _]}
    assert_receive {:rpc, @hub, :unsubscribe_symbol, ["QQQ", _]}
  end
end
