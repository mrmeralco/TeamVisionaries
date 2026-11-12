"""Mira's answers carry `sources`: exactly the user's data behind the reply, never anything from the model."""
import asyncio

import pytest

from ai import llm, service, sources
from app import db
from solaris_contract import validate

SCREENS = {"home", "energy", "bill", "brownout", "alerts", "settings", None}
KINDS = {"live", "history", "forecast", "settings", "advice"}


def ask(question, replies, monkeypatch):
    async def fake(system, messages, schema, max_tokens=220):
        r = replies.pop(0)
        if isinstance(r, Exception):
            raise r
        return r
    monkeypatch.setattr(llm, "complete_json", fake)
    s = db.get_settings()
    return asyncio.run(service.chat(s["device_id"], s, question))


def facts():
    s = db.get_settings()
    return service.gather(s["device_id"], s)


def test_every_fact_has_a_readable_source():
    for f in facts().facts:
        if f.id in sources.HIDDEN:
            continue
        label, kind, period, screen = sources.meta(f.id)
        assert label != f.id, f"{f.id} has no label in ai/sources.py"
        assert kind in KINDS and screen in SCREENS and period, f.id


def test_model_answer_lists_its_cited_facts_with_their_data(monkeypatch):
    fs = facts().by_id()
    forecast = fs["bill.forecast_php"]
    out = ask("Bakit mataas ang bill ko?", [{"answerable": True, "fact_ids": ["bill.forecast_php", "usage.peak_hours"],
                                             "reply": f"Mga {forecast.chip[1]} ang inaasahang bill mo."}], monkeypatch)
    validate("chat", out)
    assert [s["id"] for s in out["sources"]] == ["bill.forecast_php", "usage.peak_hours"]
    first = out["sources"][0]
    assert first["label"] == "Bill forecast" and first["value"] == forecast.chip[1]
    assert first["detail"] == forecast.spoken and first["kind"] == "forecast" and first["screen"] == "bill"
    assert out["sources"][1]["value"] is None and "tuwing" in out["sources"][1]["detail"]


def test_fallback_answer_has_sources_too(monkeypatch):
    out = ask("Bakit mataas ang bill ko?", [llm.LLMUnavailable("down")], monkeypatch)
    assert out["source"] == "fallback" and out["sources"] and out["facts_used"]
    assert [s["id"] for s in out["sources"]] == [i for i in out["facts_used"] if i != "now.online"]
    for s in out["sources"]:
        assert s["detail"].rstrip(".") in out["reply"]          # every source is something the reply said


def test_direct_answer_sources(monkeypatch):
    out = ask("Magkano ang forecast ng bill ko?", [], monkeypatch)
    assert out["sources"][-1]["id"] == "bill.forecast_php"


def test_refusal_has_no_sources(monkeypatch):
    out = ask("Sino ang presidente?", [{"answerable": False, "reply": "", "fact_ids": []}], monkeypatch)
    assert out["sources"] == [] and out["facts_used"] == []


def test_live_sources_use_the_reading_time_and_settings_have_none():
    fs = facts()
    by = fs.by_id()
    out = sources.build(["now.battery_pct", "bill.rate", "user.name", "bill.secret"], by, 1_700_000_000, 1_800_000_000)
    assert [s["id"] for s in out] == ["now.battery_pct", "bill.rate"]   # name and unknown ids skipped
    assert out[0]["as_of_ts"] == 1_700_000_000 and out[0]["kind"] == "live"
    assert out[1]["as_of_ts"] is None and out[1]["screen"] == "settings"


@pytest.mark.parametrize("online,shown", [(True, False), (False, True)])
def test_device_connection_is_a_source_only_when_offline(online, shown):
    from ai.facts import Fact
    text = "Online ang Solaris device." if online else "OFFLINE ang Solaris device; luma na ang live data."
    out = sources.build(["now.online"], {"now.online": Fact("now.online", "now", text)}, None, 1)
    assert bool(out) == shown


def test_upgrade_question_answers_from_the_system_check(monkeypatch):
    """Mira's answer to an upgrade question comes from /api/upgrade's analysis, and says so in its sources."""
    out = ask("Kailangan ko ba ng dagdag na battery?", [llm.LLMUnavailable("down")], monkeypatch)
    used = [s["id"] for s in out["sources"]]
    assert used[0] == "upgrade.verdict" and any(i in used for i in ("upgrade.battery", "upgrade.solar", "upgrade.inverter"))
    first = out["sources"][0]
    assert first["label"] == "System check" and first["kind"] == "advice" and first["screen"] == "bill"
    assert "Tantiyang tipid" in out["reply"] or "Sakto" in out["reply"]


def test_upgrade_question_gets_only_the_system_check_and_must_cite_it(monkeypatch):
    calls = []

    async def fake(system, messages, schema, max_tokens=220):
        calls.append(messages)
        return {"answerable": True, "reply": "Depende sa gamit mo. Offline ang device ngayon.", "fact_ids": ["now.status"]}
    monkeypatch.setattr(llm, "complete_json", fake)
    s = db.get_settings()
    out = asyncio.run(service.chat(s["device_id"], s, "Kailangan ko ba ng dagdag na battery?"))
    prompt = calls[0][0]["content"]
    assert "[upgrade.verdict]" in prompt and "[now.battery_pct]" not in prompt and "[outlook." not in prompt
    assert len(calls) == 2 and "upgrade" in calls[1][-1]["content"]     # retried: must use the system check
    assert out["source"] == "fallback" and out["sources"][0]["id"] == "upgrade.verdict"
    assert "Offline" not in out["reply"]                                # no stale-reading notice on an upgrade answer


def test_upgrade_money_is_checked_by_role():
    """'tipid ₱1,717 ... gastos ₱100,000' is right; swapping the two is caught."""
    from ai import guard
    from ai.facts import FactSet
    fs = FactSet()
    fs.add("upgrade.battery", "upgrade", "Rekomendasyon: Dagdag na battery (+5 kWh). Tantiyang tipid: ₱1,717 kada buwan. "
           "Tantiyang gastos: ₱100,000.", (1717, 100000, 4.9))
    q = "Kailangan ko ba ng dagdag na battery?"
    ok = "Oo, makakatipid ka ng mga ₱1,717 kada buwan, at ₱100,000 ang tantiyang gastos."
    swapped = "Makakatipid ka ng ₱100,000 kada buwan, at ₱1,717 ang gastos."
    assert guard.check(ok, ["upgrade.battery"], True, fs.facts, q).ok
    assert not guard.check(swapped, ["upgrade.battery"], True, fs.facts, q).ok


def test_refusing_an_upgrade_question_falls_back_to_the_system_check(monkeypatch):
    refuse = {"answerable": False, "reply": "Pasensya na", "fact_ids": []}
    out = ask("Dapat ko bang dagdagan ang panels ko?", [refuse, dict(refuse)], monkeypatch)
    assert out["source"] == "fallback" and out["sources"][0]["id"] == "upgrade.verdict"
    assert not out["reply"].startswith("Pasensya")
