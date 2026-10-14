defmodule TradingMicroWeb.PageController do
  use TradingMicroWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
