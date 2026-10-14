defmodule TradingMicro.SessionTest do
  use ExUnit.Case, async: true

  alias TradingMicro.Session

  describe "a regular day in EDT (UTC-4)" do
    setup do: %{day: Session.day(~D[2026-10-13])}

    test "window is 04:00-20:00 ET, half-open", %{day: day} do
      refute Session.in_window?(day, ~U[2026-10-13 07:59:59Z])
      assert Session.in_window?(day, ~U[2026-10-13 08:00:00Z])
      assert Session.in_window?(day, ~U[2026-10-13 23:59:59Z])
      refute Session.in_window?(day, ~U[2026-10-14 00:00:00Z])
    end

    test "RTH is 09:30-16:00 ET, half-open", %{day: day} do
      refute Session.rth?(day, ~U[2026-10-13 13:29:59Z])
      assert Session.rth?(day, ~U[2026-10-13 13:30:00Z])
      assert Session.rth?(day, ~U[2026-10-13 19:59:59Z])
      refute Session.rth?(day, ~U[2026-10-13 20:00:00Z])
    end
  end

  test "EST (UTC-5) shifts the UTC bounds by an hour" do
    day = Session.day(~D[2026-12-01])
    refute Session.rth?(day, ~U[2026-12-01 14:29:59Z])
    assert Session.rth?(day, ~U[2026-12-01 14:30:00Z])
    assert Session.in_window?(day, ~U[2026-12-01 09:00:00Z])
  end

  test "a holiday has no window and no RTH" do
    # Thanksgiving 2026
    day = Session.day(~D[2026-11-26])
    refute Session.in_window?(day, ~U[2026-11-26 16:00:00Z])
    refute Session.rth?(day, ~U[2026-11-26 16:00:00Z])
  end

  test "a weekend has no window" do
    refute Session.in_window?(Session.day(~D[2026-10-17]), ~U[2026-10-17 15:00:00Z])
  end

  test "a half day closes RTH at the early close" do
    # Day after Thanksgiving 2026: 13:00 ET close = 18:00 UTC.
    day = Session.day(~D[2026-11-27])
    assert Session.rth?(day, ~U[2026-11-27 17:59:59Z])
    refute Session.rth?(day, ~U[2026-11-27 18:00:00Z])
  end

  test "et_date/1 uses the New York calendar day" do
    assert Session.et_date(~U[2026-10-14 03:00:00Z]) == ~D[2026-10-13]
  end

  test "rth_now?/1" do
    assert Session.rth_now?(~U[2026-10-13 15:00:00Z])
    refute Session.rth_now?(~U[2026-10-13 21:00:00Z])
  end
end
