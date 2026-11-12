"""SPEC: Meralco consumption levels and the seasonal bill forecast (app/tariff.py, energy.bill).

  cost     = fixed charges + kWh x (rate setting - fixed/200 + distribution difference of the month's level)
  forecast = month-to-date kWh + season-adjusted weekday/weekend averages x days left, then priced
"""
from datetime import date, timedelta

import pytest

from app import db, energy, tariff

FLAT = (1.0,) * 12


def put_kwh(device, d: date, kwh: float):
    """`kwh` of grid import on day `d`: one hour at kwh*1000 W, sampled every minute."""
    base = {"pv_w": 0, "batt_soc": 50, "batt_w": 0, "grid_on": True, "inv_temp_c": 40, "fault_code": 0}
    t0 = energy.local_midnight(d) + 8 * 3600
    w = int(kwh * 1000)
    for ts in range(t0, t0 + 3600, 60):
        db.insert_telemetry(device, base | {"ts": ts, "load_w": w, "grid_w": w})
    db.insert_telemetry(device, base | {"ts": t0 + 3600, "load_w": 0, "grid_w": 0})


def history(device, today: date, kwh_per_day: float, days: int = 45):
    for i in range(1, days + 1):
        put_kwh(device, today - timedelta(days=i), kwh_per_day)


# ------------------------------------------------------------------- tariff --
FIXED = (16.38 + 5.00) * 1.12  # Meralco supply + metering per customer, with VAT


def test_typical_200_kwh_month_costs_exactly_the_announced_rate():
    assert tariff.cost(200, 15.0615) == pytest.approx(200 * 15.0615)


@pytest.mark.parametrize("kwh,dist", [(150, 0.9803), (250, 1.2908), (350, 1.5837), (450, 2.0941)])
def test_whole_month_pays_the_distribution_charge_of_its_level(kwh, dist):
    per_kwh = 12.0 - FIXED / 200 + (dist - 0.9803) * 1.12
    assert tariff.cost(kwh, 12.0) == pytest.approx(FIXED + kwh * per_kwh)


def test_fixed_charges_are_paid_even_with_no_grid_use():
    assert tariff.cost(0, 12.0) == pytest.approx(FIXED)


def test_energy_tax_only_above_650_kwh_in_slices():
    assert tariff.energy_tax(650) == 0
    assert tariff.energy_tax(700) == pytest.approx(50 * 0.10)
    assert tariff.energy_tax(1600) == pytest.approx(350 * 0.10 + 500 * 0.20 + 100 * 0.35)


def test_more_kwh_never_costs_less():
    costs = [tariff.cost(k / 2, 12.0) for k in range(0, 2400)]
    assert costs == sorted(costs)


def test_bracket_limits():
    assert tariff.bracket(200)[:2] == (0, 200) and tariff.bracket(200)[2] == 0
    assert tariff.bracket(201)[:2] == (200, 300) and tariff.bracket(201)[2] == pytest.approx(0.3105 * 1.12)
    assert tariff.bracket(999)[:2] == (400, None) and tariff.bracket(999)[2] == pytest.approx(1.1138 * 1.12)


# ------------------------------------------------------------------- season --
def test_season_index_averages_to_one():
    assert sum(tariff.SEASON_INDEX) / 12 == pytest.approx(1.0)


def test_season_factor_hits_the_table_mid_month_and_has_no_jumps():
    assert tariff.season_factor(date(2026, 5, 16)) == pytest.approx(tariff.SEASON_INDEX[4])
    days = [date(2026, 1, 1) + timedelta(days=i) for i in range(366)]
    f = [tariff.season_factor(x) for x in days]
    assert max(abs(a - b) for a, b in zip(f, f[1:])) < 0.01  # incl. Dec 31 -> Jan 1


# ----------------------------------------------------------------- forecast --
def flat_seasons(m):
    """No season anywhere: the tariff's whole-home index and the battery simulation's load and sun tables."""
    from app import projection
    m.setattr(tariff, "SEASON_INDEX", FLAT)
    m.setattr(projection, "LOAD_SEASON", FLAT)
    m.setattr(projection, "SOLAR_SEASON", FLAT)


def test_flat_season_forecast_is_history_times_days(device, monkeypatch):
    d = date(2026, 4, 15)
    monkeypatch.setattr(energy, "today", lambda: d)
    flat_seasons(monkeypatch)
    history(device, d, 2.0)
    b = energy.bill(device, {"rate_php_per_kwh": 12.0, "battery_kwh": 10})
    # Apr 1-14 = 28 kWh, today expected 2, Apr 16-30 = 15 x 2
    assert b["forecast_kwh"] == pytest.approx(60, abs=0.2)
    assert b["forecast_php"] == pytest.approx(tariff.cost(60, 12.0), abs=3)


def test_hot_season_raises_the_forecast(device, monkeypatch):
    d = date(2026, 4, 15)
    monkeypatch.setattr(energy, "today", lambda: d)
    history(device, d, 2.0)
    flat = None
    with monkeypatch.context() as m:
        flat_seasons(m)
        flat = energy.bill(device, {"rate_php_per_kwh": 12.0, "battery_kwh": 10})["forecast_kwh"]
    seasonal = energy.bill(device, {"rate_php_per_kwh": 12.0, "battery_kwh": 10})["forecast_kwh"]
    assert seasonal > flat  # history came from cooler March/early April; late April is hotter


def test_heading_into_a_higher_level_prices_the_whole_month_there(device, monkeypatch):
    d = date(2026, 4, 15)
    monkeypatch.setattr(energy, "today", lambda: d)
    flat_seasons(monkeypatch)
    history(device, d, 9.0)  # 30 x 9 = 270 kWh -> 201-300 level
    b = energy.bill(device, {"rate_php_per_kwh": 12.0, "battery_kwh": 10})
    assert b["forecast_kwh"] == pytest.approx(270, abs=1)
    assert b["forecast_rate_php_per_kwh"] == pytest.approx(tariff.rate_at(270, 12.0), abs=0.01)
    assert b["forecast_bracket_kwh"] == (200, 300)
    assert b["month_to_date_php"] == pytest.approx(126 * tariff.rate_at(270, 12.0), abs=1)
    assert b["month_to_date_php"] <= b["forecast_low_php"] <= b["forecast_php"] <= b["forecast_high_php"]


def test_forecast_follows_the_last_two_weeks_not_the_eight_week_average(device, monkeypatch):
    """Use jumped 2 weeks ago (hot spell, new aircon): the rest of the month is forecast at the new level.
    SARIMA alone reverted toward its 8-week mean, which lagged the season in backtests."""
    d = date(2026, 4, 5)
    monkeypatch.setattr(energy, "today", lambda: d)
    flat_seasons(monkeypatch)
    for i in range(15, 60):
        put_kwh(device, d - timedelta(days=i), 2.0)
    for i in range(1, 15):
        put_kwh(device, d - timedelta(days=i), 6.0)
    fc = energy.forecast_days(device, d, 26, settings={"battery_kwh": 10})
    assert sum(fc["kwh"]) / 26 == pytest.approx(6.0, rel=0.1)


# ------------------------------------------------- forecast evidence (Bill) --
@pytest.mark.parametrize("kwh", [0, 57.3, 199.9, 200.1, 250, 333.3, 450, 700, 1600])
def test_charges_add_up_to_the_bill(kwh):
    parts = tariff.charges(kwh, 15.06)
    assert sum(c["php"] for c in parts) == pytest.approx(round(tariff.cost(kwh, 15.06), 2), abs=0.005)
    ids = [c["id"] for c in parts]
    assert ids[:3] == ["energy", "distribution", "fixed"]
    assert ("energy_tax" in ids) == (kwh > 650)


def test_distribution_charge_is_the_levels_rate_on_every_kwh():
    d = {c["id"]: c for c in tariff.charges(250, 15.06)}["distribution"]
    assert d["php_per_kwh"] == pytest.approx(1.2908 * 1.12, abs=1e-4)
    assert d["php"] == pytest.approx(250 * 1.2908 * 1.12, abs=0.01)


def test_a_200_kwh_month_splits_the_announced_rate():
    """The overall rate for 200 kWh is the whole bill: energy + distribution + fixed = rate x 200."""
    parts = {c["id"]: c["php"] for c in tariff.charges(200, 15.06)}
    assert sum(parts.values()) == pytest.approx(15.06 * 200, abs=0.01)
    assert parts["fixed"] == pytest.approx((16.38 + 5.00) * 1.12, abs=0.01)


def test_level_steps_say_how_far_the_next_level_is_and_what_crossing_it_costs():
    s = tariff.level_steps(253, 15.06)
    assert (s["min_kwh"], s["max_kwh"]) == (200, 300)
    assert s["up"]["kwh_away"] == pytest.approx(47) and s["down"]["kwh_away"] == pytest.approx(53)
    # Crossing 300 kWh moves all 300 kWh to the 301-400 rate.
    assert s["up"]["jump_php"] == pytest.approx(300 * (1.5837 - 1.2908) * 1.12, abs=0.05)
    assert s["down"]["jump_php"] == pytest.approx(200 * (1.2908 - 0.9803) * 1.12, abs=0.05)
    assert tariff.level_steps(50, 15.06)["down"] is None
    assert tariff.level_steps(900, 15.06)["up"] is None


def test_bill_shows_how_its_forecast_is_made(client):
    from solaris_contract import validate
    b = client.get("/api/bill").json()
    validate("bill", b)
    f = b["forecast_detail"]
    assert sum(c["php"] for c in f["charges"]) == pytest.approx(b["forecast_php"], abs=0.02)
    days = f["days"]
    assert [x["day"] for x in days] == list(range(1, b["days_in_month"] + 1))
    assert [x["kind"] for x in days].count("today") == 1
    assert days[b["days_elapsed"] - 1]["kind"] == "today"
    assert f["done_days"] == b["days_elapsed"] - 1 and f["days_left"] == b["days_in_month"] - f["done_days"]
    cum = [x["cum_kwh"] for x in days]
    assert cum == sorted(cum) and cum[-1] == pytest.approx(f["kwh"], abs=0.1)
    assert days[-1]["cum_low_kwh"] == pytest.approx(f["low_kwh"], abs=0.1)
    assert days[-1]["cum_high_kwh"] == pytest.approx(f["high_kwh"], abs=0.1)
    assert all(x["cum_low_kwh"] <= x["cum_kwh"] <= x["cum_high_kwh"] for x in days)
    assert f["done_kwh"] + f["days_left_kwh"] == pytest.approx(f["kwh"], abs=0.2)
    lo, hi = f["level"]["min_kwh"], f["level"]["max_kwh"]
    assert lo <= f["kwh"] and (hi is None or f["kwh"] <= hi)
