defmodule TradingMicro.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        TradingMicroWeb.Telemetry,
        TradingMicro.Repo,
        {DNSCluster, query: Application.get_env(:trading_micro, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: TradingMicro.PubSub},
        # A local server under the hub's PubSub name: Phoenix.PubSub delivers
        # cross-node through :pg groups keyed by that name, so this is what
        # lets trading_hub's broadcasts reach the recorder. Subscribe only;
        # this app never broadcasts on it.
        Supervisor.child_spec({Phoenix.PubSub, name: TradingHub.PubSub}, id: :trading_hub_pubsub),
        {Registry, keys: :unique, name: TradingMicro.Recorder.Registry}
      ] ++ recorder() ++ [TradingMicroWeb.Endpoint]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: TradingMicro.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp recorder do
    if TradingMicro.Recorder.enabled?(), do: [TradingMicro.Recorder], else: []
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    TradingMicroWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
