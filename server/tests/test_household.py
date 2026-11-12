"""Household profile (/api/household): routine and occupancy from home use alone, and new appliance-sized loads.

Most tests build synthetic households as 15-minute slots (no DB), so each pattern is exactly what the rule
is meant for. One test goes through SQLite and the real endpoint.
"""
import random
import time
from datetime import date, timedelta

from app import db, energy, household as H
from solaris_contract import validate

TODAY = date(2026, 11, 12)          # a Thursday
RATE = 15.0


def worker(d: date, h: float) -> float:
    """Out 9 to 6 on weekdays, home on weekends; up at 7, aircon + TV 6-11 PM (like tools/seed_history.py)."""
    w = 300.0
    if 18 <= h < 23:
        w += 1400
    elif 7 <= h < 9:
        w += 600
    elif d.weekday() >= 5 and 10 <= h < 17:
        w += 800
    return w


def make_days(load, n: int = 35, today: date = TODAY, noise: float = 40, seed: int = 1,
              extra=lambda d, h: 0.0) -> dict:
    rnd = random.Random(seed)
    out = {}
    for i in range(n, 0, -1):
        d = today - timedelta(days=i)
        slots = []
        for k in range(H.SLOTS_DAY):
            h = k / 4
            a = load(d, h) + extra(d, h) + rnd.uniform(-noise, noise)
            slots.append((a, a - noise / 2, a + noise / 2))
        out[d] = slots
    return out


def full(days: dict, now_state: dict | None = None) -> dict:
    p = H.profile(days, TODAY, RATE)
    p.pop("threshold_w")
    out = {"generated_ts": int(time.time()), "now": now_state or H.now_status(None, False, time.time(), p["routine"], None), **p}
    validate("household", out)
    return out


def new_after(days_ago: int, watts: float, a: float, b: float):
    """A load of `watts` between hours a and b (wrapping midnight) from `days_ago` days before TODAY."""
    start = TODAY - timedelta(days=days_ago)

    def f(d: date, h: float) -> float:
        on = (a <= h < b) if a < b else (h >= a or h < b)
        return watts if d >= start and on else 0.0
    return f


# --------------------------------------------------------------- routine --
def test_nine_to_six_worker():
    p = full(make_days(worker))
    wd, we = p["routine"]["weekday"], p["routine"]["weekend"]
    assert (wd["wake_hour"], wd["sleep_hour"]) == (7, 23)
    assert wd["away"] == {"start_hour": 9, "end_hour": 18}
    assert we["away"] is None and we["home_pct"][12] == 100
    assert p["archetype"]["id"] == "away_daytime" and "9AM hanggang 6PM" in p["archetype"]["description"]
    assert {t["id"] for t in p["traits"]} >= {"evening_peak", "weekend_home", "high_baseload"}
    assert p["confidence"] == "high" and p["days_used"] == 28
    assert 260 <= p["baseload"]["watts"] <= 310
    assert p["new_loads"] == []


def test_someone_home_all_day():
    p = full(make_days(lambda d, h: 250 + (700 if 6 <= h < 22 else 0)))
    assert p["archetype"]["id"] == "home_daytime"
    assert p["routine"]["weekday"]["away"] is None
    assert (p["routine"]["weekday"]["wake_hour"], p["routine"]["weekday"]["sleep_hour"]) == (6, 22)


def test_aircon_all_night_has_no_sleep_hour_but_says_why():
    p = full(make_days(lambda d, h: 200 + (900 if h >= 19 or h < 6 else 0) + (500 if 6 <= h < 8 else 0)))
    wd = p["routine"]["weekday"]
    assert wd["sleep_hour"] is None
    assert "night_load" in {t["id"] for t in p["traits"]}


def test_too_few_days_is_honest():
    p = full(make_days(worker, n=2))
    assert p["confidence"] == "none" and p["routine"] == {"weekday": None, "weekend": None}
    assert p["archetype"]["id"] == "unknown" and p["baseload"] is None and p["new_loads"] == []


# ------------------------------------------------------------------- now --
def _profiles():
    p = H.profile(make_days(worker), TODAY, RATE)
    return p["routine"], p["threshold_w"]


def at(hour: float, d: date = TODAY) -> float:
    return energy.local_midnight(d) + hour * 3600


def test_now_active_in_the_evening_is_home_and_usual():
    routine, thr = _profiles()
    n = H.now_status((1600, 1500, 1700), True, at(20), routine, thr)
    assert (n["state"], n["likely_home"], n["unusual"]) == ("active", True, False)
    assert n["load_w"] == 1600 and "1.6 kW" in n["text"]


def test_now_quiet_on_a_weekday_afternoon_is_away_until_six():
    routine, thr = _profiles()
    n = H.now_status((300, 280, 320), True, at(14), routine, thr)
    assert (n["state"], n["likely_home"]) == ("away", False)
    assert n["next_active_ts"] == at(18) and "6PM" in n["text"]


def test_now_quiet_at_night_is_asleep():
    routine, thr = _profiles()
    n = H.now_status((300, 280, 320), True, at(2), routine, thr)
    assert (n["state"], n["likely_home"]) == ("asleep", True)


def test_now_busy_when_the_house_is_usually_empty_is_unusual():
    routine, thr = _profiles()
    n = H.now_status((1200, 1100, 1300), True, at(13), routine, thr)
    assert n["state"] == "active" and n["unusual"] and "Hindi ito karaniwan" in n["text"]


def test_now_quiet_at_a_usually_busy_hour_might_be_out():
    routine, thr = _profiles()
    n = H.now_status((300, 280, 320), True, at(20), routine, thr)
    assert (n["state"], n["likely_home"]) == ("quiet", False)


def test_now_power_swinging_inside_the_slot_counts_as_someone_home():
    routine, thr = _profiles()
    assert H.now_status((350, 250, 1900), True, at(14), routine, thr)["state"] == "active"  # kettle, microwave


def test_now_offline_is_unknown():
    routine, thr = _profiles()
    n = H.now_status((1600, 1500, 1700), False, at(20), routine, thr)
    assert n["state"] == "unknown" and n["likely_home"] is None and n["load_w"] is None


def test_weekend_uses_the_weekend_routine():
    routine, thr = _profiles()
    saturday = TODAY + timedelta(days=2)
    assert H.now_status((300, 280, 320), True, at(13, saturday), routine, thr)["state"] == "quiet"


# -------------------------------------------------------- new appliances --
def test_new_aircon_at_night_is_found_with_its_hours_and_start():
    p = full(make_days(worker, extra=new_after(5, 1100, 21, 2)))
    [n] = p["new_loads"]
    assert n["kind"] == "scheduled" and (n["start_hour"], n["end_hour"]) == (21, 2)
    assert 1000 <= n["added_w"] <= 1200 and n["guess"] == "aircon"
    assert n["since_ts"] == energy.local_midnight(TODAY - timedelta(days=5)) and n["days_seen"] == 5
    assert n["php_month"] == round(n["kwh_day"] * 30 * RATE)
    assert "9PM–2AM" in n["text"] and "aircon" in n["text"]


def test_new_always_on_load_is_a_baseload_rise_not_24_blocks():
    p = full(make_days(worker, extra=new_after(4, 150, 0, 24)))
    [n] = p["new_loads"]
    assert n["kind"] == "always_on" and n["start_hour"] is None
    assert 120 <= n["added_w"] <= 180 and "ref" in n["guess"]
    assert n["since_ts"] == energy.local_midnight(TODAY - timedelta(days=4))


def test_new_water_heater_in_the_morning():
    p = full(make_days(worker, extra=new_after(6, 3000, 6, 7)))
    [n] = p["new_loads"]
    assert (n["start_hour"], n["end_hour"]) == (6, 7) and "water heater" in n["guess"]


def test_one_busy_evening_is_not_a_new_appliance():
    party = TODAY - timedelta(days=1)
    p = full(make_days(worker, extra=lambda d, h: 2000 if d == party and 18 <= h < 24 else 0))
    assert p["new_loads"] == []


def test_noisy_steady_home_has_no_new_loads():
    for seed in range(5):
        assert full(make_days(worker, noise=150, seed=seed))["new_loads"] == []


def test_a_change_older_than_the_window_is_the_new_normal():
    p = full(make_days(worker, extra=new_after(30, 1100, 21, 2)))
    assert p["new_loads"] == []


def test_small_new_loads_are_ignored():
    p = full(make_days(worker, extra=new_after(5, 120, 20, 22)))     # a fan for 2 hours: 0.24 kWh
    assert p["new_loads"] == []


# --------------------------------------------------------------- endpoint --
def test_endpoint_through_sqlite(client, device):
    """Ten days of a 9-to-6 household written as telemetry, read back through history() and the endpoint."""
    now = int(time.time())
    today = energy.to_local(now).date()
    start = energy.local_midnight(today - timedelta(days=10))
    rows = []
    for ts in range(start, now, 300):
        lt = energy.to_local(ts)
        load = worker(lt.date(), lt.hour + lt.minute / 60)
        rows.append((device, ts, 0, round(load), round(load), 50, 0, 1, 35, 0))
    rows.append((device, now, 0, 1500, 1500, 50, 0, 1, 35, 0))   # a fresh reading: the device is online
    with db._lock:
        db.conn().executemany("INSERT INTO telemetry (device_id, ts, pv_w, load_w, grid_w, batt_soc, batt_w, grid_on, "
                              "inv_temp_c, fault_code) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", rows)
    days = H.history(device, today, 10)
    assert len(days) == 10 and all(len(v) == H.SLOTS_DAY and all(v) for v in days.values())

    out = H.household(device, {"rate_php_per_kwh": RATE})
    validate("household", out)
    assert out["days_used"] == 10 and out["confidence"] == "medium"
    assert out["now"]["state"] != "unknown" and out["now"]["load_w"] is not None

    r = client.get("/api/household")
    assert r.status_code == 200
    validate("household", r.json())


# ------------------------------------------------------------------ Mira --
def test_mira_gets_household_facts_and_the_new_appliance_answers_bill_questions(monkeypatch):
    """Example payload in, grounded facts out: "is anyone home?" and "why did my bill go up?"."""
    import json

    from ai import facts as F, router, service
    from app import config

    ex = json.loads((config.EXAMPLES_DIR / "household.json").read_text())
    monkeypatch.setattr(F.household, "household", lambda dev, s: ex)
    s = db.get_settings()
    fs = service.gather(s["device_id"], s)
    by = fs.by_id()
    assert {"household.now", "household.routine", "household.baseload", "household.new_load"} <= set(by)
    assert "9AM hanggang 6PM" in by["household.routine"].text and "11PM" in by["household.routine"].text
    assert by["household.new_load"].topic == "usage" and 1100 in by["household.new_load"].values

    q = "May tao ba sa bahay ngayon?"
    reply, ids = service.fallback_reply(router.topics_for(q, set()), set(), fs)
    assert ids[0] == "household.now" and "walang tao" in reply

    q = "Bakit biglang tumaas ang gamit namin?"
    reply, ids = service.fallback_reply(router.topics_for(q, set()), set(), fs)
    assert ids[0] == "household.new_load" and "aircon" in reply


def test_why_is_my_bill_high_keeps_the_new_appliance_in_the_prompt():
    from ai import router
    from ai.facts import Fact
    fs = [Fact("bill.forecast_php", "bill", "x"), Fact("usage.peak_hours", "usage", "x"),
          Fact("week.grid_kwh", "usage", "x"), Fact("household.new_load", "usage", "x")]
    ids = {f.id for f in router.select_facts("Bakit mataas ang bill ko?", fs)}
    assert {"usage.peak_hours", "household.new_load"} <= ids and "week.grid_kwh" not in ids
