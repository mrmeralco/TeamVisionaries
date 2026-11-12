"""Contract C tests: docs/contracts/examples/*.json, mock mode and real mode all match app/schemas.py.

If one of these fails, the doc, the examples and the backend disagree. Fix whichever is wrong,
and if the contract itself has to change, post in the group chat first (docs/contracts/README.md).
"""
import json

import pytest
from fastapi.testclient import TestClient
from pydantic import BaseModel, TypeAdapter

from app import config, db
from app import schemas as S
from app.main import app

EXAMPLES = {
    "live": S.Live,
    "energy_day": S.Energy,
    "energy_week": S.Energy,
    "energy_month": S.Energy,
    "bill": S.Bill,
    "brownout": S.Brownout,
    "outlook": S.Outlook,
    "upgrade": S.Upgrade,
    "bill_projection": S.Projection,
    "alerts": S.AlertList,
    "chat": S.Chat,
    "summary_daily": S.DailySummary,
    "settings": S.Settings,
}

GETS = {
    "/api/live": S.Live,
    "/api/energy?period=day": S.Energy,
    "/api/energy?period=week": S.Energy,
    "/api/energy?period=month": S.Energy,
    "/api/bill": S.Bill,
    "/api/brownout": S.Brownout,
    "/api/outlook": S.Outlook,
    "/api/upgrade": S.Upgrade,
    "/api/bill/projection": S.Projection,
    "/api/alerts": S.AlertList,
    "/api/summary/daily": S.DailySummary,
    "/api/settings": S.Settings,
    "/api/health": S.Health,
}


def example(name: str):
    return json.loads((config.EXAMPLES_DIR / f"{name}.json").read_text(encoding="utf-8"))


def assert_exact(model: type[BaseModel], data: dict) -> None:
    """Valid AND nothing extra: a field the model doesn't know would be dropped by the round trip."""
    assert model.model_validate(data).model_dump(exclude_unset=True) == data


@pytest.fixture
def client():
    # No `with`: skips lifespan, so no MQTT thread and no Ollama warm-up.
    return TestClient(app)


@pytest.fixture
def no_llm(monkeypatch):
    monkeypatch.setattr(config, "LLM_ENABLED", False)


@pytest.fixture
def mock_mode(monkeypatch):
    monkeypatch.setattr(config, "MOCK", True)


# ---------------------------------------------------------------- examples --
def test_every_example_file_is_covered():
    files = {p.stem for p in config.EXAMPLES_DIR.glob("*.json")}
    assert files == set(EXAMPLES) | {"ws_messages"}


@pytest.mark.parametrize("name", sorted(EXAMPLES))
def test_example_matches_schema(name):
    assert_exact(EXAMPLES[name], example(name))


def test_ws_examples_match_schema():
    msgs = example("ws_messages")
    adapter = TypeAdapter(S.WsMessage)
    for m in msgs:
        parsed = adapter.validate_python(m)
        assert parsed.model_dump(exclude_unset=True) == m
    assert {m["type"] for m in msgs} >= {"telemetry", "alert", "status"}


def test_energy_examples_have_expected_point_counts():
    assert len(example("energy_day")["points"]) == 24
    assert len(example("energy_week")["points"]) == 7


# --------------------------------------------------------------- mock mode --
@pytest.mark.parametrize("path", sorted(GETS))
def test_mock_get(client, mock_mode, no_llm, path):
    r = client.get(path)
    assert r.status_code == 200, r.text
    GETS[path].model_validate(r.json())


def test_mock_posts(client, mock_mode):
    assert client.post("/api/chat", json={"message": "Kumusta?"}).status_code == 200
    assert client.post("/api/alerts/read-all").json() == {"unread": 0}
    aid = example("alerts")["alerts"][0]["id"]
    assert client.post(f"/api/alerts/{aid}/read").json()["read"] is True
    assert client.post("/api/alerts/999999/read").status_code == 404


def test_mock_ws_sends_telemetry_first(client, mock_mode):
    with client.websocket_connect("/ws/live") as ws:
        S.WsTelemetry.model_validate(ws.receive_json())


# --------------------------------------------------------------- real mode --
@pytest.mark.parametrize("path", sorted(GETS))
def test_real_get(client, no_llm, path):
    r = client.get(path)
    assert r.status_code == 200, r.text
    assert_exact(GETS[path], r.json())


def test_real_energy_point_counts(client):
    assert len(client.get("/api/energy?period=day").json()["points"]) == 24
    assert len(client.get("/api/energy?period=week").json()["points"]) == 7
    assert client.get("/api/energy?period=year").status_code == 422


def test_real_chat_fallback(client, no_llm):
    r = client.post("/api/chat", json={"message": "Magkano ang bill ko ngayong buwan?"})
    assert r.status_code == 200, r.text
    body = S.Chat.model_validate(r.json())
    assert body.source == "fallback"
    assert client.post("/api/chat", json={"message": ""}).status_code == 422


def test_real_settings_put_returns_full_object(client):
    before = client.get("/api/settings").json()
    try:
        r = client.put("/api/settings", json={"user_name": "Maria"})
        assert r.status_code == 200
        assert_exact(S.Settings, r.json())
        assert r.json() == before | {"user_name": "Maria"}
        assert client.put("/api/settings", json={"rate_php_per_kwh": -1}).status_code == 422
    finally:
        db.put_settings(before)


def test_real_alerts_read(client):
    a = db.insert_alert("solaris-001", 1794446366, "high_temp", "warning", "Test", "Test alert")
    r = client.post(f"/api/alerts/{a['id']}/read")
    assert r.status_code == 200
    assert_exact(S.Alert, r.json())
    assert r.json()["read"] is True
    assert client.post("/api/alerts/read-all").json() == {"unread": 0}
    assert client.get("/api/alerts?unread_only=true").json()["alerts"] == []


def test_real_ws_sends_telemetry_first(client):
    with client.websocket_connect("/ws/live") as ws:
        S.WsTelemetry.model_validate(ws.receive_json())
