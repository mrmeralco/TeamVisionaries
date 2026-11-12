"""SPEC (Andy): every Contract C endpoint returns exactly the shape in docs/contracts/schema.json,
in real mode AND in mock mode, and the example files the app team builds against match too.

If one of these fails after you change the backend, you broke the Flutter app.
"""
import json

import pytest
from sinag_contract import validate

from app import config

ENDPOINTS = [
    ("live", "/api/live"),
    ("energy", "/api/energy?period=day"),
    ("energy", "/api/energy?period=week"),
    ("energy", "/api/energy?period=month"),
    ("bill", "/api/bill"),
    ("brownout", "/api/brownout"),
    ("alerts", "/api/alerts"),
    ("summary", "/api/summary/daily"),
    ("settings", "/api/settings"),
    ("health", "/api/health"),
]


@pytest.mark.parametrize("schema,path", ENDPOINTS)
def test_real_mode_endpoint_matches_contract(client, schema, path):
    r = client.get(path)
    assert r.status_code == 200, r.text
    validate(schema, r.json())


@pytest.mark.parametrize("schema,path", ENDPOINTS)
def test_mock_mode_endpoint_matches_contract(mock_client, schema, path):
    r = mock_client.get(path)
    assert r.status_code == 200, r.text
    validate(schema, r.json())


EXAMPLES = {
    "live.json": "live", "energy_day.json": "energy", "energy_week.json": "energy", "energy_month.json": "energy",
    "bill.json": "bill", "brownout.json": "brownout", "alerts.json": "alerts", "chat.json": "chat",
    "summary_daily.json": "summary", "settings.json": "settings",
}


@pytest.mark.parametrize("name,schema", EXAMPLES.items())
def test_example_files_match_contract(name, schema):
    validate(schema, json.loads((config.EXAMPLES_DIR / name).read_text()))


def test_ws_examples_match_contract():
    for msg in json.loads((config.EXAMPLES_DIR / "ws_messages.json").read_text()):
        validate("ws_message", msg)


def test_energy_has_one_point_per_bucket(client):
    assert len(client.get("/api/energy?period=day").json()["points"]) == 24
    assert len(client.get("/api/energy?period=week").json()["points"]) == 7
    month = client.get("/api/energy?period=month").json()
    assert len(month["points"]) == client.get("/api/bill").json()["days_in_month"]


def test_energy_rejects_unknown_period(client):
    assert client.get("/api/energy?period=year").status_code == 422


def test_chat_matches_contract(client):
    r = client.post("/api/chat", json={"message": "Bakit mataas ang bill ko?"})
    assert r.status_code == 200
    validate("chat", r.json())


def test_chat_rejects_empty_message(client):
    assert client.post("/api/chat", json={"message": ""}).status_code == 422


def test_settings_put_is_partial_and_returns_full_object(client):
    before = client.get("/api/settings").json()
    r = client.put("/api/settings", json={"rate_php_per_kwh": 12.5})
    validate("settings", r.json())
    assert r.json() == before | {"rate_php_per_kwh": 12.5}
    client.put("/api/settings", json={"rate_php_per_kwh": before["rate_php_per_kwh"]})


def test_settings_rejects_nonsense(client):
    assert client.put("/api/settings", json={"rate_php_per_kwh": -1}).status_code == 422


def test_rate_change_changes_the_bill(client):
    before = client.get("/api/bill").json()
    client.put("/api/settings", json={"rate_php_per_kwh": before["rate_php_per_kwh"] * 2})
    after = client.get("/api/bill").json()
    client.put("/api/settings", json={"rate_php_per_kwh": before["rate_php_per_kwh"]})
    assert after["month_to_date_php"] == pytest.approx(before["month_to_date_php"] * 2, rel=0.01)


def test_alert_read_flow(client):
    from app import db
    a = db.insert_alert("sinag-001", 1, "low_battery", "warning", "t", "m")
    assert client.get("/api/alerts").json()["unread"] >= 1
    r = client.post(f"/api/alerts/{a['id']}/read")
    validate("alert", r.json())
    assert r.json()["read"] is True
    assert client.post("/api/alerts/read-all").json() == {"unread": 0}
    assert client.get("/api/alerts?unread_only=true").json()["alerts"] == []
    assert client.post("/api/alerts/999999/read").status_code == 404


def test_ws_sends_live_on_connect(client):
    with client.websocket_connect("/ws/live") as ws:
        msg = ws.receive_json()
    validate("ws_message", msg)
    assert msg["type"] == "telemetry"


@pytest.fixture
def fast_mock_push(monkeypatch):
    from app import mock
    monkeypatch.setattr(mock, "PUSH_EVERY_S", 0.05)


def test_mock_ws_pushes_readings(fast_mock_push, mock_client):
    with mock_client.websocket_connect("/ws/live") as ws:
        first, pushed = ws.receive_json(), ws.receive_json()
    validate("ws_message", first)
    validate("ws_message", pushed)
