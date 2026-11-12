"""Smart meter mode (settings `setup`): a home with only a meter, with solar and a meter, or solar only.

conftest.py seeds solaris-001 with inverter telemetry AND its Meralco meter (ansi-c12), and meter-001 with
meter readings only (a home without solar). Each test switches settings and puts them back.
"""
import asyncio
import json
import re
import time
from datetime import timedelta

import pytest
from conftest import METER_ONLY_DEVICE
from fastapi.testclient import TestClient
from solaris_contract import validate

from ai import facts, guard, service
from ai.guard import NO_SOLAR_WORDS
from app import alerts, db, energy, ingest, meter, mock, projection, tariff
from app import schemas as S
from app.main import app

SOLAR_WORDS = NO_SOLAR_WORDS


@pytest.fixture
def client():
    return TestClient(app)  # no lifespan: no MQTT, no LLM warm-up


@pytest.fixture
def setup_mode():
    """setup_mode("meter_only") -> settings for that household; restored afterwards."""
    before = db.get_settings()

    def use(setup: str, device: str | None = None) -> dict:
        dev = device or (METER_ONLY_DEVICE if setup == "meter_only" else "solaris-001")
        return db.put_settings({"setup": setup, "device_id": dev})

    yield use
    db.put_settings(before)


def meter_payload(**kw) -> bytes:
    return json.dumps({"ts": int(time.time()), "meter_type": "sdm120", "voltage_v": 229.5, "current_a": 4.1,
                       "power_w": 850, "pf": 0.93, "freq_hz": 60.0, "import_kwh": 3001.5, "export_kwh": 0.0,
                       "grid_on": True} | kw).encode()


# ---------------------------------------------------------------- settings --
def test_setup_is_a_setting(client, setup_mode):
    setup_mode("solar")
    assert client.get("/api/settings").json()["setup"] == "solar"
    r = client.put("/api/settings", json={"setup": "meter_only"})
    assert r.status_code == 200 and r.json()["setup"] == "meter_only"
    assert client.get("/api/settings").json()["setup"] == "meter_only"
    assert client.put("/api/settings", json={"setup": "wind"}).status_code == 422


def test_unknown_stored_setup_counts_as_solar():
    assert energy.setup({"setup": "bogus"}) == "solar"
    assert energy.setup({}) == "solar"


# --------------------------------------------------------------- meter only --
def test_meter_only_live_comes_from_the_meter(client, setup_mode):
    setup_mode("meter_only")
    live = client.get("/api/live").json()
    validate("live", live)
    S.Live.model_validate(live)
    assert live["setup"] == "meter_only" and live["telemetry"] is None
    assert live["meter"]["meter_type"] == "sdm120"
    assert live["state"] in {"grid", "brownout", "offline"}
    assert live["saved_today_php"] == 0
    assert not SOLAR_WORDS.search(live["status_line"])


def test_meter_only_live_state_lines():
    online = {"online": True}
    m = {"ts": int(time.time()), "power_w": 1450.0, "grid_on": True}
    assert energy.meter_state_and_line(online, m) == ("grid", "Kumukuha ang bahay mo ng 1.4 kW mula sa grid ngayon.")
    assert energy.meter_state_and_line(online, m | {"grid_on": False})[0] == "brownout"
    assert energy.meter_state_and_line({"online": False}, m)[0] == "offline"
    assert energy.meter_state_and_line(online, None)[0] == "offline"


def test_meter_only_energy_is_all_grid(client, setup_mode):
    setup_mode("meter_only")
    for period in ("day", "week", "month"):
        e = client.get(f"/api/energy?period={period}").json()
        validate("energy", e)
        t = e["totals"]
        assert t["pv_kwh"] == t["batt_charge_kwh"] == t["batt_discharge_kwh"] == t["grid_export_kwh"] == 0
        assert t["load_kwh"] == pytest.approx(t["grid_import_kwh"]) and t["load_kwh"] > 0
        assert e["self_sufficiency_pct"] == 0


def test_meter_only_bill_is_priced_from_meter_kwh(client, setup_mode):
    s = setup_mode("meter_only")
    b = client.get("/api/bill").json()
    validate("bill", b)
    assert b["grid_source"] == "meter"
    assert b["savings_today_php"] == 0 and b["savings_month_php"] == 0
    d = energy.today()
    mtd = sum(energy.day_totals(METER_ONLY_DEVICE, d.replace(day=i), "meter")["grid_import_kwh"] for i in range(1, d.day + 1))
    assert b["month_to_date_kwh"] == pytest.approx(mtd, abs=0.01)
    full = energy.bill(METER_ONLY_DEVICE, s)
    assert b["forecast_php"] == pytest.approx(tariff.cost(full["forecast_kwh"], s["rate_php_per_kwh"]), abs=1)
    assert b["forecast_low_php"] <= b["forecast_php"] <= b["forecast_high_php"]
    assert b["last_month_php"] is not None   # 40 days seeded


def test_meter_only_forecast_follows_aircon_season_not_solar(setup_mode, monkeypatch):
    s = setup_mode("meter_only")
    from app import outlook
    monkeypatch.setattr(outlook, "profiles", lambda *_: pytest.fail("a meter-only forecast must not simulate solar"))
    hist = energy.daily_history(METER_ONLY_DEVICE, energy.today(), 28, "meter")
    assert energy.recent_level(METER_ONLY_DEVICE, energy.today(), 10, hist, s) > 0


def test_meter_only_projection_has_no_solar(client, setup_mode):
    setup_mode("meter_only")
    p = client.get("/api/bill/projection").json()
    validate("bill_projection", p)
    assert p["enough_data"] is True and len(p["months"]) == 1 + projection.MAX_MONTHS
    for m in p["months"][1:]:
        assert m["solar_kwh"] == 0 and m["load_kwh"] == m["grid_kwh"]
        assert m["low_kwh"] <= m["grid_kwh"] <= m["high_kwh"]
        assert m["range_pct"] < 100   # whole-home use: narrower than a solar home's leftover grid use


def test_meter_only_brownout_has_no_battery(client, setup_mode):
    setup_mode("meter_only")
    bo = client.get("/api/brownout").json()
    validate("brownout", bo)
    assert bo["batt_soc"] is None and bo["runtime_h"] is None and bo["load_w"] is None
    assert not SOLAR_WORDS.search(bo["advice"])
    assert bo["outages_this_month"] >= 0


# ------------------------------------------------------------- /api/meter --
def test_meter_endpoint_meter_only(client, setup_mode):
    setup_mode("meter_only")
    r = client.get("/api/meter").json()
    validate("meter_info", r)
    S.MeterInfo.model_validate(r)
    assert r["setup"] == "meter_only" and r["reading"]["meter_type"] == "sdm120"
    u, t, q = r["usage"], r["tier"], r["quality"]
    assert u["days"] == 7 and len(u["by_hour_kwh"]) == 24
    assert u["import_kwh_day"] == pytest.approx(sum(u["by_hour_kwh"]), rel=0.01)
    assert 0 < u["base_w"] <= u["peak_w"]
    assert all(18 <= h or h < 6 for h in u["peak_hours"])   # the seeded home peaks at night (air-con)
    # The tier is the bill's forecast, placed in Meralco's levels.
    b = client.get("/api/bill").json()
    assert t["month_to_date_kwh"] == b["month_to_date_kwh"]
    lo, hi, _ = tariff.bracket(t["forecast_kwh"])
    assert (t["level_min_kwh"], t["level_max_kwh"]) == (lo, hi)
    assert q["low_limit_v"] < q["avg_v_24h"] < q["high_limit_v"]
    ids = [i["id"] for i in r["insights"]]
    assert ids[-1] == "reading" and any(i.startswith("tier") for i in ids)
    for ins in r["insights"]:
        assert not SOLAR_WORDS.search(ins["body"]), ins


def test_meter_insight_numbers_come_from_the_response(client, setup_mode):
    setup_mode("meter_only")
    r = client.get("/api/meter").json()
    tier = next(i for i in r["insights"] if i["id"].startswith("tier"))
    assert f"{r['tier']['forecast_kwh']:.0f} kWh" in tier["body"]
    base = next(i for i in r["insights"] if i["id"] == "base_load")
    assert f"{r['usage']['base_w']} W" in base["body"]
    reading = next(i for i in r["insights"] if i["id"] == "reading")
    assert f"{r['reading']['import_kwh']:,.1f}" in reading["title"]


def test_tier_insights():
    def insights(fc, days_left=10):
        lo, hi, _ = tariff.bracket(fc)
        t = {"forecast_kwh": fc, "level_min_kwh": lo, "level_max_kwh": hi, "days_left": days_left,
             "kwh_above_lower_level": fc - lo if lo else None,
             "save_php_at_lower_level": round(tariff.cost(fc, 13) - tariff.cost(lo, 13)) if lo else None,
             "kwh_to_next_level": hi - fc if hi else None, "rate_php_per_kwh": tariff.rate_at(fc, 13),
             "next_level_rate_php_per_kwh": tariff.rate_at(hi + 1, 13) if hi else None}
        return meter._insights({"quality": None, "usage": None, "tier": t, "reading": None}, {"setup": "meter_only", "rate_php_per_kwh": 13})

    drop = insights(215)[0]
    assert drop["id"] == "tier_drop" and "15 kWh lampas sa 200 kWh" in drop["body"] and "1.5 kWh kada araw" in drop["body"]
    assert insights(195)[0]["id"] == "tier_near"     # 5 kWh below the 201-300 level
    assert insights(120)[0]["id"] == "tier"
    assert insights(215, days_left=2)[0]["id"] == "tier"   # too late in the month to change level


def test_voltage_and_power_factor_warnings():
    q = {"low_limit_v": 207.0, "high_limit_v": 253.0, "voltage_status": "low", "out_of_range_pct_24h": 12.0, "pf_status": "poor"}
    m = {"voltage_v": 198.0, "pf": 0.71, "grid_on": True, "meter_type": "sdm120", "import_kwh": 10.0}
    out = meter._insights({"quality": q, "usage": None, "tier": None, "reading": m}, {"setup": "meter_only", "rate_php_per_kwh": 13})
    assert [i["id"] for i in out[:2]] == ["voltage", "power_factor"]
    assert out[0]["tone"] == "warning" and out[0]["title"] == "Mababa ang boltahe" and "198 V" in out[0]["body"]


def test_meter_endpoint_without_any_meter(client, setup_mode, device):
    setup_mode("meter_only", device)
    r = client.get("/api/meter").json()
    validate("meter_info", r)
    assert r["reading"] is None and r["usage"] is None and r["tier"] is None and r["insights"] == []
    live = client.get("/api/live").json()
    assert live["state"] == "offline" and live["meter"] is None


# --------------------------------------------------------- solar + meter --
def test_solar_and_meter_bills_from_meter_keeps_inverter_flows(client, setup_mode):
    setup_mode("solar_and_meter")
    live = client.get("/api/live").json()
    validate("live", live)
    assert live["telemetry"] is not None and live["meter"]["meter_type"] == "ansi-c12"
    b = client.get("/api/bill").json()
    assert b["grid_source"] == "meter" and b["savings_month_php"] > 0
    d = energy.today()
    mtd = sum(energy.day_totals("solaris-001", d.replace(day=i), "meter")["grid_import_kwh"] for i in range(1, d.day + 1))
    assert b["month_to_date_kwh"] == pytest.approx(mtd, abs=0.01)
    e = client.get("/api/energy?period=week").json()
    assert e["totals"]["pv_kwh"] > 0 and e["totals"]["batt_discharge_kwh"] > 0
    assert client.get("/api/meter").json()["tier"]["month_to_date_kwh"] == b["month_to_date_kwh"]


def test_solar_and_meter_without_meter_readings_falls_back_to_inverter(setup_mode, device):
    s = setup_mode("solar_and_meter", device)
    assert energy.grid_source(device, s) == "inverter"


# ------------------------------------------------------------- solar only --
def test_solar_only_ignores_the_meter(client, setup_mode):
    setup_mode("solar")
    live = client.get("/api/live").json()
    assert live["setup"] == "solar" and live["meter"] is None and live["telemetry"] is not None
    b = client.get("/api/bill").json()
    assert b["grid_source"] == "inverter"
    d = energy.today()
    mtd = sum(energy.day_totals("solaris-001", d.replace(day=i), "inverter")["grid_import_kwh"] for i in range(1, d.day + 1))
    assert b["month_to_date_kwh"] == pytest.approx(mtd, abs=0.01)


# ---------------------------------------------------------------- ingest --
@pytest.mark.parametrize("bad", [
    meter_payload(meter_type="abb"),
    meter_payload(power_w="lots"),
    meter_payload(pf=1.7),
    json.dumps({"meter_type": "sdm120", "voltage_v": 230}).encode(),   # missing power and registers
])
def test_bad_meter_payloads_are_rejected(device, bad):
    ingest.handle_message(f"solaris/{device}/meter", bad)
    assert db.latest_meter(device) is None


def test_meter_grid_on_defaults_to_voltage(device):
    p = json.loads(meter_payload())
    del p["grid_on"]
    ingest.handle_message(f"solaris/{device}/meter", json.dumps(p | {"voltage_v": 0}).encode())
    assert db.latest_meter(device)["grid_on"] is False


def test_meter_only_ingest_tracks_outages_and_goes_online(setup_mode, device):
    setup_mode("meter_only", device)
    now = int(time.time())
    ingest.handle_message(f"solaris/{device}/meter", meter_payload(ts=now - 2))
    assert energy.live(device, db.get_settings())["device"]["online"] is True
    ingest.handle_message(f"solaris/{device}/meter", meter_payload(ts=now - 1, grid_on=False, voltage_v=0, power_w=0))
    assert db.open_outage(device)["start_ts"] == now - 1
    assert energy.live(device, db.get_settings())["state"] == "brownout"
    ingest.handle_message(f"solaris/{device}/meter", meter_payload(ts=now))
    assert db.open_outage(device) is None and db.last_outage(device)["end_ts"] == now
    types = [a["type"] for a in db.query("SELECT type FROM alerts WHERE device_id=? ORDER BY id", (device,))]
    assert types == ["brownout", "grid_restored"]
    msgs = [a["message"] for a in db.query("SELECT message FROM alerts WHERE device_id=?", (device,))]
    assert not any(SOLAR_WORDS.search(m) for m in msgs)


def test_solar_home_meter_does_not_raise_alerts(setup_mode, device):
    setup_mode("solar", device)
    ingest.handle_message(f"solaris/{device}/meter", meter_payload(grid_on=False, voltage_v=0))
    assert db.query("SELECT 1 FROM alerts WHERE device_id=?", (device,)) == []
    assert db.latest_meter(device) is not None   # still stored


def test_evaluate_meter_first_reading_catches_outage_during_restart(device):
    db.execute("INSERT INTO outages (device_id, start_ts) VALUES (?, ?)", (device, int(time.time()) - 600))
    out = alerts.evaluate_meter(device, {"ts": int(time.time()), "grid_on": True})
    assert [a["type"] for a in out] == ["grid_restored"]


# ------------------------------------------------------------------ Mira --
def test_meter_only_facts_never_mention_solar(setup_mode):
    s = setup_mode("meter_only")
    fs = facts.gather(METER_ONLY_DEVICE, s)
    ids = {f.id for f in fs.facts}
    assert facts.METER_ONLY in ids
    assert not any(i.startswith(("outlook.", "upgrade.", "now.battery", "now.solar", "fault.")) for i in ids)
    assert not {"today.saved_php", "bill.savings_month_php", "week.solar_kwh", "today.solar_kwh"} & ids
    assert {"today.load_kwh", "now.voltage_v", "meter.tier", "meter.reading"} <= ids
    for f in fs.facts:
        if f.topic == "solar_plan":
            continue   # getting solar (app/solar_plan.py): only in the prompt when asked, see test_solar_plan.py
        assert not SOLAR_WORDS.search(f.text) and not SOLAR_WORDS.search(f.spoken), f.id


def test_solar_home_facts_keep_solar_and_skip_meter_marker(setup_mode):
    s = setup_mode("solar")
    ids = {f.id for f in facts.gather("solaris-001", s).facts}
    assert facts.METER_ONLY not in ids and "now.solar_w" in ids and "outlook.advice" in ids
    assert not any(i.startswith("meter.") for i in ids)   # solar-only: no meter facts


def test_solar_and_meter_facts_have_both(setup_mode):
    s = setup_mode("solar_and_meter")
    ids = {f.id for f in facts.gather("solaris-001", s).facts}
    assert {"now.solar_w", "now.battery_pct", "meter.tier", "now.voltage_v"} <= ids and facts.METER_ONLY not in ids


@pytest.mark.parametrize("q", ["Magkano ang bill ko ngayong buwan?", "Kumusta ang battery ko?", "Kumusta kahapon?",
                               "Paano makatipid?", "Ano ang boltahe ngayon?", "Ano ang basa ng meter ko?", "Kumusta?",
                               "Magkano ang bill ko sa susunod na buwan?", "Ilang watts ang solar ngayon?"])
def test_meter_only_answers_never_mention_solar(setup_mode, q):
    s = setup_mode("meter_only")
    r = asyncio.run(service.chat(METER_ONLY_DEVICE, s, q))   # LLM_ENABLED=0: rule-based answers
    assert r["reply"] and not SOLAR_WORDS.search(r["reply"]), r["reply"]
    assert "setup.meter_only" not in [x["id"] for x in r["sources"]]


def test_meter_only_voltage_question_answers_voltage_first(setup_mode):
    s = setup_mode("meter_only")
    r = asyncio.run(service.chat(METER_ONLY_DEVICE, s, "Ano ang boltahe ngayon?"))
    assert r["facts_used"][0] == "meter.voltage" and re.search(r"\d+ V", r["reply"])


def test_guard_rejects_solar_talk_for_meter_only_home(setup_mode):
    s = setup_mode("meter_only")
    fs = facts.gather(METER_ONLY_DEVICE, s)
    given = [f for f in fs.facts if f.id in {"setup.meter_only", "bill.month_to_date_php"}]
    amount = fs.by_id()["bill.month_to_date_php"].chip[1]
    bad = guard.check(f"{amount} na ang nagastos mo. Mag-solar ka para makatipid.", ["bill.month_to_date_php"], True, given,
                      "Magkano na ang bill ko?")
    assert not bad.ok and any("no solar" in p for p in bad.problems)
    ok = guard.check(f"Wala kang solar, kaya {amount} na ang nagastos mo.", ["bill.month_to_date_php"], True, given,
                     "May solar ba ako?")
    assert ok.ok, ok.problems


def test_meter_only_daily_summary(setup_mode):
    s = setup_mode("meter_only")
    out = asyncio.run(service.daily_summary(METER_ONLY_DEVICE, s, force=True))
    validate("summary", out)
    assert out["totals"]["pv_kwh"] == 0 and out["totals"]["load_kwh"] > 0
    assert not SOLAR_WORDS.search(out["summary"])
    yesterday = energy.day_totals(METER_ONLY_DEVICE, energy.today() - timedelta(days=1), "meter")
    assert f"{yesterday['load_kwh']:.1f} kWh" in out["summary"]


# ------------------------------------------------------------- mock mode --
@pytest.fixture
def mock_mode(monkeypatch):
    from app import config
    monkeypatch.setattr(config, "MOCK", True)
    mock.reset()
    yield
    mock.reset()


def test_mock_mode_demos_each_setup(client, mock_mode):
    assert client.get("/api/live").json()["setup"] == "solar"
    for setup in ("meter_only", "solar_and_meter", "solar"):
        assert client.put("/api/settings", json={"setup": setup}).json()["setup"] == setup
        assert client.get("/api/settings").json()["setup"] == setup
        live = client.get("/api/live").json()
        validate("live", live)
        assert live["setup"] == setup
        assert (live["telemetry"] is None) == (setup == "meter_only")
        assert (live["meter"] is None) == (setup == "solar")
        b = client.get("/api/bill").json()
        assert b["grid_source"] == ("inverter" if setup == "solar" else "meter")
        for path in ("/api/energy?period=day", "/api/energy?period=week", "/api/bill/projection", "/api/brownout",
                     "/api/summary/daily", "/api/meter"):
            assert client.get(path).status_code == 200
    mock.set_setup("meter_only")
    assert client.get("/api/energy?period=month").json()["totals"]["pv_kwh"] == 0


def test_mock_mode_keeps_what_onboarding_saved(client, mock_mode):
    """The app remembers it was set up; the demo server must remember the answers, even after a restart."""
    import importlib

    from app import config
    out = client.put("/api/settings", json={"setup": "meter_only", "user_name": "Ana"}).json()
    assert (out["setup"], out["user_name"]) == ("meter_only", "Ana")
    client.put("/api/settings", json={"battery_kwh": 14.5})
    got = client.get("/api/settings").json()
    assert (got["setup"], got["user_name"], got["battery_kwh"]) == ("meter_only", "Ana", 14.5)
    assert client.get("/api/live").json()["setup"] == "meter_only"

    importlib.reload(mock)   # a restart: read back from the file
    assert config.MOCK_SETTINGS_PATH.exists()
    got = client.get("/api/settings").json()
    assert (got["setup"], got["user_name"]) == ("meter_only", "Ana")
    assert client.get("/api/live").json()["telemetry"] is None
