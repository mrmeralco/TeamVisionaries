"""DEMO FLOWS (Stephen runs these 5+ times after the hour-18 feature freeze).

Each test is one thing the panel will see. With SOLARIS_SOURCE=real it tells the simulator operator
what to press, exactly like the live demo.
"""
import time

import pytest
from support import DEVICE_ID, HUMAN_WAIT_S, wait_for
from solaris_contract import validate

pytestmark = pytest.mark.demo


def _alert(ws, type_, since):
    return next((m["data"] for m in ws.messages if m["type"] == "alert" and m["data"]["type"] == type_
                 and m["data"]["ts"] >= since), None)


def test_brownout_flow(api, ws, operator):
    """Brownout button -> alert on the phone, Home turns 'brownout', advisor shows runtime; restore -> 'bumalik na'."""
    t = operator.fake and 15 or HUMAN_WAIT_S
    since = int(time.time()) - 2
    operator.act("Hold the simulator button 1-3 s and release: BROWNOUT ON.", grid_on=False, pv_w=0, load_w=900, batt_w=900)
    try:
        a = wait_for(lambda: _alert(ws, "brownout", since), t, what="a 'brownout' alert on /ws/live")
        validate("alert", a)
        assert a["severity"] == "critical"
        assert api.get("/api/live").json()["state"] in ("brownout", "fault")
        bo = api.get("/api/brownout").json()
        validate("brownout", bo)
        assert bo["active"] and bo["runtime_h"] and bo["runtime_h"] > 0 and "brownout" in bo["advice"].lower()
    finally:
        operator.act("Hold the button 1-3 s again: BROWNOUT OFF.", grid_on=True, pv_w=2500, load_w=1200, batt_w=-1300)
    wait_for(lambda: _alert(ws, "grid_restored", since), t, what="a 'grid_restored' alert")
    assert api.get("/api/brownout").json()["active"] is False


def test_fault_flow(api, ws, operator):
    """Fault button -> critical alert explaining fault 21 in Taglish; Home shows 'fault'; chat can explain it."""
    t = operator.fake and 15 or HUMAN_WAIT_S
    since = int(time.time()) - 2
    operator.act("Hold the simulator button 3-6 s and release: FAULT 21 ON.", fault_code=21, inv_temp_c=78)
    try:
        a = wait_for(lambda: _alert(ws, "fault", since), t, what="a 'fault' alert")
        assert "21" in a["title"] and len(a["message"]) > 20
        assert api.get("/api/live").json()["state"] == "fault"
        r = api.post("/api/chat", json={"message": "May problema ba ang inverter ko?"}).json()
        assert "21" in r["reply"] or "init" in r["reply"].lower(), f"chat didn't mention the fault: {r['reply']}"
    finally:
        operator.act("Hold the button 3-6 s again: FAULT OFF.", fault_code=0, inv_temp_c=42)
    wait_for(lambda: api.get("/api/live").json()["state"] != "fault", t, what="fault to clear")


def test_low_battery_alert(api, ws, operator):
    if not operator.fake:
        pytest.skip("on hardware: set SOC to <20% with the knob (SOC target) and check the Alerts tab by eye")
    since = int(time.time()) - 2
    operator.publish(batt_soc=50)
    operator.publish(batt_soc=15)
    wait_for(lambda: _alert(ws, "low_battery", since), 10, what="a 'low_battery' alert")
    operator.publish(batt_soc=70)


def test_ask_mira_bill_question(api):
    """Plan, workstream 3: 'Bakit mataas ang bill ko?' returns a correct Taglish answer in under 10 s using live data."""
    t0 = time.monotonic()
    r = api.post("/api/chat", json={"message": "Bakit mataas ang bill ko?"})
    dt = time.monotonic() - t0
    body = r.json()
    validate("chat", body)
    bill = api.get("/api/bill").json()
    assert dt < 10, f"chat took {dt:.1f}s (target < 10 s)"
    assert body["source"] == "llm", "answered by the rule-based fallback: is Ollama up and the model pulled? (GET /api/health)"
    assert f"{bill['month_to_date_php']:,.0f}" in body["reply"] or f"{bill['forecast_php']:,.0f}" in body["reply"] \
        or body["facts_used"], f"reply doesn't use the bill data: {body['reply']}"


def test_ask_mira_refuses_off_topic(api):
    body = api.post("/api/chat", json={"message": "Sino ang nanalo sa NBA finals?"}).json()
    if body["source"] == "llm":
        assert body["facts_used"] == [] and "hindi ko pa alam" in body["reply"].lower()


def test_daily_summary_is_ready(api):
    """Pre-generated, so the Home card loads instantly."""
    t0 = time.monotonic()
    s = api.get("/api/summary/daily").json()
    assert time.monotonic() - t0 < 2 and s["summary"]


def test_device_offline_flow(api, ws, operator, mqtt_client):
    """Unplug the Solaris device -> 'offline' alert and Home shows offline; plug back -> online again."""
    if not operator.fake:
        pytest.skip("on hardware: unplug the Solaris device, wait ~30 s, check the app shows Offline, plug back in")
    import json
    since = int(time.time()) - 2
    mqtt_client.publish(f"solaris/{DEVICE_ID}/status", json.dumps({"online": False}), qos=1, retain=True)
    wait_for(lambda: _alert(ws, "device_offline", since), 10, what="a 'device_offline' alert")
    assert api.get("/api/live").json()["device"]["online"] is False
    mqtt_client.publish(f"solaris/{DEVICE_ID}/status", json.dumps({"online": True, "fw": "acceptance"}), qos=1, retain=True)
    operator.publish()
    wait_for(lambda: api.get("/api/live").json()["device"]["online"], 10, what="device back online")
