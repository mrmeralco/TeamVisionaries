"""Bill projection (/api/bill/projection) and how Mira answers about later months.

Only this month is a forecast; up to 3 months after it are projections with a widening range; beyond that
nothing is projected and Mira explains why.
"""
import asyncio
from datetime import date

import pytest

from ai import guard, llm, router, service
from ai.facts import FactSet
from app import db, projection
from solaris_contract import validate


@pytest.fixture
def proj():
    projection._cache.clear()
    s = db.get_settings()
    out = projection.project(s["device_id"], s)
    validate("bill_projection", out)
    return out


def test_this_month_is_the_forecast_and_three_months_are_projected(proj):
    months = proj["months"]
    assert proj["enough_data"] and proj["max_months"] == 3
    assert [m["months_ahead"] for m in months] == [0, 1, 2, 3]
    assert months[0]["kind"] == "forecast" and all(m["kind"] == "projection" for m in months[1:])


def test_the_range_widens_every_month(proj):
    ranges = [m["range_pct"] for m in proj["months"][1:]]
    assert ranges == sorted(ranges) and (ranges[0] < ranges[-1] or ranges[0] == projection.RANGE_PCT_MAX)
    widths = [m["high_kwh"] - m["low_kwh"] for m in proj["months"][1:]]
    assert all(w > 0 for w in widths)
    for m in proj["months"][1:]:
        assert m["low_php"] < m["bill_php"] < m["high_php"] and m["low_kwh"] >= 0
        assert m["range_pct"] <= projection.RANGE_PCT_MAX


def test_range_never_shrinks_to_nothing_for_a_home_that_barely_uses_the_grid(monkeypatch):
    """Grid use is what's left after sun and battery: a projection of ~0 kWh still gets a real range."""
    monkeypatch.setattr(projection, "_daily_grid", lambda prof, lx, px, s: {"grid": 0.05, "load": 12.0, "pv": 20.0})
    projection._cache.clear()
    s = db.get_settings()
    out = projection.project(s["device_id"], s)
    projection._cache.clear()
    for m in out["months"][1:]:
        assert m["high_kwh"] - m["grid_kwh"] >= projection.FLOOR_SHARE * m["load_kwh"] - 0.1
        assert m["low_kwh"] == 0 and m["range_pct"] == projection.RANGE_PCT_MAX


def test_this_month_matches_the_bill_forecast(proj):
    from app import energy
    s = db.get_settings()
    assert proj["months"][0]["bill_php"] == energy.bill(s["device_id"], s)["forecast_php"]


def test_season_tables_cover_the_year_and_average_one():
    for table in (projection.LOAD_SEASON, projection.SOLAR_SEASON):
        assert len(table) == 12 and abs(sum(table) / 12 - 1) < 0.02
    # Manila: the dry season (Mar-May) is sunnier than the rainy season (Jul-Sep).
    assert min(projection.SOLAR_SEASON[2:5]) > max(projection.SOLAR_SEASON[6:9])


def test_less_sun_means_more_grid():
    """Same home and use: a cloudier month buys more from the grid."""
    s = db.get_settings()
    from app import outlook
    prof = outlook.profiles(s["device_id"])
    sunny = projection._daily_grid(prof, 1.0, 1.2, s)["grid"]
    cloudy = projection._daily_grid(prof, 1.0, 0.8, s)["grid"]
    assert cloudy > sunny


def test_too_little_history_gives_only_this_month(monkeypatch):
    from app import energy
    monkeypatch.setattr(energy, "daily_history", lambda *a, **k: [])
    projection._cache.clear()
    s = db.get_settings()
    out = projection.project(s["device_id"], s)
    validate("bill_projection", out)
    assert not out["enough_data"] and len(out["months"]) == 1
    projection._cache.clear()


# ------------------------------------------------------------- months asked --
TODAY = date(2026, 11, 12)


@pytest.mark.parametrize("question,ahead", [
    ("Magkano ang bill ko sa Disyembre?", 1),
    ("Magkano bill ko next month?", 1),
    ("Magkano ang bill ko sa Pasko?", 1),
    ("Ano ang bill ko sa tatlong buwan?", 3),
    ("Ilan ang bill ko sa Marso?", 4),
    ("Bill ko sa 6 na buwan?", 6),
    ("Magkano bill ko next year?", 12),
    ("Bill ko sa Disyembre 2027?", 13),
    ("Magkano ang bill ko sa Nobyembre?", 0),
    ("May brownout ba?", None),                    # "may" is not May
    ("May 5 na tao sa bahay", None),
])
def test_months_ahead(question, ahead):
    assert router.months_ahead(question, TODAY) == ahead


def test_later_months_are_not_this_months_bill():
    assert router.bill_intent("Magkano ang forecast ng bill ko next month?") is None
    assert router.bill_intent("Magkano ang forecast ng bill ko?") == "forecast"


# ------------------------------------------------------------------ Mira ----
def ask(question, replies, monkeypatch):
    async def fake(system, messages, schema, max_tokens=220):
        r = replies.pop(0)
        if isinstance(r, Exception):
            raise r
        return r
    monkeypatch.setattr(llm, "complete_json", fake)
    projection._cache.clear()
    s = db.get_settings()
    return asyncio.run(service.chat(s["device_id"], s, question))


def test_next_month_answer_says_it_is_an_estimate(monkeypatch):
    out = ask("Magkano ang bill ko next month?", [llm.LLMUnavailable("down")], monkeypatch)
    assert out["source"] == "fallback" and out["reply"].startswith("Tantiya lang")
    assert [s["id"] for s in out["sources"]] == ["projection.m1", "projection.limits"]
    assert "hindi gaanong maaasahan" in out["reply"]


def test_beyond_three_months_explains_why_not(monkeypatch):
    out = ask("Magkano ang bill ko next year?", [llm.LLMUnavailable("down")], monkeypatch)
    ids = [s["id"] for s in out["sources"]]
    assert ids[0] == "projection.limits" and ids[-1] == "projection.m3"   # why + the furthest it can do
    assert "lampas doon" in out["reply"].lower()


def test_model_must_hedge_and_respect_the_limit(monkeypatch):
    """The model's prompt has only projection facts; an answer without a caveat, or a number for a month past
    the limit without explaining, is retried and then replaced."""
    calls = []

    async def fake(system, messages, schema, max_tokens=220):
        calls.append(messages)
        return {"answerable": True, "reply": "Ang bill mo sa susunod na taon ay ₱2,000.", "fact_ids": ["projection.m3"]}
    monkeypatch.setattr(llm, "complete_json", fake)
    projection._cache.clear()
    s = db.get_settings()
    out = asyncio.run(service.chat(s["device_id"], s, "Magkano bill ko next year?"))
    prompt = calls[0][0]["content"]
    assert "[projection.limits]" in prompt and "[bill.month_to_date_php]" not in prompt
    assert len(calls) == 2 and out["source"] == "fallback"
    assert out["sources"][0]["id"] == "projection.limits"


def test_guard_rules_for_projection_answers():
    fs = FactSet()
    fs.add("projection.limits", "projection", "Limitasyon: hanggang 3 buwan lang.")
    fs.add("projection.m1", "projection", "Projection ng bill sa Disyembre 2026: mga ₱2,734 (₱1,821 hanggang ₱3,731)",
           (2734, 1821, 3731))
    q = "Magkano ang bill ko next month?"
    assert guard.check("Tantiya lang: mga ₱2,734 sa Disyembre.", ["projection.m1"], True, fs.facts, q).ok
    assert not guard.check("Mga ₱2,734 ang bill mo sa Disyembre.", ["projection.m1"], True, fs.facts, q).ok  # no caveat
    far = "Magkano bill ko next year?"
    assert guard.check("Hindi ko pa kaya i-project iyan; hanggang 3 buwan lang.", ["projection.limits"], True, fs.facts, far).ok
    assert not guard.check("Tantiya lang: ₱2,734.", ["projection.m1"], True, fs.facts, far).ok


def test_cant_project_answer_shows_no_unrelated_chips(monkeypatch):
    """'Hindi pa kaya' cites only the limits fact: no 'Bill this month' chips beside it."""
    out = ask("Magkano bill ko next year?", [{"answerable": True, "fact_ids": ["projection.limits"],
              "reply": "Hindi ko pa kaya iyan; hanggang 3 buwan lang ang projection."}], monkeypatch)
    assert out["source"] == "llm" and out["chips"] == []
