# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :trading_micro,
  ecto_repos: [TradingMicro.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# What the recorder records. Adding a symbol is this one line — the
# recorder subscribes it on trading_hub's Polygon feed at boot. IWM and
# XLE (added 2026-10-15) are controls for the SPY/QQQ signature study: a
# second broad index and a thinner sector name, so an effect seen only in
# QQQ can be told apart from a fluke.
config :trading_micro, :symbols, ["SPY", "QQQ", "IWM", "XLE"]

# The recorder: per-second aggregation flushed in batches.
#   flush_interval_ms — how often closed seconds are written.
#   settle_ms — how long after a second ends before it is closed, so a
#     late-arriving message (Polygon stamps by SIP time, delivery is
#     cross-node and unordered across topics) still lands in its second.
#   gap_warn_seconds — RTH silence that counts as a gap, logged as a
#     warning when it closes.
#   gap_alarm_seconds — RTH silence that gets logged at error level and
#     marks the recorder unhealthy.
config :trading_micro, TradingMicro.Recorder,
  enabled: true,
  flush_interval_ms: 5_000,
  settle_ms: 2_000,
  gap_warn_seconds: 15,
  gap_alarm_seconds: 60

# Shared /status and /status/metrics endpoints (app_status).
config :app_status,
  app_name: :trading_micro,
  endpoint: TradingMicroWeb.Endpoint,
  extension: TradingMicro.StatusExtension

# DST-correct ET session math (TradingCore.Intraday.RegularSession) needs
# a real tz database. Updated via `mix deps.update tzdata`, not polled.
config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase
config :tzdata, :autoupdate, :disabled

# Configure the endpoint
config :trading_micro, TradingMicroWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: TradingMicroWeb.ErrorHTML, json: TradingMicroWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: TradingMicro.PubSub,
  live_view: [signing_salt: "AwToaQhE"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :trading_micro, TradingMicro.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  trading_micro: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  trading_micro: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
