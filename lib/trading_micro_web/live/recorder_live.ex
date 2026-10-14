defmodule TradingMicroWeb.RecorderLive do
  @moduledoc """
  Recorder monitor: hub connection and session state, a stat strip per
  symbol, and the most recent recorded seconds per symbol as they are
  written. Follows DESIGN.md's three-zone monitor pattern.
  """

  use TradingMicroWeb, :live_view

  alias TradingMicro.Health
  alias TradingMicro.Quotes
  alias TradingMicro.Recorder
  alias TradingMicro.Recorder.Worker

  @recent 20
  @tick_ms 2_000

  @impl true
  def mount(_params, _session, socket) do
    symbols = Recorder.symbols()

    if connected?(socket) do
      Phoenix.PubSub.subscribe(TradingMicro.PubSub, Worker.stats_topic())
      :timer.send_interval(@tick_ms, :tick)
    end

    socket =
      socket
      |> assign(:page_title, "Recorder")
      |> assign(:symbols, symbols)
      |> assign(:health, Health.snapshot())
      |> assign(:stats, Map.new(symbols, &{&1, Worker.stats(&1)}))
      |> assign(:newest, %{})

    {:ok, Enum.reduce(symbols, socket, &load_rows(&2, &1))}
  end

  @impl true
  def handle_info({:recorder_stats, %{symbol: symbol} = stats}, socket) do
    socket = update(socket, :stats, &Map.put(&1, symbol, stats))
    {:noreply, load_rows(socket, symbol)}
  end

  def handle_info(:tick, socket) do
    stats = Map.new(socket.assigns.symbols, &{&1, Worker.stats(&1)})
    {:noreply, assign(socket, health: Health.snapshot(), stats: stats)}
  end

  # Inserts rows newer than the newest one shown, at the top, so only new
  # rows flash. The first load resets the stream.
  defp load_rows(socket, symbol) do
    rows = Quotes.recent(symbol, @recent)
    newest = Map.get(socket.assigns.newest, symbol)

    fresh =
      if newest,
        do: Enum.filter(rows, &(DateTime.compare(&1.ts, newest) == :gt)),
        else: rows

    socket =
      if newest do
        fresh
        |> Enum.reverse()
        |> Enum.reduce(socket, &stream_insert(&2, stream_name(symbol), &1, at: 0, limit: @recent))
      else
        stream(socket, stream_name(symbol), rows, reset: true, dom_id: &dom_id(symbol, &1))
      end

    case rows do
      [top | _] -> update(socket, :newest, &Map.put(&1, symbol, top.ts))
      [] -> socket
    end
  end

  # Stream names are atoms; symbols come from config, so this is bounded.
  defp stream_name(symbol), do: String.to_atom("rows_" <> symbol)

  defp dom_id(symbol, row), do: "#{symbol}-#{DateTime.to_unix(row.ts)}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.trading_live flash={@flash}>
      <%!-- Zone 1: header bar --%>
      <div class="flex flex-wrap items-center justify-between gap-4 py-4 border-b border-base-300">
        <div class="flex items-center gap-3">
          <.icon name="hero-signal" class="size-6 text-primary" />
          <div>
            <h1 class="text-xl font-semibold uppercase tracking-wider">Microstructure Recorder</h1>
            <p class="font-data text-xs text-base-content/50">
              live_second_quotes · one row per symbol per second · polygon via trading_hub
            </p>
          </div>
        </div>

        <div class="flex flex-wrap items-center gap-2" id="recorder-status">
          <.hub_status connected={@health.hub_connected} node={@health.hub_node} />
          <.badge color={if @health.rth, do: "info", else: "neutral"}>
            {if @health.rth, do: "RTH", else: "Off-hours"}
          </.badge>
          <.badge color={status_color(@health.status)} id="overall-status">
            {@health.status}
          </.badge>
        </div>
      </div>

      <%!-- Zone 2: stat strip, one card per symbol --%>
      <div class="grid gap-px bg-base-300 border border-base-300 mt-4 md:grid-cols-2">
        <.symbol_card
          :for={symbol <- @symbols}
          symbol={symbol}
          stats={@stats[symbol]}
          health={@health.symbols[symbol]}
        />
      </div>

      <%!-- Zone 3: recent seconds per symbol --%>
      <div class="grid gap-4 mt-4 xl:grid-cols-2">
        <section :for={symbol <- @symbols} class="border border-base-300 bg-base-100 min-w-0">
          <div class="flex items-center justify-between px-3 py-2 bg-base-200 border-b border-base-300">
            <div class="flex items-center gap-2 text-sm uppercase tracking-wider">
              <.icon name="hero-clock" class="size-4 text-primary" />
              {symbol} · recent seconds
            </div>
            <span class="font-data text-[11px] text-base-content/50">newest first · ET</span>
          </div>

          <div class="overflow-x-auto">
            <table class="data-table w-full text-xs tabular-nums">
              <thead class="text-[10px] uppercase tracking-wider text-base-content/50">
                <tr class="border-b border-base-300">
                  <th class="px-2 py-1.5 text-left font-display font-normal">Time</th>
                  <th class="px-2 py-1.5 text-right font-display font-normal">Bid</th>
                  <th class="px-2 py-1.5 text-right font-display font-normal">Ask</th>
                  <th class="px-2 py-1.5 text-right font-display font-normal">Bps</th>
                  <th class="px-2 py-1.5 text-right font-display font-normal">Upd</th>
                  <th class="px-2 py-1.5 text-right font-display font-normal">OFI</th>
                  <th class="px-2 py-1.5 text-right font-display font-normal">Buy</th>
                  <th class="px-2 py-1.5 text-right font-display font-normal">Sell</th>
                  <th class="px-2 py-1.5 text-right font-display font-normal">Trd</th>
                </tr>
              </thead>
              <tbody id={"rows-#{symbol}"} phx-update="stream">
                <tr id={"rows-#{symbol}-empty"} class="hidden only:table-row">
                  <td colspan="9"><.empty_rows connected={@health.hub_connected} /></td>
                </tr>
                <tr
                  :for={{id, row} <- @streams[stream_name(symbol)]}
                  id={id}
                  class="row-flash border-b border-base-300/60 hover:bg-base-200"
                >
                  <td class="px-2 py-1 text-base-content/70">
                    {et_time(row.ts)}<span :if={!row.rth} class="ml-1 text-warning/70">x</span>
                  </td>
                  <td class="px-2 py-1 text-right">{price(row.bid)}</td>
                  <td class="px-2 py-1 text-right">{price(row.ask)}</td>
                  <td class="px-2 py-1 text-right text-base-content/70">
                    {spread_bps(row.bid, row.ask)}
                  </td>
                  <td class="px-2 py-1 text-right text-base-content/70">{row.quote_updates}</td>
                  <td class={["px-2 py-1 text-right", flow_class(row.ofi)]}>{signed(row.ofi)}</td>
                  <td class="px-2 py-1 text-right text-long">{volume(row.buy_volume)}</td>
                  <td class="px-2 py-1 text-right text-short">{volume(row.sell_volume)}</td>
                  <td class="px-2 py-1 text-right text-base-content/70">{row.trade_count}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>
      </div>
    </Layouts.trading_live>
    """
  end

  attr :connected, :boolean, required: true
  attr :node, :any, default: nil

  defp hub_status(assigns) do
    ~H"""
    <div
      class={[
        "flex items-center gap-2 px-2 py-1 border font-data text-[11px] uppercase tracking-wide",
        if(@connected,
          do: "border-success/40 text-success bg-success/10",
          else: "border-error/40 text-error bg-error/10"
        )
      ]}
      title={@node && to_string(@node)}
    >
      <span class={[
        "relative inline-block size-2 rounded-full bg-current",
        @connected && "signal-dot"
      ]}></span>
      {if @connected, do: "Hub connected", else: "Hub offline"}
    </div>
    """
  end

  attr :color, :string, required: true
  attr :id, :string, default: nil
  slot :inner_block, required: true

  defp badge(assigns) do
    ~H"""
    <span
      id={@id}
      class={[
        "px-1.5 py-0.5 border text-[11px] uppercase tracking-wide font-data",
        badge_class(@color)
      ]}
    >
      {render_slot(@inner_block)}
    </span>
    """
  end

  defp badge_class("success"), do: "border-success/40 text-success bg-success/10"
  defp badge_class("error"), do: "border-error/40 text-error bg-error/10"
  defp badge_class("warning"), do: "border-warning/40 text-warning bg-warning/10"
  defp badge_class("info"), do: "border-info/40 text-info bg-info/10"
  defp badge_class(_), do: "border-base-content/20 text-base-content/60"

  defp status_color("ok"), do: "success"
  defp status_color("degraded"), do: "error"
  defp status_color(_), do: "neutral"

  attr :symbol, :string, required: true
  attr :stats, :map, default: nil
  attr :health, :map, default: nil

  defp symbol_card(assigns) do
    assigns = assign(assigns, :quote, assigns.stats && assigns.stats.quote)

    ~H"""
    <div class="bg-base-100 p-4" id={"card-#{@symbol}"}>
      <div class="flex items-center justify-between">
        <div class="text-lg font-semibold uppercase tracking-wider">{@symbol}</div>
        <div class="flex gap-1">
          <.badge :if={@health && @health.gap_open} color="error">Gap</.badge>
          <.badge
            :if={@health && @health.subscription}
            color={if @health.subscription == :subscribed, do: "success", else: "warning"}
          >
            {@health.subscription}
          </.badge>
        </div>
      </div>

      <div :if={is_nil(@stats)} class="mt-3 font-data text-xs text-base-content/50">
        recorder not running for this symbol
      </div>

      <div :if={@stats} class="mt-3 grid grid-cols-2 gap-x-6 gap-y-2 sm:grid-cols-4">
        <.stat label="Bid" value={price(@quote && @quote.bid)} sub={size(@quote && @quote.bid_size)} />
        <.stat label="Ask" value={price(@quote && @quote.ask)} sub={size(@quote && @quote.ask_size)} />
        <.stat
          label="Spread"
          value={spread_bps(@quote && @quote.bid, @quote && @quote.ask)}
          sub="bps"
        />
        <.stat
          label="Rows / min"
          value={@health && @health.rows_last_minute}
          sub={"#{@stats.rows_written} written"}
        />
        <.stat label="Last msg" value={age(@stats.last_message_age_s)} sub="age" />
        <.stat label="Quotes" value={@stats.quotes_seen} sub={"#{@stats.trades_seen} trades"} />
        <.stat label="Late" value={@stats.late_dropped} sub={"#{@stats.outside_window} off-window"} />
        <.stat
          label="Pending"
          value={@stats.pending_rows}
          sub={(@stats.last_flush_error && "write failing") || "ok"}
        />
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :sub, :any, default: nil

  defp stat(assigns) do
    ~H"""
    <div>
      <div class="text-[10px] uppercase tracking-wider text-base-content/50">{@label}</div>
      <div class="font-data text-base tabular-nums">{@value || "—"}</div>
      <div :if={@sub} class="font-data text-[10px] text-base-content/40">{@sub}</div>
    </div>
    """
  end

  attr :connected, :boolean, required: true

  defp empty_rows(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center gap-2 py-10 text-center">
      <.icon name="hero-signal-slash" class="size-10 text-primary/30" />
      <div class="text-sm uppercase tracking-wider">No seconds recorded yet</div>
      <div class="font-data text-[11px] text-base-content/50">
        rows appear once quotes arrive in the 04:00–20:00 ET window
      </div>
      <div
        :if={!@connected}
        class="mt-1 px-1.5 py-0.5 border border-error/40 text-error bg-error/10 font-data text-[11px] uppercase tracking-wide"
      >
        Not connected to Trading Hub
      </div>
    </div>
    """
  end

  # -- formatting --------------------------------------------------------------

  defp et_time(ts) do
    ts |> DateTime.shift_zone!("America/New_York") |> Calendar.strftime("%H:%M:%S")
  end

  defp price(nil), do: nil
  defp price(%Decimal{} = d), do: d |> Decimal.round(2) |> Decimal.to_string(:normal)

  defp size(nil), do: nil
  defp size(%Decimal{} = d), do: "x" <> Decimal.to_string(Decimal.normalize(d), :normal)

  defp volume(%Decimal{} = d) do
    if Decimal.equal?(d, 0), do: "·", else: d |> Decimal.normalize() |> Decimal.to_string(:normal)
  end

  defp volume(_), do: "·"

  defp signed(nil), do: "—"

  defp signed(%Decimal{} = d) do
    text = d |> Decimal.normalize() |> Decimal.to_string(:normal)
    if Decimal.compare(d, 0) == :gt, do: "+" <> text, else: text
  end

  defp flow_class(%Decimal{} = d) do
    case Decimal.compare(d, 0) do
      :gt -> "text-long"
      :lt -> "text-short"
      :eq -> "text-base-content/50"
    end
  end

  defp flow_class(_), do: "text-base-content/30"

  defp spread_bps(%Decimal{} = bid, %Decimal{} = ask) do
    mid = bid |> Decimal.add(ask) |> Decimal.div(2)

    if Decimal.compare(mid, 0) == :gt do
      ask
      |> Decimal.sub(bid)
      |> Decimal.div(mid)
      |> Decimal.mult(10_000)
      |> Decimal.round(2)
      |> Decimal.to_string(:normal)
    end
  end

  defp spread_bps(_, _), do: nil

  defp age(nil), do: nil
  defp age(s) when s < 60, do: "#{:erlang.float_to_binary(s * 1.0, decimals: 1)}s"
  defp age(s), do: "#{round(s)}s"
end
