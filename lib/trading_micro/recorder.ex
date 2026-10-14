defmodule TradingMicro.Recorder do
  @moduledoc """
  Phase 1 of trading_micro: records SPY/QQQ top of book and trade flow
  from trading_hub's Polygon feed into `live_second_quotes`, one row per
  symbol per second. No prediction, no orders, nothing published back
  onto `TradingHub.PubSub`.

  Supervises `TradingMicro.HubSubscription` (asks the hub for the data) and
  one `TradingMicro.Recorder.Worker` per configured symbol (listens and
  writes). Switched off entirely with
  `config :trading_micro, TradingMicro.Recorder, enabled: false`.
  """

  use Supervisor

  alias TradingMicro.HubSubscription
  alias TradingMicro.Recorder.Worker

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The symbols this app records, from `config :trading_micro, :symbols`."
  @spec symbols() :: [String.t()]
  def symbols, do: Application.get_env(:trading_micro, :symbols, [])

  @doc "Whether the recorder is configured to run."
  @spec enabled?() :: boolean()
  def enabled? do
    :trading_micro |> Application.get_env(__MODULE__, []) |> Keyword.get(:enabled, true)
  end

  @impl true
  def init(_opts) do
    symbols = symbols()
    hub_node = Application.get_env(:trading_micro, :hub_node)

    children =
      [{HubSubscription, symbols: symbols, hub_node: hub_node}] ++
        Enum.map(symbols, &{Worker, symbol: &1})

    Supervisor.init(children, strategy: :one_for_one)
  end
end
