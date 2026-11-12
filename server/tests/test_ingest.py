"""SPEC (Andy): MQTT ingest. Contract B in, validated rows + live pushes out.

Calls ingest.handle_message() directly, exactly as the MQTT thread does, so no broker is needed.
"""
import json
import time

import pytest

from app import db, ingest


def tel(**kw):
    return json.dumps({"ts": int(time.time()), "pv_w": 3000, "load_w": 1500, "grid_w": 0, "batt_soc": 80,
                       "batt_w": -1500, "grid_on": True, "inv_temp_c": 42, "fault_code": 0} | kw).encode()


def test_valid_telemetry_is_stored(device):
    ingest.handle_message(f"solaris/{device}/telemetry", tel(pv_w=1234))
    assert db.latest_telemetry(device)["pv_w"] == 1234


def test_ts_zero_means_device_has_no_clock_yet(device):
    ingest.handle_message(f"solaris/{device}/telemetry", tel(ts=0))
    assert abs(db.latest_telemetry(device)["ts"] - time.time()) < 5


def test_wildly_wrong_clock_is_replaced(device):
    ingest.handle_message(f"solaris/{device}/telemetry", tel(ts=946684800))  # year 2000
    assert abs(db.latest_telemetry(device)["ts"] - time.time()) < 5


@pytest.mark.parametrize("bad", [
    b"not json",
    b'{"pv_w": 100}',                                     # missing fields
    tel(pv_w="lots"),                                     # wrong type
    tel(batt_soc=140),                                    # impossible value
])
def test_bad_payloads_are_rejected_not_crashing(device, bad):
    ingest.handle_message(f"solaris/{device}/telemetry", bad)
    assert db.latest_telemetry(device) is None


def test_unknown_topics_are_ignored(device):
    ingest.handle_message(f"other/{device}/telemetry", tel())
    ingest.handle_message(f"solaris/{device}/telemetry/extra", tel())
    assert db.latest_telemetry(device) is None


def test_meter_payload_is_stored(device):
    ingest.handle_message(f"solaris/{device}/meter", b'{"ts":0,"meter_type":"sdm120","voltage_v":230.1,"power_w":497,'
                                                    b'"import_kwh":1520.35,"export_kwh":12.4,"grid_on":true}')
    row = db.one("SELECT * FROM meter WHERE device_id=?", (device,))
    assert row["meter_type"] == "sdm120" and json.loads(row["data"])["voltage_v"] == 230.1


def test_last_will_marks_device_offline_and_alerts(device):
    ingest.handle_message(f"solaris/{device}/status", b'{"online":true,"rssi":-60,"fw":"0.3.0"}')
    ingest.handle_message(f"solaris/{device}/telemetry", tel())
    before = len(db.list_alerts())
    ingest.handle_message(f"solaris/{device}/status", b'{"online":false}')
    assert db.get_status(device)["online"] == 0
    assert db.get_status(device)["fw"] == "0.3.0"      # last will doesn't wipe the firmware version
    assert db.list_alerts()[0]["type"] == "device_offline" and len(db.list_alerts()) == before + 1


def test_coming_back_online_alerts(device):
    ingest.handle_message(f"solaris/{device}/status", b'{"online":true}')
    ingest.handle_message(f"solaris/{device}/telemetry", tel())
    ingest.handle_message(f"solaris/{device}/status", b'{"online":false}')
    ingest.handle_message(f"solaris/{device}/telemetry", tel())
    assert db.list_alerts()[0]["type"] == "device_online"


def test_brownout_reading_creates_alert_through_ingest(device):
    ingest.handle_message(f"solaris/{device}/telemetry", tel())
    ingest.handle_message(f"solaris/{device}/telemetry", tel(grid_on=False))
    assert db.list_alerts()[0]["type"] == "brownout"


def test_live_push_reaches_websocket(client):
    """Integration: a reading for the configured device is pushed on /ws/live within a moment."""
    dev = db.get_settings()["device_id"]
    with client.websocket_connect("/ws/live") as ws:
        ws.receive_json()  # initial snapshot
        ingest.handle_message(f"solaris/{dev}/telemetry", tel(pv_w=4321))
        for _ in range(5):
            m = ws.receive_json()
            if m["type"] == "telemetry":
                break
    assert m["data"]["telemetry"]["pv_w"] == 4321
