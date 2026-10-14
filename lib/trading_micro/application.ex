defmodule TradingMicro.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      TradingMicroWeb.Telemetry,
      TradingMicro.Repo,
      {DNSCluster, query: Application.get_env(:trading_micro, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: TradingMicro.PubSub},
      # Start a worker by calling: TradingMicro.Worker.start_link(arg)
      # {TradingMicro.Worker, arg},
      # Start to serve requests, typically the last entry
      TradingMicroWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: TradingMicro.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    TradingMicroWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
