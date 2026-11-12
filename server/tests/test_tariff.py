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
def test_flat_season_forecast_is_history_times_days(device, monkeypatch):
    d = date(2026, 4, 15)
    monkeypatch.setattr(energy, "today", lambda: d)
    monkeypatch.setattr(tariff, "SEASON_INDEX", FLAT)
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
        m.setattr(tariff, "SEASON_INDEX", FLAT)
        flat = energy.bill(device, {"rate_php_per_kwh": 12.0, "battery_kwh": 10})["forecast_kwh"]
    seasonal = energy.bill(device, {"rate_php_per_kwh": 12.0, "battery_kwh": 10})["forecast_kwh"]
    assert seasonal > flat  # history came from cooler March/early April; late April is hotter


def test_heading_into_a_higher_level_prices_the_whole_month_there(device, monkeypatch):
    d = date(2026, 4, 15)
    monkeypatch.setattr(energy, "today", lambda: d)
    monkeypatch.setattr(tariff, "SEASON_INDEX", FLAT)
    history(device, d, 9.0)  # 30 x 9 = 270 kWh -> 201-300 level
    b = energy.bill(device, {"rate_php_per_kwh": 12.0, "battery_kwh": 10})
    assert b["forecast_kwh"] == pytest.approx(270, abs=1)
    assert b["forecast_rate_php_per_kwh"] == pytest.approx(tariff.rate_at(270, 12.0), abs=0.01)
    assert b["forecast_bracket_kwh"] == (200, 300)
    assert b["month_to_date_php"] == pytest.approx(126 * tariff.rate_at(270, 12.0), abs=1)
    assert b["month_to_date_php"] <= b["forecast_low_php"] <= b["forecast_php"] <= b["forecast_high_php"]
