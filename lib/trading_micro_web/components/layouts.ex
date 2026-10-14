defmodule TradingMicroWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use TradingMicroWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Page layout for non-monitor pages: navbar plus a centred column.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <.trading_navbar />

    <main class="px-4 py-8 sm:px-6 lg:px-8">
      <div class="mx-auto max-w-6xl">
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Full-viewport layout for dense, live-updating monitor screens (DESIGN.md).
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  slot :inner_block, required: true

  def trading_live(assigns) do
    ~H"""
    <.trading_navbar />

    <div class="min-h-screen bg-base-100">
      <main class="pb-6 px-4 sm:px-6 lg:px-8">
        <div class="max-w-7xl mx-auto">
          {render_slot(@inner_block)}
        </div>
      </main>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  The only navbar: square mark plus `Trading://Micro` wordmark.
  """
  def trading_navbar(assigns) do
    ~H"""
    <header class="navbar bg-base-300 border-b border-primary/20 px-4 sm:px-6 lg:px-8 min-h-14 h-14">
      <div class="navbar-start">
        <a href="/" class="flex items-center gap-2 px-2">
          <span class="w-2 h-2 bg-primary shrink-0"></span>
          <span class="text-lg font-bold uppercase tracking-[0.08em] text-base-content">
            Trading<span class="text-primary">://</span>Micro
          </span>
        </a>
      </div>

      <div class="navbar-end">
        <ul class="menu menu-horizontal px-1 gap-1 font-data text-xs uppercase tracking-wider">
          <li>
            <a
              href="/"
              class="rounded-none border border-transparent hover:border-primary/40 hover:bg-primary/10 hover:text-primary"
            >
              <.icon name="hero-signal" class="h-4 w-4 mr-1" /> Recorder
            </a>
          </li>
          <li>
            <a
              href="/health"
              class="rounded-none border border-transparent hover:border-primary/40 hover:bg-primary/10 hover:text-primary"
            >
              <.icon name="hero-heart" class="h-4 w-4 mr-1" /> Health
            </a>
          </li>
          <li>
            <a href="/status" class="rounded-none opacity-50 hover:opacity-100">
              <.icon name="hero-cog-6-tooth" class="h-4 w-4 mr-1" /> Status
            </a>
          </li>
        </ul>
      </div>
    </header>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
