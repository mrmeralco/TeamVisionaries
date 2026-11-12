"""Mock data must not bypass the real, grounded AI pipeline."""
import time

import pytest

from ai import llm, service
from app import config, energy, mock


@pytest.mark.parametrize("setup", ["solar", "meter_only", "solar_and_meter"])
def test_mock_ai_uses_working_device_even_when_seeded_history_is_stale(monkeypatch, setup):
    monkeypatch.setattr(config, "MOCK", True)
    monkeypatch.setattr(mock, "_setup", setup)
    settings = mock.load("settings")
    # Seeded rows are older than the hardware timeout; mock facts must use the online demo instead.
    monkeypatch.setattr(config, "OFFLINE_AFTER_S", 0)
    assert not energy.live(settings["device_id"], settings)["device"]["online"]
    live = mock.load("live")
    started = int(time.time())
    facts = service.gather(settings["device_id"], settings)
    by = facts.by_id()
    assert by["now.online"].text == "Online ang Solaris device."
    assert by["now.status"].spoken == live["status_line"]
    assert started <= facts.measured_ts <= int(time.time())
    assert not any("offline" in fact.text.lower() for fact in facts.facts)
    if setup != "meter_only":
        assert by["now.battery_pct"].values[0] == live["telemetry"]["batt_soc"]
        assert by["now.solar_w"].values[0] == live["telemetry"]["pv_w"]


def test_hardware_ai_still_reports_stale_device(monkeypatch):
    monkeypatch.setattr(config, "MOCK", False)
    monkeypatch.setattr(config, "OFFLINE_AFTER_S", 0)
    settings = mock.load("settings")
    by = service.gather(settings["device_id"], settings).by_id()
    assert by["now.online"].text.startswith("OFFLINE")


def test_mock_chat_calls_model_with_seeded_facts(mock_client, monkeypatch):
    monkeypatch.setattr(config, "LLM_ENABLED", True)
    settings = mock.load("settings")
    facts = service.gather(settings["device_id"], settings)
    amount = facts.by_id()["bill.month_to_date_php"].chip[1]
    calls = []

    async def complete(system, messages, schema, max_tokens=220):
        calls.append(messages)
        return {"answerable": True, "reply": f"{amount} na ang bill mo ngayong buwan.",
                "fact_ids": ["bill.month_to_date_php"]}

    monkeypatch.setattr(llm, "complete_json", complete)
    response = mock_client.post("/api/chat", json={"message": "Bakit mataas ang bill ko?"})
    assert response.status_code == 200
    assert response.json()["source"] == "llm"
    assert amount in response.json()["reply"]
    assert calls and "Bakit mataas ang bill ko?" in calls[0][0]["content"]
    assert "OFFLINE ang Solaris device" not in calls[0][0]["content"]


def test_mock_meter_only_solar_plan_matches_the_go_solar_card(monkeypatch):
    """The card shows mock.load("solar_plan"); Mira must quote the same plan, not "need 7 days of readings"."""
    monkeypatch.setattr(config, "MOCK", True)
    monkeypatch.setattr(mock, "_setup", "meter_only")
    settings = mock.load("settings")
    card = mock.load("solar_plan")["options"]
    by = service.gather(settings["device_id"], settings).by_id()
    assert "solar_plan.not_ready" not in by
    best = next(o for o in card if o["recommended"])
    rec = by["solar_plan.recommended"]
    assert rec.chip == ("Suggested solar", f"{best['pv_kwp']:g} kWp")
    assert rec.values[:2] == (best["savings_php_month"], best["cost_php"])
    reply, ids = service.fallback_reply({"solar_plan", "now"}, set(), service.gather(settings["device_id"], settings))
    assert ids[0] == "solar_plan.recommended" and f"{best['pv_kwp']:g} kWp" in reply


def test_mock_solar_install_question_explains_plan_instead_of_referring_to_facts(mock_client, monkeypatch):
    monkeypatch.setattr(config, "LLM_ENABLED", True)
    monkeypatch.setattr(mock, "_setup", "meter_only")
    calls = []

    async def defer_to_facts(system, messages, schema, max_tokens=220):
        calls.append(messages)
        return {"answerable": True, "reply": "Tingnan ang solar_plan facts para sa mungkahi ng laki at tipid.",
                "fact_ids": ["solar_plan.recommended"]}

    monkeypatch.setattr(llm, "complete_json", defer_to_facts)
    response = mock_client.post("/api/chat", json={
        "message": "anong setup ng solar ang dapat ko iinstall para mabawasan ang bill ko sa kuryente"})
    assert response.status_code == 200
    result = response.json()
    assert "solar_plan.recommended" in calls[0][0]["content"]
    assert "bill.forecast_php" not in calls[0][0]["content"]
    assert result["facts_used"][0] == "solar_plan.recommended"
    assert "kWp" in result["reply"] and "₱" in result["reply"]
    assert "4.64 kWp" in result["reply"] and "15 kWh na battery" in result["reply"]
    assert "solar_plan" not in result["reply"] and "facts" not in result["reply"].lower()
