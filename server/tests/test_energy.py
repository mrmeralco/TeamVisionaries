"""SPEC (Andy): the money and energy math from the plan.

  kWh       = power integrated over time (each sample counts until the next, gaps > 15 min not counted)
  bill      = grid import kWh x rate (+ Meralco level adder, see test_tariff.py; pure solar, no net-metering)
  savings   = home use NOT taken from the grid x rate
  runtime_h = (batt_soc% x battery_kWh) / load
Numbers here are exact so a wrong formula fails loudly.
"""
from datetime import timedelta

import pytest

from app import db, energy


def put_hour(device, start_ts, step=5, **w):
    """One hour of constant readings every `step` seconds."""
    base = {"pv_w": 0, "load_w": 0, "grid_w": 0, "batt_soc": 50, "batt_w": 0, "grid_on": True, "inv_temp_c": 40, "fault_code": 0}
    for ts in range(start_ts, start_ts + 3600, step):
        db.insert_telemetry(device, base | w | {"ts": ts})
    db.insert_telemetry(device, base | w | {"ts": start_ts + 3600, "pv_w": 0, "load_w": 0, "grid_w": 0, "batt_w": 0})


def day_start(days_ago=3):
    return energy.local_midnight(energy.today() - timedelta(days=days_ago))


def test_constant_power_for_one_hour_is_exact_kwh(device):
    t0 = day_start() + 10 * 3600
    put_hour(device, t0, pv_w=3000, load_w=1000, grid_w=-1500, batt_w=-500)
    t = energy.totals(device, t0, t0 + 7200)
    assert t["pv_kwh"] == pytest.approx(3.0)
    assert t["load_kwh"] == pytest.approx(1.0)
    assert t["grid_export_kwh"] == pytest.approx(1.5) and t["grid_import_kwh"] == 0
    assert t["batt_charge_kwh"] == pytest.approx(0.5) and t["batt_discharge_kwh"] == 0


def test_import_and_discharge_are_split_by_sign(device):
    t0 = day_start() + 20 * 3600
    put_hour(device, t0, load_w=2000, grid_w=1200, batt_w=800)
    t = energy.totals(device, t0, t0 + 3600)
    assert t["grid_import_kwh"] == pytest.approx(1.2) and t["batt_discharge_kwh"] == pytest.approx(0.8)


def test_data_gaps_are_not_counted_as_usage(device):
    t0 = day_start() + 3600
    db.insert_telemetry(device, {"ts": t0, "pv_w": 0, "load_w": 1000, "grid_w": 1000, "batt_soc": 50, "batt_w": 0,
                                 "grid_on": True, "inv_temp_c": 40, "fault_code": 0})
    db.insert_telemetry(device, {"ts": t0 + 3 * 3600, "pv_w": 0, "load_w": 0, "grid_w": 0, "batt_soc": 50, "batt_w": 0,
                                 "grid_on": True, "inv_temp_c": 40, "fault_code": 0})
    # device was silent for 3 h: only the 15-minute cap counts
    assert energy.totals(device, t0, t0 + 4 * 3600)["load_kwh"] == pytest.approx(0.25)


def test_self_sufficiency(device):
    assert energy.self_sufficiency({"load_kwh": 10, "grid_import_kwh": 2.5}) == 75.0
    assert energy.self_sufficiency({"load_kwh": 0, "grid_import_kwh": 0}) == 0.0


def test_savings_is_home_use_not_from_grid():
    assert energy.saved_kwh({"load_kwh": 10, "grid_import_kwh": 3}) == 7
    assert energy.saved_kwh({"load_kwh": 1, "grid_import_kwh": 3}) == 0  # never negative


@pytest.mark.parametrize("soc,load,kwh,expected", [(80, 1000, 10, 8.0), (50, 500, 5, 5.0), (20, 2000, 10, 1.0), (60, 0, 10, None)])
def test_brownout_runtime_formula(soc, load, kwh, expected):
    assert energy.runtime_hours(soc, load, kwh) == expected


def test_bill_is_grid_import_times_rate(device):
    d = energy.today()
    t0 = energy.local_midnight(d) + 60  # today, just after midnight
    put_hour(device, t0, load_w=2000, grid_w=2000)
    b = energy.bill(device, {"rate_php_per_kwh": 12.0, "battery_kwh": 10})
    assert b["month_to_date_kwh"] == pytest.approx(2.0, abs=0.01)
    # ₱/kWh of the level the month is heading for (up to 200 kWh here): the rate minus the fixed charges' share
    assert b["forecast_rate_php_per_kwh"] == pytest.approx(12.0 - (16.38 + 5.00) * 1.12 / 200, abs=0.01)
    assert b["month_to_date_php"] == pytest.approx(2.0 * b["forecast_rate_php_per_kwh"], abs=0.1)


def test_forecast_range_is_ordered_and_not_below_month_to_date(client):
    b = client.get("/api/bill").json()
    assert b["month_to_date_php"] <= b["forecast_low_php"] <= b["forecast_php"] <= b["forecast_high_php"]


def test_week_has_seven_weekly_costs_or_fewer(client):
    assert 1 <= len(client.get("/api/bill").json()["weekly_costs"]) <= 5


def _live(t):
    device = {"online": True}
    return energy.state_and_line(device, t, {"battery_kwh": 10})


@pytest.mark.parametrize("t,state", [
    ({"pv_w": 3000, "load_w": 1000, "grid_w": 0, "batt_w": -2000, "batt_soc": 50, "grid_on": True, "fault_code": 0, "ts": 0}, "solar"),
    ({"pv_w": 0, "load_w": 800, "grid_w": 0, "batt_w": 800, "batt_soc": 50, "grid_on": True, "fault_code": 0, "ts": 0}, "battery"),
    ({"pv_w": 0, "load_w": 800, "grid_w": 800, "batt_w": 0, "batt_soc": 20, "grid_on": True, "fault_code": 0, "ts": 0}, "grid"),
    ({"pv_w": 0, "load_w": 800, "grid_w": 0, "batt_w": 800, "batt_soc": 60, "grid_on": False, "fault_code": 0, "ts": 0}, "brownout"),
    ({"pv_w": 0, "load_w": 800, "grid_w": 0, "batt_w": 800, "batt_soc": 60, "grid_on": False, "fault_code": 21, "ts": 0}, "fault"),
])
def test_home_screen_state(t, state):
    s, line = _live(t)
    assert s == state and line  # fault beats brownout beats everything else


def test_offline_beats_everything():
    s, _ = energy.state_and_line({"online": False}, {"ts": 0, "fault_code": 21}, {"battery_kwh": 10})
    assert s == "offline"
    assert energy.state_and_line({"online": False}, None, {})[0] == "offline"
