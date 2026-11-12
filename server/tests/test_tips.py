"""Solar tips (/api/tips): each rule fires on the situation it's meant for, and only then."""
from datetime import date

from app import config, db, energy, tips
from solaris_contract import validate

DAY = date(2026, 11, 12)                   # a Thursday
NOON = energy.local_midnight(DAY) + 12 * 3600


def at(hour: float, d: date = DAY) -> float:
    return energy.local_midnight(d) + hour * 3600


def live(**over):
    base = {"ts": NOON, "pv_w": 1500, "load_w": 1200, "grid_w": 0, "batt_soc": 60, "batt_w": -300,
            "grid_on": 1, "inv_temp_c": 40, "fault_code": 0}
    return base | over


def usage(**over):
    base = {"export_kwh_day": 0.2, "night_import_kwh_day": 0.3, "day_import_kwh_day": 0.2}
    return base | over


def hours_from(start_ts: float, pv: list[float], load: float = 0.4) -> list[dict]:
    """Outlook-style hours starting at start_ts, with the given PV kWh per hour."""
    start = int(start_ts // 3600 * 3600)
    return [{"ts": start + i * 3600, "pv_kwh": p, "load_kwh": load} for i, p in enumerate(pv)]


def sunny_day(start_ts: float, n: int = 48) -> list[dict]:
    """PV bell from 6 AM to 6 PM (peak 3 kWh at noon) for n hours from start_ts."""
    out = []
    for h in hours_from(start_ts, [0.0] * n):
        hr = energy.to_local(h["ts"]).hour
        h["pv_kwh"] = max(0.0, 3.0 - abs(hr - 12) * 0.5) if 6 <= hr < 18 else 0.0
        out.append(h)
    return out


def run(now=NOON, **kw):
    args = {"live": None, "window": None, "solar_tomorrow": None, "solar_typical": None, "usage": None,
            "shape": None, "rate": 15.0} | kw
    out = tips.build(now=now, **args)
    validate("tips", {"generated_ts": int(now), "best_window": args["window"], "impact": None, "tips": out})
    return out


def ids(out):
    return [t["id"] for t in out]


# ------------------------------------------------------------------- now --
def test_nothing_to_say_still_gives_one_general_tip():
    out = run()
    assert ids(out) == ["general"] and out[0]["priority"] == 1 and out[0]["kind"] == "general"


def test_general_tip_changes_daily():
    a = run(now=at(12))[0]["title"]
    b = run(now=at(12, date(2026, 11, 13)))[0]["title"]
    assert a != b


def test_surplus_with_full_battery_says_use_it_now():
    out = run(live=live(pv_w=3200, load_w=900, batt_soc=97, batt_w=-100))
    assert ids(out)[0] == "surplus_now"
    t = out[0]
    assert t["kind"] == "now" and "3.2 kW" in t["body"] and "900 W" in t["body"] and "97%" in t["body"]


def test_surplus_going_to_grid_says_use_it_now():
    out = run(live=live(pv_w=3000, load_w=1000, batt_soc=70, batt_w=-800, grid_w=-1200))
    assert ids(out)[0] == "surplus_now" and "1.2 kW" in out[0]["body"]


def test_surplus_still_charging_the_battery_is_not_a_tip():
    # The sun is filling the battery for tonight: running more appliances now would take from that.
    assert "surplus_now" not in ids(run(live=live(pv_w=3200, load_w=900, batt_soc=60, batt_w=-2300)))


def test_no_now_tips_in_a_brownout_or_fault():
    assert ids(run(live=live(pv_w=3200, load_w=900, batt_soc=97, grid_on=0))) == ["general"]
    assert ids(run(live=live(pv_w=3200, load_w=900, batt_soc=97, fault_code=3))) == ["general"]


def test_grid_now_points_to_the_sunny_window_ahead():
    now = at(7)
    window = tips.best_window(sunny_day(now), now)
    out = run(now=now, live=live(pv_w=200, load_w=900, grid_w=700, batt_soc=20, batt_w=0), window=window)
    assert ids(out)[:2] == ["grid_now", "best_window"]
    assert "700 W" in out[0]["body"] and "mamaya, 11AM hanggang 2PM" in out[0]["body"]


def test_grid_now_needs_a_window_ahead():
    assert "grid_now" not in ids(run(live=live(pv_w=0, load_w=900, grid_w=900, batt_soc=20, batt_w=0)))


# ----------------------------------------------------------------- today --
def test_best_window_is_the_sunniest_three_hours_today():
    now = at(7)
    w = tips.best_window(sunny_day(now), now)
    # Surplus per hour = pv - 0.4: 11AM 2.1, noon 2.6, 1PM 2.1 -> 6.8 kWh (ties go to the earliest).
    assert w["day"] == "today" and w["surplus_kwh"] == 6.8
    assert energy.to_local(w["start_ts"]).hour == 11 and w["end_ts"] - w["start_ts"] == 3 * 3600


def test_best_window_moves_to_tomorrow_after_sunset():
    now = at(19)
    w = tips.best_window(sunny_day(now), now)
    assert w["day"] == "tomorrow" and energy.to_local(w["start_ts"]).date() == date(2026, 11, 13)
    out = run(now=now, window=w)
    assert out[0]["id"] == "best_window" and out[0]["title"].startswith("Pinakamaaraw bukas: 11AM")


def test_window_already_started_says_now():
    now = at(11.5)
    w = tips.best_window(sunny_day(now), now)
    assert w["start_ts"] <= now
    out = run(now=now, window=w)
    assert out[0]["title"].startswith("Pinakamaaraw ngayon") and "ngayon, " in out[0]["body"]


def test_surplus_now_replaces_a_window_that_is_happening_now():
    now = at(11.5)
    w = tips.best_window(sunny_day(now), now)
    out = run(now=now, window=w, live=live(pv_w=3200, load_w=900, batt_soc=97, batt_w=-100))
    assert "surplus_now" in ids(out) and "best_window" not in ids(out)


def test_no_window_when_the_sun_barely_covers_use():
    now = at(7)
    assert tips.best_window(hours_from(now, [0.5] * 48, load=0.4), now) is None


def test_cloudy_tomorrow_during_the_day_only():
    out = run(now=at(10), solar_tomorrow=5.0, solar_typical=17.0)
    assert ids(out)[0] == "cloudy_tomorrow" and "5 kWh" in out[0]["body"] and "17 kWh" in out[0]["body"]
    assert "cloudy_tomorrow" not in ids(run(now=at(20), solar_tomorrow=5.0, solar_typical=17.0))
    assert "cloudy_tomorrow" not in ids(run(now=at(10), solar_tomorrow=15.0, solar_typical=17.0))


# ----------------------------------------------------------------- habit --
def test_exported_sun_and_grid_nights_means_shift_to_day():
    out = run(usage=usage(export_kwh_day=4.4, night_import_kwh_day=3.7))
    t = out[0]
    assert t["id"] == "shift_to_day" and t["kind"] == "habit"
    assert t["savings_php_month"] == round(3.7 * 15 * 30)              # only what the nights could take
    assert "4.4" in t["body"] and "3.7" in t["body"] and "₱1,665" in t["body"]


def test_grid_while_sunny_means_spread_loads():
    out = run(usage=usage(day_import_kwh_day=2.1))
    assert ids(out) == ["spread_loads", "general"] and "2.1" in out[0]["body"]
    assert out[0]["savings_php_month"] is None


def test_heavy_evenings_with_spare_sun_means_precool():
    shape = {"evening_kwh_h": 1.6, "midday_kwh_h": 0.3}
    assert "precool" in ids(run(usage=usage(export_kwh_day=3.0), shape=shape))
    assert "precool" not in ids(run(usage=usage(export_kwh_day=0.2), shape=shape))     # no spare sun
    assert "precool" not in ids(run(usage=usage(export_kwh_day=3.0), shape={"evening_kwh_h": 0.5, "midday_kwh_h": 0.4}))


def test_order_now_then_today_then_habits_by_savings_then_general_and_capped():
    now = at(10)
    w = tips.best_window(sunny_day(now), now)
    out = run(now=now, window=w, live=live(pv_w=3200, load_w=900, batt_soc=97, batt_w=-100),
              solar_tomorrow=5.0, solar_typical=17.0,
              usage=usage(export_kwh_day=4.4, night_import_kwh_day=3.7, day_import_kwh_day=2.0),
              shape={"evening_kwh_h": 1.6, "midday_kwh_h": 0.3})
    assert len(out) == tips.MAX_TIPS
    assert [t["kind"] for t in out] == ["now", "today", "today", "habit", "habit", "general"]
    assert ids(out)[3] == "shift_to_day"                                  # the one with savings first
    assert [t["priority"] for t in out] == list(range(1, tips.MAX_TIPS + 1))


# ---------------------------------------------------------------- impact --
def test_impact_is_solar_times_grid_emission_factor(monkeypatch, device):
    monkeypatch.setattr(energy, "totals", lambda *a: {**energy._zero(), "pv_kwh": 300.0, "load_kwh": 400.0,
                                                      "grid_import_kwh": 100.0})
    monkeypatch.setattr(config, "GRID_CO2_KG_PER_KWH", 0.71)
    i = tips.impact(device)
    assert i["solar_kwh"] == 300.0 and i["co2_avoided_kg"] == 213.0 and i["clean_share_pct"] == 75.0
    assert i["trees"] == round(213 / tips.TREE_KG_CO2_YEAR)


def test_no_impact_before_any_solar(device):
    assert tips.impact(device) is None


def test_real_endpoint_matches_contract_on_seeded_history(client):
    r = client.get("/api/tips")
    assert r.status_code == 200, r.text
    body = r.json()
    validate("tips", body)
    assert body["impact"] is not None and body["impact"]["solar_kwh"] > 0
    assert body["tips"][-1]["kind"] == "general"

