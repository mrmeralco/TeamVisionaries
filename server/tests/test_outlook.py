"""SPEC: solar + battery outlook (app/outlook.py, app/weather.py, GET /api/outlook).

  solar    = forecast radiation x this house's kWh per kWh/m² (fitted on the last 7 days)
  battery  = hour-by-hour simulation, 95% each way, drains to reserve (grid on) or cutoff (brownout)
"""
import math
import time
from datetime import timedelta

import pytest

from ai import facts, router
from app import db, energy, outlook, weather

H = 3600
T = 1_800_000_000  # any hour start


# ---------------------------------------------------------------- weather --
def test_open_meteo_radiation_belongs_to_the_hour_before_its_timestamp():
    h = weather.parse({"time": [T + H, T + 2 * H], "shortwave_radiation": [500.0, None], "cloud_cover": [40, 90]})
    assert h == {T: {"rad_wm2": 500.0, "cloud_pct": 40}}


def test_stale_forecast_is_ignored(monkeypatch):
    monkeypatch.setattr(weather, "_cache", None)
    weather.set_hours({T: {"rad_wm2": 1.0, "cloud_pct": 0}}, fetched=time.time() - weather.STALE_S - 1)
    assert weather.hours() is None


# ---------------------------------------------------------------- battery --
def slots(n, pv, load):
    return [(T + i * H, 1.0, pv, load) for i in range(n)]


def test_no_sun_drains_to_reserve_then_grid():
    r = outlook.simulate(50, 10, 20, slots(6, 0, 1.0))
    # 5 kWh stored, 2 kWh reserve: 3 kWh x 0.95 = 2.85 kWh delivered = 2.85 h at 1 kW
    assert r["floor_ts"] == T + int(2.85 * H)
    assert r["soc"][-1] == pytest.approx(20)
    assert sum(r["short_kwh"]) == pytest.approx(6 - 2.85)


def test_brownout_cutoff_lasts_longer_than_grid_reserve():
    assert outlook.simulate(50, 10, 5, slots(6, 0, 1.0))["floor_ts"] == T + int(4.275 * H)


def test_sun_fills_the_battery():
    r = outlook.simulate(50, 10, 20, slots(4, 2.0, 0))
    assert r["full_ts"] == T + int(5 / 1.9 * H)   # 2 kWh x 0.95 per hour into 5 kWh of room
    assert r["soc"][-1] == pytest.approx(100)


def test_charging_is_capped_by_inverter_power():
    r = outlook.simulate(50, 10, 20, slots(4, 10.0, 0), max_kw=3.0)
    assert r["full_ts"] == T + int(5 / 2.85 * H)


# ---------------------------------------------------------- calibration --
def put(device, ts, pv_w, load_w, soc=50, grid_on=True):
    db.insert_telemetry(device, {"ts": ts, "pv_w": int(pv_w), "load_w": load_w, "grid_w": max(0, load_w - int(pv_w)),
                                 "batt_soc": soc, "batt_w": 0, "grid_on": grid_on, "inv_temp_c": 40, "fault_code": 0})


def clear_sky(ts) -> float:
    """0..1 for the middle of the hour starting at ts."""
    lt = energy.to_local(ts)
    return max(0.0, math.sin((lt.hour + 0.5 - 6) / 12 * math.pi))


def test_calibration_learns_kwh_per_kwh_m2(device):
    start = energy.local_midnight(energy.today() - timedelta(days=2)) + 7 * H
    wx = {}
    for i in range(12):
        hs = start + i * H
        for ts in range(hs, hs + H, 300):
            put(device, ts, 2000, 500)
        wx[hs] = {"rad_wm2": 800.0, "cloud_pct": 20}
    put(device, start + 12 * H, 0, 500)
    assert outlook.calibrate(device, wx) == pytest.approx(2.0 / 0.8, rel=0.01)


# ------------------------------------------------------------- scenarios --
def history(device, days=15, peak_w=3000, load_w=500):
    """Finished days of a clear-sky PV curve and flat home use, every 10 min."""
    for k in range(days, 0, -1):
        t0 = energy.local_midnight(energy.today() - timedelta(days=k))
        for ts in range(t0, t0 + 86400, 600):
            lt = energy.to_local(ts)
            put(device, ts, max(0.0, math.sin((lt.hour + lt.minute / 60 - 6) / 12 * math.pi)) * peak_w, load_w)


def forecast_with_cloudy_tomorrow(factor=0.2):
    now = time.time()
    start = int(now // H * H)
    tomorrow = energy.today() + timedelta(days=1)
    return {start + i * H: {"rad_wm2": 1000 * clear_sky(start + i * H) * (factor if energy.to_local(start + i * H).date() == tomorrow else 1.0),
                            "cloud_pct": 90 if energy.to_local(start + i * H).date() == tomorrow else 10}
            for i in range(-7 * 24, 3 * 24)}


@pytest.fixture
def no_weather(monkeypatch):
    monkeypatch.setattr(weather, "_cache", None)


def test_cloudy_tomorrow_is_called_out(device, no_weather):
    history(device)
    put(device, int(time.time()) - 30, 0, 500, soc=40)
    weather.set_hours(forecast_with_cloudy_tomorrow())
    o = outlook.outlook(device, {"battery_kwh": 10, "rate_php_per_kwh": 15.06})
    assert o["source"] == "weather" and len(o["hours"]) == 48
    assert o["solar_typical_kwh"] == pytest.approx(3 * 12 * 2 / math.pi, rel=0.03)  # ∫ 3 kW sin curve over 12 h
    assert o["solar_tomorrow_kwh"] < 0.3 * o["solar_typical_kwh"]
    assert o["battery"]["tomorrow_max_soc_pct"] < 90
    assert "Maulap" in o["advice"]


def test_without_weather_it_falls_back_to_history(device, no_weather):
    history(device)
    put(device, int(time.time()) - 30, 0, 500, soc=40)
    o = outlook.outlook(device, {"battery_kwh": 10, "rate_php_per_kwh": 15.06})
    assert o["source"] == "history"
    assert o["solar_tomorrow_kwh"] == pytest.approx(o["solar_typical_kwh"], rel=0.01)
    assert all(h["cloud_pct"] is None for h in o["hours"])
    assert "Walang weather forecast" in o["advice"]


def test_brownout_advice_counts_the_forecast_sun(device, no_weather):
    history(device)
    now = int(time.time())
    put(device, now - 30, 0, 800, soc=60, grid_on=False)
    db.execute("INSERT INTO outages (device_id, start_ts) VALUES (?, ?)", (device, now - 600))
    o = outlook.outlook(device, {"battery_kwh": 10, "rate_php_per_kwh": 15.06})
    assert o["brownout"]["active"]
    b = energy.brownout(device, {"battery_kwh": 10, "rate_php_per_kwh": 15.06})
    assert "Kasama ang forecast na araw" in b["advice"]


def test_no_telemetry_still_gives_a_solar_outlook(device, no_weather):
    o = outlook.outlook(device, {"battery_kwh": 10, "rate_php_per_kwh": 15.06})
    assert o["brownout"] is None and o["battery"]["soc_pct"] is None
    assert o["advice"]


# -------------------------------------------------------------------- AI --
@pytest.mark.parametrize("q", ["Maulap ba bukas?", "Tatagal ba ang battery ko mamaya?", "Uulan ba, mapupuno ba ang battery?"])
def test_weather_and_battery_questions_get_the_outlook(q):
    assert "outlook" in router.topics_for(q, set())


def test_outlook_facts_are_gathered(device, no_weather):
    history(device, days=3)
    put(device, int(time.time()) - 30, 0, 500, soc=40)
    ids = facts.gather(device, {"battery_kwh": 10, "rate_php_per_kwh": 15.06, "user_name": "Juan"}).by_id()
    assert {"outlook.solar_tomorrow_kwh", "outlook.battery_reserve", "outlook.brownout_until", "outlook.advice"} <= set(ids)


@pytest.mark.parametrize("q", ["Ano ang forecast ng solar bukas?", "Forecast ng araw bukas?", "Ano ang weather forecast?"])
def test_solar_forecast_questions_are_not_bill_questions(q):
    assert router.bill_intent(q) is None
    topics = router.topics_for(q, set())
    assert "outlook" in topics and "bill" not in topics


@pytest.mark.parametrize("q,intent", [("Magkano ang forecast ng bill ko?", "forecast"),
                                      ("Ano forecast ng bill ko ngayong buwan?", "forecast"),
                                      ("Magkano ang forecast kahit may solar?", "forecast")])
def test_bill_forecast_questions_stay_bill_questions(q, intent):
    assert router.bill_intent(q) == intent
