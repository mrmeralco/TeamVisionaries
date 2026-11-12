"""End-to-end AI pipeline with a scripted fake model: proves bad replies never reach the user."""
import asyncio

from ai import llm, service
from app import db


def run(replies, question="Bakit mataas ang bill ko?", monkeypatch=None):
    """replies: list of dicts (model output) or Exception, consumed one per LLM call."""
    calls = []

    async def fake(system, messages, schema, max_tokens=220):
        calls.append(messages)
        r = replies.pop(0)
        if isinstance(r, Exception):
            raise r
        return r

    monkeypatch.setattr(llm, "complete_json", fake)
    s = db.get_settings()
    return asyncio.run(service.chat(s["device_id"], s, question)), calls


def facts_text(calls):
    return calls[0][0]["content"]


def test_grounded_answer_is_returned(monkeypatch):
    s = db.get_settings()
    fs = service.gather(s["device_id"], s)
    mtd = fs.by_id()["bill.month_to_date_php"].chip[1]           # e.g. "₱746"
    out, calls = run([{"answerable": True, "reply": f"{mtd} na ang bill mo ngayong buwan.", "fact_ids": ["bill.month_to_date_php"]}],
                     monkeypatch=monkeypatch)
    assert out["source"] == "llm" and mtd in out["reply"]
    assert out["chips"][0]["label"] == "Bill this month"           # chips come from cited facts
    assert "[bill.forecast_php]" in facts_text(calls)              # router gave the bill facts
    assert "[brownout.runtime_h]" not in facts_text(calls)         # ...and not unrelated ones


def test_hallucination_is_retried_then_fixed(monkeypatch):
    bad = {"answerable": True, "reply": "Aabot ng ₱9,999 ang bill mo.", "fact_ids": ["bill.forecast_php"]}
    good = {"answerable": True, "reply": "Tingnan ang forecast sa Bill tab.", "fact_ids": ["bill.forecast_php"]}
    out, calls = run([bad, good], monkeypatch=monkeypatch)
    assert len(calls) == 2 and "9,999" in calls[1][-1]["content"]   # retry tells the model what was wrong
    assert out["source"] == "llm" and "9,999" not in out["reply"]


def test_repeated_hallucination_falls_back(monkeypatch):
    bad = {"answerable": True, "reply": "Aabot ng ₱9,999 ang bill mo.", "fact_ids": ["bill.forecast_php"]}
    out, _ = run([bad, dict(bad)], monkeypatch=monkeypatch)
    assert out["source"] == "fallback" and "9,999" not in out["reply"]
    assert "Bill ngayong buwan" in out["reply"]                    # rule-based answer from the same facts


def test_out_of_scope(monkeypatch):
    out, _ = run([{"answerable": False, "reply": "Si ...", "fact_ids": []}], "Sino ang presidente?", monkeypatch)
    assert out["reply"].startswith("Pasensya na") and out["facts_used"] == []


def test_llm_down_falls_back(monkeypatch):
    out, _ = run([llm.LLMUnavailable("connection refused")], monkeypatch=monkeypatch)
    assert out["source"] == "fallback" and out["reply"]


def test_brownout_facts_always_included(monkeypatch):
    s = db.get_settings()
    dev = s["device_id"]
    db.execute("INSERT INTO outages (device_id, start_ts) VALUES (?, strftime('%s','now') - 600)", (dev,))
    try:
        _, calls = run([{"answerable": True, "reply": "May brownout. Offline ang device.", "fact_ids": ["brownout.active", "now.online"]}], "Kumusta solar ko?", monkeypatch)
        assert "MAY BROWNOUT NGAYON" in facts_text(calls)
    finally:
        db.execute("DELETE FROM outages WHERE end_ts IS NULL")


def test_cached_fallback_summary_is_served_without_calling_the_llm(monkeypatch):
    """LLM down: the app's GET must not wait on it again; only the background task retries."""
    from app import config
    monkeypatch.setattr(config, "LLM_ENABLED", True)
    calls = []

    async def down(*a, **k):
        calls.append(1)
        raise llm.LLMUnavailable("ollama down")

    async def ok(*a, **k):
        calls.append(1)
        return {"answerable": True, "reply": "Maaraw kahapon.", "fact_ids": []}

    monkeypatch.setattr(llm, "complete_json", down)
    s = db.get_settings()
    first = asyncio.run(service.daily_summary(s["device_id"], s, force=True))
    assert first["source"] == "fallback"
    n = len(calls)

    again = asyncio.run(service.daily_summary(s["device_id"], s))          # what GET /api/summary/daily does
    assert again == first and len(calls) == n                              # cached, no LLM call

    monkeypatch.setattr(llm, "complete_json", ok)
    upgraded = asyncio.run(service.daily_summary(s["device_id"], s, upgrade=True))  # background task
    assert len(calls) > n and upgraded["source"] in ("llm", "fallback")


def test_bracketed_fact_ids_are_accepted(monkeypatch):
    # Qwen copies the "[id]" format from the FACTS list; a correct answer must not be thrown away for that.
    s = db.get_settings()
    pct = service.gather(s["device_id"], s).by_id()["now.battery_pct"].values[0]
    out, calls = run([{"answerable": True, "reply": f"Offline ang device. {pct:g}% ang battery mo.", "fact_ids": ["[now.battery_pct]"]}],
                     "Ipaliwanag ang battery percentage ko", monkeypatch)
    assert len(calls) == 1 and out["source"] == "llm" and out["facts_used"] == ["now.battery_pct"]


def test_made_up_id_in_brackets_is_still_rejected(monkeypatch):
    bad = {"answerable": True, "reply": "Ok ang lahat.", "fact_ids": ["[bill.secret_php]"]}
    out, calls = run([bad, dict(bad)], "Ipaliwanag ang battery percentage ko", monkeypatch)
    assert len(calls) == 2 and out["source"] == "fallback"


def test_numbers_written_in_a_fact_sentence_are_allowed():
    # e.g. "Offline ang Sinag device. Huling data 32 minuto na ang nakaraan." had no values, so quoting 32 failed.
    fs = service.FactSet()
    fs.add("now.status", "now", "Kalagayan ngayon: Huling data 32 minuto na ang nakaraan.")
    fs.add("bill.forecast_php", "bill", "Forecast: mga ₱2,070", (2069.64,))
    by = fs.by_id()
    assert 32 in by["now.status"].values
    assert by["bill.forecast_php"].values == (2069.64, 2070.0)


def test_solar_question_falls_back_to_live_numbers_not_the_bill(monkeypatch):
    out, _ = run([llm.LLMUnavailable("down")], "Kumusta ang solar ko?", monkeypatch)
    assert out["source"] == "fallback" and "Bill ngayong buwan" not in out["reply"]
