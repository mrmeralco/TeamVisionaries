"""SPEC: SARIMA daily-kWh forecast (app/sarima.py) and how the bill uses it (energy.forecast_days).

  fit      log(1 + kWh) with a weekly cycle; None when there's < 4 weeks of data or nothing varies
  predict  mean of residual-bootstrap paths per day (never negative) + the paths for the range
  bill     SARIMA by default, weekday/weekend averages as the fallback or with FORECAST_METHOD=average
"""
from datetime import date, timedelta

import numpy as np
import pytest

from app import config, db, energy, sarima


def put_days(device, kwh: list, end: date):
    """kwh[i] of grid import on the days before `end` (the last value is the day before end)."""
    base = {"pv_w": 0, "batt_soc": 50, "batt_w": 0, "grid_on": True, "inv_temp_c": 40, "fault_code": 0}
    for i, k in enumerate(kwh):
        t0 = energy.local_midnight(end - timedelta(days=len(kwh) - i)) + 8 * 3600
        w = int(k * 1000)
        for ts in range(t0, t0 + 3600, 300):
            db.insert_telemetry(device, base | {"ts": ts, "load_w": max(w, 1), "grid_w": w})
        db.insert_telemetry(device, base | {"ts": t0 + 3600, "load_w": 1, "grid_w": 0})


def weekly(days: int, weekday=3.0, weekend=8.0, noise=0.5, seed=1) -> list[float]:
    """Daily kWh with a clear weekly cycle: days 5 and 6 of each week are weekends."""
    rng = np.random.default_rng(seed)
    return [max(0.0, (weekend if i % 7 >= 5 else weekday) + rng.normal(0, noise)) for i in range(days)]


def test_needs_four_weeks_of_data():
    assert sarima.fit(weekly(27)) is None
    assert sarima.fit(weekly(27) + [None] * 10) is None  # days without data don't count
    assert sarima.fit(weekly(28)) is not None


def test_a_flat_series_is_left_to_the_averages():
    assert sarima.fit([4.0] * 56) is None


def test_learns_the_weekly_cycle():
    res = sarima.fit(weekly(56))  # ends on a weekend day (55 % 7 == 6): next 5 are weekdays
    mean, paths = sarima.predict(res, 7)
    assert mean[:5].max() < 5 < mean[5:].min()
    assert mean[5:].mean() == pytest.approx(8.0, rel=0.15)
    assert paths.shape == (7, sarima.SIMS) and (paths >= 0).all()


def test_missing_days_are_skipped_not_zero():
    full = sarima.predict(sarima.fit(weekly(56)), 7)[0]
    gappy = weekly(56)
    for i in (10, 11, 12, 30):
        gappy[i] = None
    assert sarima.predict(sarima.fit(gappy), 7)[0].sum() == pytest.approx(full.sum(), rel=0.1)


def test_range_reflects_how_much_days_vary():
    calm = sarima.predict(sarima.fit(weekly(56, noise=0.3)), 14)[1].sum(axis=0)
    wild = sarima.predict(sarima.fit(weekly(56, noise=2.0, seed=2)), 14)[1].sum(axis=0)
    assert np.std(wild) > 2 * np.std(calm)


def test_describe():
    assert sarima.describe(sarima.fit(weekly(56))).startswith("SARIMA(")


# ------------------------------------------------------------------- bill --
def test_bill_uses_sarima_with_enough_history(client):
    s = db.get_settings()
    b = energy.bill(s["device_id"], s)  # seeded with 40 days in conftest
    assert b["forecast_method"] == "sarima" and b["forecast_model"].startswith("SARIMA(")
    assert b["month_to_date_php"] <= b["forecast_low_php"] <= b["forecast_php"] <= b["forecast_high_php"]


def test_average_fallback_without_statsmodels(device, monkeypatch):
    monkeypatch.setattr(sarima, "available", lambda: False)
    put_days(device, weekly(40), end=energy.today())
    fc = energy.forecast_days(device, energy.today(), 5)
    assert fc["method"] == "average" and fc["totals"] is None


def test_forecast_method_setting(device, monkeypatch):
    put_days(device, weekly(40), end=energy.today())
    sarima._cache.clear()
    assert energy.forecast_days(device, energy.today(), 5)["method"] == "sarima"
    monkeypatch.setattr(config, "FORECAST_METHOD", "average")
    assert energy.forecast_days(device, energy.today(), 5)["method"] == "average"


def test_today_is_never_forecast_below_what_was_already_used(device):
    put_days(device, weekly(40), end=energy.today())
    fc = energy.forecast_days(device, energy.today(), 3, today_kwh=50.0)
    assert fc["kwh"][0] == 50.0 and (fc["totals"] >= 50.0).all()


def test_history_is_divided_by_the_season_factor(device):
    from app import tariff
    d = date(2026, 4, 20)
    put_days(device, [3.0] * 3, end=d)
    hist = energy.daily_history(device, d, 3)
    assert [x for x, _ in hist] == [d - timedelta(days=i) for i in (3, 2, 1)]
    assert hist[-1][1] == pytest.approx(3.0 / tariff.season_factor(d - timedelta(days=1)), rel=0.01)
