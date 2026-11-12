"""Disconnects must replace the live snapshot and never expose old RSSI as current."""
import json
import threading
import time

import pytest

from app import config, db, energy, hub, ingest


def reading(device, ts=None):
    ingest.handle_message(f"solaris/{device}/status", b'{"online":true,"rssi":-45,"fw":"test"}')
    ingest.handle_message(f"solaris/{device}/telemetry", json.dumps({
        "ts": ts or int(time.time()), "pv_w": 1000, "load_w": 500, "grid_w": 0,
        "batt_soc": 80, "batt_w": -500, "grid_on": True, "inv_temp_c": 40, "fault_code": 0,
    }).encode())


@pytest.mark.parametrize("disconnect", ["last_will", "stale"])
def test_disconnect_pushes_offline_snapshot_without_signal(device, monkeypatch, disconnect):
    monkeypatch.setattr(ingest, "_online", {})
    monkeypatch.setattr(config, "OFFLINE_AFTER_S", 3600)
    monkeypatch.setitem(config.DEFAULT_SETTINGS, "device_id", device)
    monkeypatch.setattr(db, "get_settings", lambda: config.DEFAULT_SETTINGS)
    reading(device, ts=int(time.time()) - 31 if disconnect == "stale" else None)
    pushes = []
    monkeypatch.setattr(hub, "publish_threadsafe", lambda kind, data: pushes.append((kind, data)))
    if disconnect == "last_will":
        ingest.handle_message(f"solaris/{device}/status", b'{"online":false}')
    else:
        monkeypatch.setattr(config, "OFFLINE_AFTER_S", 30)
        ingest.check_stale()
    snapshots = [data for kind, data in pushes if kind == "telemetry"]
    assert snapshots, "Device status must also push a complete Home snapshot"
    assert snapshots[-1]["state"] == "offline"
    assert snapshots[-1]["device"]["online"] is False
    assert snapshots[-1]["device"]["rssi"] is None
    assert db.get_status(device)["rssi"] == -45  # Keep history internally.


def test_fresh_telemetry_recovers_after_last_will(device, monkeypatch):
    monkeypatch.setattr(ingest, "_online", {})
    reading(device)
    ingest.handle_message(f"solaris/{device}/status", b'{"online":false}')
    ingest.handle_message(f"solaris/{device}/telemetry", json.dumps(db.latest_telemetry(device)).encode())
    assert energy.device_info(device, db.latest_telemetry(device))["online"] is True


def test_retained_status_restores_stale_monitoring_after_server_restart(device, monkeypatch):
    monkeypatch.setattr(ingest, "_online", {})
    monkeypatch.setattr(config, "OFFLINE_AFTER_S", 3600)
    reading(device, ts=int(time.time()) - 31)
    ingest._online.clear()  # The backend restarts, but SQLite and broker retention survive.
    ingest.handle_message(f"solaris/{device}/status", b'{"online":true,"rssi":-45}')
    monkeypatch.setattr(config, "OFFLINE_AFTER_S", 30)
    pushes = []
    monkeypatch.setattr(hub, "publish_threadsafe", lambda kind, data: pushes.append((kind, data)))
    ingest.check_stale()
    assert any(kind == "status" and data["online"] is False for kind, data in pushes)


def test_slow_weather_does_not_delay_offline_snapshot(device, monkeypatch):
    from fastapi.testclient import TestClient
    from app import weather
    from app.main import app

    release_weather = threading.Event()
    weather_started = threading.Event()

    def slow_weather():
        weather_started.set()
        release_weather.wait(timeout=15)

    monkeypatch.setattr(ingest, "_online", {})
    monkeypatch.setattr(config, "WEATHER_ENABLED", True)
    monkeypatch.setattr(config, "OFFLINE_AFTER_S", 1)
    monkeypatch.setattr(weather, "refresh", slow_weather)
    settings = db.get_settings() | {"device_id": device}
    monkeypatch.setattr(db, "get_settings", lambda: settings)
    reading(device)
    pushes = []
    monkeypatch.setattr(hub, "publish_threadsafe", lambda kind, data: pushes.append((kind, data)))
    try:
        with TestClient(app):
            assert weather_started.wait(timeout=7)
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline and not any(
                    kind == "telemetry" and data["state"] == "offline" for kind, data in pushes):
                time.sleep(0.05)
            assert any(kind == "telemetry" and data["state"] == "offline" for kind, data in pushes)
            release_weather.set()
    finally:
        release_weather.set()
