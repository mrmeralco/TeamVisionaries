"""CHECKPOINT h10 (Adrian + Andy): real Sinag device -> MQTT -> backend -> DB.

Plan: "Done when turning a knob changes the JSON seen in mosquitto_sub within 5 s" and "knob turn appears in DB".
"""
import time

import pytest
from support import DEVICE_ID, HUMAN_WAIT_S, wait_for
from sinag_contract import errors, validate

pytestmark = pytest.mark.h10


@pytest.mark.real_only
def test_device_publishes_contract_b_every_5s(mqtt_messages):
    """Adrian: the Sinag device's JSON matches Contract B and arrives every ~5 s."""
    q = mqtt_messages(f"sinag/{DEVICE_ID}/telemetry")
    stamps = []
    for _ in range(3):
        _, payload, _ = q.get(timeout=15)
        validate("telemetry", payload)
        stamps.append(time.monotonic())
    gaps = [b - a for a, b in zip(stamps, stamps[1:])]
    assert all(3.5 <= g <= 7.5 for g in gaps), f"publish interval should be ~5 s, got {gaps}"


@pytest.mark.real_only
def test_device_has_ntp_time(mqtt_messages):
    """ts=0 is allowed (backend falls back) but the device should get NTP on the hotspot."""
    _, payload, _ = mqtt_messages(f"sinag/{DEVICE_ID}/telemetry").get(timeout=15)
    assert payload["ts"] > 1_700_000_000, "ts is 0: the device has no NTP time (check internet on the hotspot)"


@pytest.mark.real_only
def test_device_status_is_retained_and_online(mqtt_messages):
    _, payload, retained = mqtt_messages(f"sinag/{DEVICE_ID}/status").get(timeout=10)
    validate("status", payload)
    assert retained and payload["online"] is True and payload.get("fw")


@pytest.mark.real_only
def test_device_energy_balance_is_consistent(mqtt_messages):
    """load = pv + grid + battery (the simulator keeps this; a real inverter roughly does)."""
    _, t, _ = mqtt_messages(f"sinag/{DEVICE_ID}/telemetry").get(timeout=15)
    if t["grid_on"]:
        assert abs(t["pv_w"] + t["grid_w"] + t["batt_w"] - t["load_w"]) <= max(50, 0.05 * t["load_w"]), t


def test_reading_reaches_the_api(api, operator):
    """Andy: a reading on MQTT shows up in GET /api/live within 10 s."""
    since = time.time() - 1
    operator.act("Make sure the Sinag device is on and connected (LED solid).")
    live = wait_for(lambda: (r := api.get("/api/live").json())["telemetry"] and r["telemetry"]["ts"] >= since and r,
                    timeout=15 if operator.fake else HUMAN_WAIT_S, what="a fresh reading in /api/live")
    validate("live", live)
    assert live["device"]["online"] is True and live["device"]["id"] == DEVICE_ID


def test_knob_turn_shows_in_api(api, operator):
    """THE h10 checkpoint: turning the Sun knob changes pv_w seen by the backend."""
    start = api.get("/api/live").json()["telemetry"] or {"pv_w": 0}
    target = 500 if start["pv_w"] > 2500 else 4000
    operator.act(f"Turn the SUN knob {'DOWN' if target < start['pv_w'] else 'UP'} a lot (now {start['pv_w']} W).", pv_w=target)
    wait_for(lambda: abs(api.get("/api/live").json()["telemetry"]["pv_w"] - start["pv_w"]) > 300,
             timeout=15 if operator.fake else HUMAN_WAIT_S, what="pv_w to change by >300 W")


def test_bad_payload_does_not_break_the_server(api, mqtt_client, operator):
    """Garbage on the topic is logged and ignored; the next good reading still works."""
    if not operator.fake:
        pytest.skip("fake mode only")
    mqtt_client.publish(f"sinag/{DEVICE_ID}/telemetry", b"{broken json")
    mqtt_client.publish(f"sinag/{DEVICE_ID}/telemetry", b'{"pv_w": "lots"}')
    operator.publish(pv_w=1111)
    wait_for(lambda: api.get("/api/live").json()["telemetry"]["pv_w"] == 1111, timeout=10, what="the good reading")
    assert not errors("live", api.get("/api/live").json())
