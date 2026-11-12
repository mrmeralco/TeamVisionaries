"""Acceptance tests run against the RUNNING system: server + MQTT broker (+ real hardware if you have it).

    SOLARIS_SOURCE=fake  (default)  the test plays the Solaris device: it publishes Contract B readings itself
    SOLARIS_SOURCE=real             the real device + simulator are on; the test tells YOU what to press

Env: SOLARIS_API (http://localhost:8000), MQTT_HOST (localhost), MQTT_PORT (1883), SOLARIS_DEVICE_ID (solaris-001),
     SOLARIS_SERIAL (USB-RS485 port, hardware tests only), SOLARIS_WAIT_S (60, how long to wait for a human).

Fake mode writes test readings into the server's DB. Run it against a dev DB, then reseed.
"""
import json
import os
import queue
import sys
import threading
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))  # solaris_contract.py

from support import API, DEVICE_ID, MQTT_HOST, MQTT_PORT, SOURCE  # noqa: E402


def pytest_configure(config):
    for m in ("h10: checkpoint hour 8-10, device -> MQTT -> backend -> DB",
              "h14: checkpoint hour 10-14, backend -> app (REST + WebSocket)",
              "demo: hour-18 demo flows (brownout, fault, chat, offline)",
              "hardware: needs the simulator on a USB-RS485 dongle (SOLARIS_SERIAL)",
              "real_only: only meaningful with SOLARIS_SOURCE=real"):
        config.addinivalue_line("markers", m)


def pytest_collection_modifyitems(config, items):
    for item in items:
        if "real_only" in item.keywords and SOURCE != "real":
            item.add_marker(pytest.mark.skip(reason="needs the real Solaris device (SOLARIS_SOURCE=real)"))


@pytest.fixture(scope="session")
def api():
    import httpx
    c = httpx.Client(base_url=API, timeout=30)
    try:
        c.get("/api/health").raise_for_status()
    except httpx.HTTPError as e:
        pytest.skip(f"server not reachable at {API} ({e}). Start it: cd server && uvicorn app.main:app --host 0.0.0.0")
    if c.get("/api/health").json().get("mock"):
        pytest.skip("server is in SOLARIS_MOCK=1 mode; acceptance tests need real mode")
    yield c
    c.close()


@pytest.fixture(scope="session")
def mqtt_client():
    import paho.mqtt.client as mqtt
    c = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=f"solaris-acceptance-{os.getpid()}")
    try:
        c.connect(MQTT_HOST, MQTT_PORT, keepalive=30)
    except OSError as e:
        pytest.skip(f"MQTT broker not reachable at {MQTT_HOST}:{MQTT_PORT} ({e}). Start it: mosquitto -c server/mosquitto.conf")
    c.loop_start()
    yield c
    c.loop_stop()
    c.disconnect()


@pytest.fixture
def mqtt_messages(mqtt_client):
    """subscribe(topic) -> queue of (topic, dict) for messages on that topic."""
    subs = []

    def subscribe(topic):
        q = queue.Queue()
        mqtt_client.message_callback_add(topic, lambda c, u, m: q.put((m.topic, json.loads(m.payload or b"{}"), m.retain)))
        mqtt_client.subscribe(topic)
        subs.append(topic)
        return q

    yield subscribe
    for t in subs:
        mqtt_client.unsubscribe(t)
        mqtt_client.message_callback_remove(t)


@pytest.fixture
def ws():
    """Live /ws/live connection. ws.messages is a list that fills in the background."""
    from websockets.sync.client import connect
    url = API.replace("http", "ws", 1) + "/ws/live"
    try:
        conn = connect(url, open_timeout=5)
    except OSError as e:
        pytest.skip(f"WebSocket not reachable at {url} ({e})")
    conn.messages = []

    def reader():
        try:
            for raw in conn:
                conn.messages.append(json.loads(raw))
        except Exception:
            pass

    threading.Thread(target=reader, daemon=True).start()
    yield conn
    conn.close()


class Operator:
    """Makes things happen: publishes fake readings (fake mode) or asks the human at the simulator (real mode)."""

    def __init__(self, request, mqtt_client=None):
        self.capman = request.config.pluginmanager.getplugin("capturemanager")
        self.mqtt = mqtt_client
        self.state = {"pv_w": 2500, "load_w": 1200, "grid_w": 0, "batt_soc": 70, "batt_w": -1300,
                      "grid_on": True, "inv_temp_c": 42, "fault_code": 0}

    @property
    def fake(self) -> bool:
        return SOURCE != "real"

    def say(self, msg: str) -> None:
        with self.capman.global_and_fixture_disabled():
            print(f"\n\n  >>> OPERATOR: {msg}\n", flush=True)

    def publish(self, **changes) -> None:
        self.state |= changes
        s = self.state
        if s["grid_on"]:
            s["grid_w"] = s["load_w"] - s["pv_w"] - s["batt_w"]
        else:
            s["grid_w"] = 0
        self.mqtt.publish(f"solaris/{DEVICE_ID}/telemetry", json.dumps({"ts": int(time.time()), **s}))

    def act(self, human_instruction: str, **fake_changes) -> None:
        if self.fake:
            self.publish(**fake_changes)
        else:
            self.say(human_instruction)


@pytest.fixture
def operator(request):
    mq = request.getfixturevalue("mqtt_client") if SOURCE != "real" else None
    op = Operator(request, mq)
    if op.fake:
        op.mqtt.publish(f"solaris/{DEVICE_ID}/status", json.dumps({"online": True, "rssi": -50, "fw": "acceptance"}), qos=1, retain=True)
        op.publish()
    return op
