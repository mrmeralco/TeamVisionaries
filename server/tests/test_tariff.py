"""SPEC: Meralco consumption levels and the seasonal bill forecast (app/tariff.py, energy.bill).

  cost     = kWh x (rate setting + adder of the level the month's total falls in)   ("whole" mode)
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
@pytest.mark.parametrize("kwh,expected", [(0, 0), (200, 2400), (250, 250 * 12.35), (350, 350 * 12.65), (450, 450 * 13.25)])
def test_whole_month_is_charged_at_its_level(kwh, expected):
    assert tariff.cost(kwh, 12.0) == pytest.approx(expected)


def test_marginal_mode_charges_each_slice_at_its_own_level(monkeypatch):
    monkeypatch.setattr(tariff, "BRACKET_MODE", "marginal")
    assert tariff.cost(250, 12.0) == pytest.approx(200 * 12 + 50 * 12.35)
    assert tariff.cost(450, 12.0) == pytest.approx(200 * 12 + 100 * 12.35 + 100 * 12.65 + 50 * 13.25)


@pytest.mark.parametrize("mode", ["whole", "marginal"])
def test_more_kwh_never_costs_less(monkeypatch, mode):
    monkeypatch.setattr(tariff, "BRACKET_MODE", mode)
    costs = [tariff.cost(k / 2, 12.0) for k in range(0, 1200)]
    assert costs == sorted(costs)


def test_bracket_limits():
    assert tariff.bracket(150) == (0, 200, 0.0)
    assert tariff.bracket(200) == (0, 200, 0.0)
    assert tariff.bracket(201) == (200, 300, 0.35)
    assert tariff.bracket(999) == (400, None, 1.25)


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
    assert b["forecast_php"] == pytest.approx(720, abs=3)


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
    assert b["forecast_rate_php_per_kwh"] == pytest.approx(12.35)
    assert b["forecast_bracket_kwh"] == (200, 300)
    assert b["month_to_date_php"] == pytest.approx(126 * 12.35, abs=1)
    assert b["month_to_date_php"] <= b["forecast_low_php"] <= b["forecast_php"] <= b["forecast_high_php"]
