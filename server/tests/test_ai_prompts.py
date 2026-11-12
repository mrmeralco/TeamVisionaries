"""Tone changes must not weaken grounding: examples pass the guard, spoken sentences add no numbers,
and the daily recap can never become the out-of-scope apology."""
import asyncio

import pytest

from ai import guard, llm, prompts, service
from ai.facts import FactSet, numbers_in_text
from app import config, db


@pytest.mark.parametrize("facts,question,reply,ids", prompts.EXAMPLES, ids=[e[1] for e in prompts.EXAMPLES])
def test_prompt_examples_pass_the_guard(facts, question, reply, ids):
    fs = FactSet()
    for fid, text in facts:
        fs.add(fid, fid.split(".")[0], text)
    result = guard.check(reply, ids, True, fs.facts, question)
    assert result.ok, result.problems


def test_examples_are_in_the_system_prompt():
    for _, question, reply, _ in prompts.EXAMPLES:
        assert question in prompts.SYSTEM and reply in prompts.SYSTEM
    assert "huwag gamitin ang mga numero rito" in prompts.SYSTEM


def test_spoken_sentences_only_use_the_facts_numbers():
    s = db.get_settings()
    for f in service.gather(s["device_id"], s).facts:
        if f.say:
            for n in numbers_in_text(f.say):
                assert any(abs(n - v) < 0.51 for v in f.values), (f.id, f.say, f.values)


def test_direct_answer_is_a_natural_sentence(monkeypatch):
    async def unexpected(*args, **kwargs):
        pytest.fail("direct reading must not call the model")
    monkeypatch.setattr(llm, "complete_json", unexpected)
    s = db.get_settings()
    out = asyncio.run(service.chat(s["device_id"], s, "Ilang porsyento na ang battery ko?"))
    assert out["reply"].startswith("Nasa ") and "ang battery mo ngayon" in out["reply"]  # reading first, stale note after
    assert "Battery:" not in out["reply"]


def test_summary_task_is_not_user_text_and_refusal_falls_back(monkeypatch):
    monkeypatch.setattr(config, "LLM_ENABLED", True)
    calls = []

    async def refuse(system, messages, schema, max_tokens=220):
        calls.append(messages)
        return {"answerable": False, "reply": "Pasensya na", "fact_ids": []}

    monkeypatch.setattr(llm, "complete_json", refuse)
    s = db.get_settings()
    out = asyncio.run(service.daily_summary(s["device_id"], s, force=True))
    first = calls[0][0]["content"]
    assert "<tanong>" not in first and "GAWAIN" in first
    assert len(calls) == 2 and "answerable" in calls[1][-1]["content"]     # retried with a nudge
    assert out["source"] == "fallback" and out["summary"] != prompts.OUT_OF_SCOPE
    assert out["summary"].startswith("Kahapon,") and out["summary"].count("Kahapon") == 1


def test_cached_refusal_recap_is_regenerated(monkeypatch):
    monkeypatch.setattr(config, "LLM_ENABLED", False)
    s = db.get_settings()
    first = asyncio.run(service.daily_summary(s["device_id"], s, force=True))
    key = f"summary:{s['device_id']}:{first['date']}"
    db.put_kv(key, {**first, "summary": prompts.OUT_OF_SCOPE, "source": "llm"})
    again = asyncio.run(service.daily_summary(s["device_id"], s))
    assert again["summary"] != prompts.OUT_OF_SCOPE and again["source"] == "fallback"


def test_repeated_time_openers_are_dropped():
    from ai.answers import join_spoken
    assert join_spoken(["Kahapon, 17.6 kWh ang nagawa ng solar mo.", "Kahapon, ₱46 ang nagastos mo.", "Ngayong araw, ₱5."]) == \
        "Kahapon, 17.6 kWh ang nagawa ng solar mo. ₱46 ang nagastos mo. Ngayong araw, ₱5."


@pytest.mark.parametrize("raw,fixed", [
    ("Juan, ₱1,280 lang ang natipid mo.", "₱1,280 ang natipid mo."),
    ("Kahapon, 17.6 kWh lang ang solar mo.", "Kahapon, 17.6 kWh ang solar mo."),
    ("Offline lang si Solaris device ngayon.", "Offline lang ang Solaris device ngayon."),
    ("Kumusta si Solar ngayon.", "Kumusta ang solar ngayon."),
    ("Hindi may active na brownout ngayon.", "Walang active na brownout ngayon."),
    ("Ilaw lang muna, Juan.", "Ilaw lang muna, Juan."),             # "lang" not after an amount, name not leading
])
def test_style_polish_only_swaps_words(raw, fixed):
    from ai import style
    assert style.polish(raw, "Juan") == fixed
    assert guard.numbers_in(style.polish(raw, "Juan")) == guard.numbers_in(raw)


def test_yes_to_higher_when_forecast_is_lower_is_rejected():
    fs = FactSet()
    fs.add("bill.vs_last_month_pct", "bill", "Ang forecast ay 12% mas mababa kaysa noong nakaraang buwan", (12,))
    q = "Mas mataas ba ang bill ko kaysa last month?"
    assert not guard.check("Oo, 12% mas mababa ang forecast.", ["bill.vs_last_month_pct"], True, fs.facts, q).ok
    assert guard.check("Hindi, 12% mas mababa ang forecast.", ["bill.vs_last_month_pct"], True, fs.facts, q).ok


@pytest.mark.parametrize("reply,ok", [
    ("Hindi mas mataas. 4% mas mababa ang forecast kaysa noong nakaraang buwan.", True),
    ("Hindi, 4% mas mababa ang forecast.", True),
    ("Mas mataas ang forecast, 4% mas mababa.", False),
    ("Oo, hindi mas mataas.", False),                                     # "Oo" to "mas mataas ba?" is still wrong
])
def test_negated_comparison_is_not_a_contradiction(reply, ok):
    fs = FactSet()
    fs.add("bill.vs_last_month_pct", "bill", "Ang forecast ay 4% mas mababa kaysa noong nakaraang buwan", (4,))
    q = "Mas mataas ba ang bill ko kaysa last month?"
    assert guard.check(reply, ["bill.vs_last_month_pct"], True, fs.facts, q).ok == ok


@pytest.mark.parametrize("reply,ok", [
    ("Medyo tumaas nga. Mga ₱1,664 ang inaasahang bill mo, 7% mas mababa.", False),   # copied opener, wrong direction
    ("Mga ₱1,664 ang inaasahang bill mo, 7% mas mababa kaysa noong nakaraang buwan.", True),
    ("Hindi tumaas: 7% mas mababa ang forecast.", True),
])
def test_rise_words_must_match_the_comparison(reply, ok):
    fs = FactSet()
    fs.add("bill.forecast_php", "bill", "Forecast ng bill sa katapusan ng buwan: mga ₱1,664", (1664.0,), ("Forecast", "₱1,664"))
    fs.add("bill.vs_last_month_pct", "bill", "Ang forecast ay 7% mas mababa kaysa noong nakaraang buwan", (7,))
    ids = ["bill.forecast_php", "bill.vs_last_month_pct"]
    assert guard.check(reply, ids, True, fs.facts, "Bakit mataas ang bill ko?").ok == ok
