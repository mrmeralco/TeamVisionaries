"""Solar plan (/api/solar-plan): sizing solar for a home that has none, from its own use."""
import json

import pytest

from app import config, db, solar_plan as P, tariff
from solaris_contract import validate

RATE = 15.0


def settings(**over):
    return {"rate_php_per_kwh": RATE, "battery_kwh": 10.0, "user_name": "Juan", "device_id": "meter-001",
            "setup": "meter_only"} | over


def evening_home(scale: float = 1.0) -> list[float]:
    """kWh per hour: 0.3 always on, 1.5 from 6 to 11 PM (aircon), 0.6 in the morning: 65 % at night."""
    return [scale * (0.3 + (1.5 if 18 <= h < 23 else 0.6 if 7 <= h < 9 else 0)) for h in range(24)]


def daytime_home() -> list[float]:
    """Someone home all day running the aircon from 10 AM to 4 PM; quiet nights."""
    return [0.25 + (1.2 if 10 <= h < 16 else 0.3 if 6 <= h < 22 else 0) for h in range(24)]


# -------------------------------------------------------------- simulate --
@pytest.mark.parametrize("kwp, batt", [(0.0, 0.0), (3.0, 0.0), (5.0, 10.0), (20.0, 20.0)])
def test_simulation_balances(kwp, batt):
    load = evening_home()
    s = P.simulate(load, kwp, batt, 5.0, 3.6)
    assert s["covered_kwh_day"] + s["grid_kwh_day"] == pytest.approx(sum(load), abs=1e-6)
    assert s["covered_kwh_day"] + s["export_kwh_day"] <= s["solar_kwh_day"] + 1e-6   # losses, never gains
    assert s["solar_kwh_day"] == pytest.approx(kwp * 3.6)


def test_a_battery_moves_sun_into_the_night():
    load = evening_home()
    without = P.simulate(load, 5.0, 0.0, 5.0, 3.6)
    with_batt = P.simulate(load, 5.0, 10.0, 5.0, 3.6)
    assert with_batt["grid_kwh_day"] < without["grid_kwh_day"] - 5
    assert with_batt["export_kwh_day"] < without["export_kwh_day"]


def test_sun_shape_is_daytime_only_and_adds_up():
    s = P.sun_shape(3.6)
    assert sum(s) == pytest.approx(3.6) and all(s[h] == 0 for h in (*range(6), *range(18, 24)))
    assert max(range(24), key=lambda h: s[h]) in (11, 12)


# ---------------------------------------------------------------- sizing --
def test_hybrid_option_is_sized_from_the_home():
    load = evening_home()
    o = P.option("hybrid", load, 2200, RATE)
    assert o["battery_kwh"] % P.BATTERY_STEP == 0 and P.BATTERY_MIN <= o["battery_kwh"] <= P.BATTERY_MAX
    night = sum(load) - sum(load[6:18])
    assert o["battery_kwh"] * P.DOD >= night                                  # the night fits in the battery
    assert o["panels"] * config.SOLAR_PANEL_W / 1000 == pytest.approx(o["pv_kwp"], abs=0.01)
    assert o["pv_kwp"] * config.SOLAR_YIELD_KWH_PER_KWP_DAY >= P.HYBRID_COVER * sum(load)
    assert o["inverter_kw"] in P.INVERTER_SIZES and o["inverter_kw"] * 1000 >= 2200 * P.PEAK_MARGIN
    assert o["savings_php_month"] == o["bill_before_php_month"] - o["bill_after_php_month"]
    assert o["bill_before_php_month"] == round(tariff.cost(sum(load) * 30, RATE))
    assert o["payback_years"] == pytest.approx(o["cost_php"] / (o["savings_php_month"] * 12), abs=0.1)
    assert o["backup_hours"] and o["covers_pct"] >= 80


def test_grid_tie_option_has_no_battery_and_is_cheaper():
    load = evening_home()
    g, h = P.option("grid_tie", load, 2200, RATE), P.option("hybrid", load, 2200, RATE)
    assert g["battery_kwh"] is None and g["backup_hours"] is None
    assert g["cost_php"] < h["cost_php"] and g["pv_kwp"] < h["pv_kwp"]
    assert g["pv_kwp"] * config.SOLAR_YIELD_KWH_PER_KWP_DAY >= sum(load[6:18])


def test_bigger_use_gets_a_bigger_system():
    small, big = P.option("hybrid", evening_home(0.5), 1500, RATE), P.option("hybrid", evening_home(2.0), 4000, RATE)
    assert big["pv_kwp"] > small["pv_kwp"] and big["battery_kwh"] >= small["battery_kwh"]
    assert big["inverter_kw"] >= small["inverter_kw"]


def test_tiny_use_still_gets_a_real_system():
    o = P.option("grid_tie", [0.02] * 24, 100, RATE)
    assert o["panels"] >= P.MIN_PANELS and o["inverter_kw"] == P.INVERTER_SIZES[0]


# ------------------------------------------------------------------ plan --
def test_night_heavy_meter_only_home_gets_the_hybrid(monkeypatch):
    monkeypatch.setattr(P, "usage", lambda dev, s: {"days": 30, "by_hour": evening_home(), "peak_w": 2200})
    r = P.plan("x", settings())
    validate("solar_plan", r)
    assert [o["id"] for o in r["options"]] == ["hybrid", "grid_tie"] and r["options"][0]["recommended"]
    assert not r["options"][1]["recommended"]
    assert r["usage"]["night_share_pct"] >= 40 and "battery" in r["options"][0]["why"]
    best = r["options"][0]
    assert f"{best['pv_kwp']:g} kWp" in r["headline"] and f"{best['battery_kwh']:g} kWh" in r["headline"]


def test_daytime_home_gets_grid_tie(monkeypatch):
    monkeypatch.setattr(P, "usage", lambda dev, s: {"days": 30, "by_hour": daytime_home(), "peak_w": 2000})
    r = P.plan("x", settings())
    validate("solar_plan", r)
    assert r["options"][0]["id"] == "grid_tie" and r["options"][0]["recommended"]
    assert "battery" not in r["headline"]


def test_home_with_solar_gets_no_options():
    r = P.plan("solaris-001", settings(setup="solar", device_id="solaris-001"))
    validate("solar_plan", r)
    assert r["has_solar"] and r["options"] == [] and r["usage"] is None and "System check" in r["headline"]


def test_not_enough_data_says_how_many_days(device):
    r = P.plan(device, settings(device_id=device))
    validate("solar_plan", r)
    assert r["options"] == [] and r["usage"] is None and r["days"] == 0 and "7 araw" in r["headline"]


def test_seeded_meter_only_home_from_the_meter():
    """conftest seeds meter-001 with 40 days of meter readings and no inverter."""
    r = P.plan("meter-001", settings())
    validate("solar_plan", r)
    assert r["days"] == P.PLAN_DAYS and len(r["options"]) == 2
    assert 10 <= r["usage"]["kwh_day"] <= 30 and r["usage"]["peak_w"] > 0
    assert all(o["savings_php_month"] > 0 and o["payback_years"] for o in r["options"])


# -------------------------------------------------------------- sponsors --
def test_placeholder_sponsors_by_default(monkeypatch, tmp_path):
    monkeypatch.setattr(config, "SPONSORS_FILE", tmp_path / "none.json")
    s = P.sponsors()
    assert len(s) == 3 and all(x["placeholder"] for x in s)


def test_sponsors_file_is_used_and_cleaned(monkeypatch, tmp_path):
    f = tmp_path / "sponsors.json"
    f.write_text(json.dumps([
        {"id": "acme", "kind": "installer", "name": "Acme Solar", "tagline": "Libreng site visit", "url": "https://example.com"},
        {"kind": "casino", "name": "Not allowed"},          # unknown kind: dropped
        {"kind": "financing", "name": "Loan Co"},           # no id: one is made up
    ]))
    monkeypatch.setattr(config, "SPONSORS_FILE", f)
    s = P.sponsors()
    assert [x["name"] for x in s] == ["Acme Solar", "Loan Co"] and not any(x["placeholder"] for x in s)
    assert s[1]["id"] == "sponsor_3" and s[1]["url"] is None


def test_broken_sponsors_file_falls_back_to_placeholders(monkeypatch, tmp_path):
    f = tmp_path / "sponsors.json"
    f.write_text("{not json")
    monkeypatch.setattr(config, "SPONSORS_FILE", f)
    assert all(x["placeholder"] for x in P.sponsors())


def test_sponsors_never_change_the_plan(monkeypatch, tmp_path):
    monkeypatch.setattr(P, "usage", lambda dev, s: {"days": 30, "by_hour": evening_home(), "peak_w": 2200})
    monkeypatch.setattr(config, "SPONSORS_FILE", tmp_path / "none.json")
    a = P.plan("x", settings())
    f = tmp_path / "sponsors.json"
    f.write_text(json.dumps([{"kind": "installer", "name": "Acme Solar"}]))
    monkeypatch.setattr(config, "SPONSORS_FILE", f)
    b = P.plan("x", settings())
    assert a["options"] == b["options"] and a["headline"] == b["headline"]


def test_endpoint(client):
    r = client.get("/api/solar-plan")
    assert r.status_code == 200
    validate("solar_plan", r.json())
    assert r.json()["setup"] == db.get_settings()["setup"]


# ------------------------------------------------------------------ Mira --
@pytest.fixture
def meter_only_home():
    """Switches settings to the seeded meter-only home (conftest), restored afterwards."""
    before = db.get_settings()
    yield db.put_settings({"setup": "meter_only", "device_id": "meter-001"})
    db.put_settings(before)


def _chat(s, q):
    import asyncio

    from ai import service
    return asyncio.run(service.chat(s["device_id"], s, q))   # LLM_ENABLED=0: rule-based answers


def test_meter_only_home_has_plan_facts_with_savings_then_cost(meter_only_home):
    from ai import facts
    by = facts.gather("meter-001", meter_only_home).by_id()
    rec, alt = by["solar_plan.recommended"], by["solar_plan.alternative"]
    plan = P.plan("meter-001", meter_only_home)
    best = plan["options"][0]
    assert rec.topic == alt.topic == by["solar_plan.limits"].topic == "solar_plan"
    assert rec.values[:2] == (best["savings_php_month"], best["cost_php"])
    assert f"{best['pv_kwp']:g} kWp" in rec.text and rec.chip == ("Suggested solar", f"{best['pv_kwp']:g} kWp")
    assert "tantiya" in rec.text and "installer" in by["solar_plan.limits"].text.lower()


@pytest.mark.parametrize("q", ["Magkano kung magpa-solar ako?", "Ilang panels ang kailangan ko?",
                               "Sulit ba ang solar para sa bahay namin?", "How big a solar setup do I need?",
                               "anong setup ng solar ang dapat ko iinstall para mabawasan ang bill ko sa kuryente",
                               "if i were to move into solar, what setup should i install base on my home consumption",
                               "Explain the solar_plan", "Ipaliwanag mo ang solar plan"])
def test_getting_solar_questions_answer_from_the_plan(meter_only_home, q):
    r = _chat(meter_only_home, q)
    assert r["facts_used"][0] == "solar_plan.recommended", r
    assert "kWp" in r["reply"] and "₱" in r["reply"]
    assert [x["label"] for x in r["sources"]][0] == "Suggested solar size"


@pytest.mark.parametrize("q", ["Kumusta?", "Magkano ang bill ko?", "Paano makatipid?", "Ilang watts ang solar ngayon?"])
def test_other_questions_never_get_the_plan(meter_only_home, q):
    r = _chat(meter_only_home, q)
    assert not any(i.startswith("solar_plan.") for i in r["facts_used"]), r["facts_used"]


def test_home_with_solar_asking_about_solar_panels_still_gets_an_answer():
    r = _chat(db.get_settings(), "Ilang panels ang kailangan ko?")
    assert r["reply"] and not any(i.startswith("solar_plan.") for i in r["facts_used"])


def test_plan_needs_data_first(meter_only_home, device):
    s = db.put_settings({"device_id": device})
    r = _chat(s, "Magkano kung magpa-solar ako?")
    assert r["facts_used"][0] == "solar_plan.not_ready" and "7 araw" in r["reply"]


def test_guard_allows_solar_words_only_with_the_plan(meter_only_home):
    from ai import facts, guard
    fs = facts.gather("meter-001", meter_only_home)
    by = fs.by_id()
    rec = by["solar_plan.recommended"]
    savings, cost = rec.values[0], rec.values[1]
    reply = f"Para sa gamit mo, solar na may battery: tantiyang tipid ₱{savings:,.0f} kada buwan."
    with_plan = [by["setup.meter_only"], rec]
    assert guard.check(reply, ["solar_plan.recommended"], True, with_plan, "Kailangan ko ba?").ok
    assert not guard.check(reply, ["solar_plan.recommended"], True, [by["setup.meter_only"]], "Kailangan ko ba?").ok
    # Savings and cost can't swap places.
    swapped = f"Tantiyang tipid ₱{cost:,.0f} kada buwan."
    bad = guard.check(swapped, ["solar_plan.recommended"], True, with_plan, "Magkano kung magpa-solar ako?")
    assert not bad.ok and any("money meaning" in p for p in bad.problems)


def test_plan_questions_get_only_the_plan_and_no_offline_rule(meter_only_home):
    """Live run with qwen3.5:4b: beside live meter facts it talked about stale readings or refused."""
    from ai import facts, guard, router
    fs = facts.gather("meter-001", meter_only_home)
    q = "Magkano kung magpa-solar ako?"
    picked = router.select_facts(q, fs.select(router.topics_for(q, set())))
    assert picked and all(f.topic == "solar_plan" for f in picked)
    rec = fs.by_id()["solar_plan.recommended"]
    offline = facts.Fact("now.online", "now", "OFFLINE ang Solaris device; luma na ang live data.")
    reply = rec.spoken + " Tantiya lang; installer ang magbibigay ng quote."
    assert guard.check(reply, ["solar_plan.recommended"], True, [rec, offline, fs.by_id()["setup.meter_only"]], q).ok
    # The fallback doesn't tack on an offline note either.
    r = _chat(meter_only_home, q)
    assert "now.online" not in r["facts_used"]


def test_plan_answer_must_give_size_and_money(meter_only_home):
    """Live run: "Sulit ba ang solar?" got a vague answer with no numbers; the guard now sends it back."""
    from ai import facts, guard
    rec = facts.gather("meter-001", meter_only_home).by_id()["solar_plan.recommended"]
    q = "Sulit ba ang solar para sa bahay namin?"
    vague = guard.check("Tantiya lang ito at installer ang magbibigay ng quote.", ["solar_plan.recommended"], True, [rec], q)
    assert not vague.ok and any("suggested size" in p for p in vague.problems)
    kwp = rec.chip[1]
    missing_battery = guard.check(f"Oo: {kwp} ang mungkahi, tantiyang tipid ₱{rec.values[0]:,.0f} kada buwan.",
                                 ["solar_plan.recommended"], True, [rec], q)
    assert not missing_battery.ok and any("battery" in p for p in missing_battery.problems)
    good = guard.check(rec.spoken,
                       ["solar_plan.recommended"], True, [rec], q)
    assert good.ok, good.problems
