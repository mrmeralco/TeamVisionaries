"""CHECKPOINT h14 (Andy + Aldrin): the app's API is live and pushes updates.

Plan: "Knob turn updates the app". These check the server side of that: every endpoint the app calls
returns real data in the contract shape, and /ws/live pushes a new reading within seconds.
Then Aldrin checks the same thing by eye on the phone.
"""
import time

import pytest
from support import HUMAN_WAIT_S, wait_for
from sinag_contract import validate

pytestmark = pytest.mark.h14

ENDPOINTS = [("live", "/api/live"), ("energy", "/api/energy?period=day"), ("energy", "/api/energy?period=week"),
             ("energy", "/api/energy?period=month"), ("bill", "/api/bill"), ("brownout", "/api/brownout"),
             ("alerts", "/api/alerts"), ("summary", "/api/summary/daily"), ("settings", "/api/settings"),
             ("health", "/api/health")]


@pytest.mark.parametrize("schema,path", ENDPOINTS)
def test_every_app_endpoint_matches_contract(api, schema, path):
    r = api.get(path)
    assert r.status_code == 200, r.text
    validate(schema, r.json())


def test_endpoints_are_fast_enough_for_the_app(api):
    for _, path in ENDPOINTS:
        if path == "/api/health":
            continue
        t0 = time.monotonic()
        api.get(path)
        assert time.monotonic() - t0 < 2, f"{path} took {time.monotonic() - t0:.1f}s (the app will feel stuck)"


def test_there_is_history_for_the_charts(api):
    """Andy: seed history (tools/seed_history.py) so Energy and Bill aren't empty at the demo."""
    week = api.get("/api/energy?period=week").json()
    assert sum(p["load_kwh"] > 0 for p in week["points"]) >= 5, "fewer than 5 days of data this week"
    assert api.get("/api/bill").json()["last_month_php"] is not None, "no last-month data: 'vs last month' will be blank"


def test_knob_turn_is_pushed_on_websocket(api, ws, operator):
    """THE h14 checkpoint (server side): a new reading reaches /ws/live, shaped like GET /api/live."""
    ws.messages.clear()
    before = api.get("/api/live").json()["telemetry"] or {"pv_w": 0}
    target = 600 if before["pv_w"] > 2500 else 3800
    operator.act("Turn the SUN knob a lot, and watch the Home tab on the phone.", pv_w=target)
    msg = wait_for(lambda: next((m for m in ws.messages if m["type"] == "telemetry"
                                 and abs(m["data"]["telemetry"]["pv_w"] - before["pv_w"]) > 300), None),
                   timeout=15 if operator.fake else HUMAN_WAIT_S, what="a telemetry push with the new pv_w")
    validate("ws_message", msg)


def test_every_ws_message_matches_contract(ws, operator):
    operator.act("Leave the system running for ~12 s.")
    time.sleep(1 if operator.fake else 12)
    assert ws.messages, "no WebSocket messages at all"
    for m in ws.messages:
        validate("ws_message", m)


def test_settings_round_trip(api):
    """Aldrin: Settings screen writes and reads back."""
    before = api.get("/api/settings").json()
    try:
        r = api.put("/api/settings", json={"user_name": "Acceptance"})
        assert r.json()["user_name"] == "Acceptance"
        assert api.get("/api/settings").json()["user_name"] == "Acceptance"
    finally:
        api.put("/api/settings", json={"user_name": before["user_name"]})
