"""Alert engine: runs on every telemetry reading and raises an alert on each *change* of state.

Rules (plan, workstream 2): fault_code != 0, grid_on false (outage log), batt_soc < 20 %, temp > 60 °C.
Hysteresis keeps a value hovering at a threshold from spamming alerts.
"""
from ai.faults import explain_fault

from . import db

LOW_BATT_ON, LOW_BATT_OFF = 20, 25
HIGH_TEMP_ON, HIGH_TEMP_OFF = 60, 55

# Per-device edge-detection state, rebuilt from the first reading after a restart.
_state: dict[str, dict] = {}


def evaluate(device_id: str, t: dict) -> list[dict]:
    """Returns the alerts created for this reading (already stored)."""
    prev = _state.get(device_id)
    now = {
        "fault_code": t["fault_code"],
        "grid_on": t["grid_on"],
        "low_batt": t["batt_soc"] < LOW_BATT_ON or (prev is not None and prev["low_batt"] and t["batt_soc"] < LOW_BATT_OFF),
        "high_temp": t["inv_temp_c"] > HIGH_TEMP_ON or (prev is not None and prev["high_temp"] and t["inv_temp_c"] > HIGH_TEMP_OFF),
    }
    _state[device_id] = now
    if prev is None:
        # First reading since startup: don't re-alert conditions that were already on,
        # but do catch a brownout that started or ended while the server was down.
        prev = {**now, "grid_on": db.open_outage(device_id) is None}

    ts = t["ts"]
    out: list[dict] = []

    if now["fault_code"] != prev["fault_code"] and now["fault_code"] != 0:
        f = explain_fault(now["fault_code"])
        out.append(db.insert_alert(device_id, ts, "fault", "critical", f"Fault {now['fault_code']}: {f['title']}", f["message"]))

    if prev["grid_on"] and not now["grid_on"]:
        _sync_outage(device_id, t)
        out.append(db.insert_alert(device_id, ts, "brownout", "critical", "Brownout",
                                   "Nawalan ng kuryente mula sa grid. Battery at solar na ang gamit ng bahay mo."))
    elif not prev["grid_on"] and now["grid_on"]:
        o = db.open_outage(device_id)
        mins = round((ts - o["start_ts"]) / 60) if o else None
        _sync_outage(device_id, t)
        dur = f" pagkatapos ng {mins} minuto" if mins is not None else ""
        out.append(db.insert_alert(device_id, ts, "grid_restored", "info", "Bumalik na ang kuryente",
                                   f"Bumalik na ang grid{dur}. Magcha-charge ulit ang battery."))

    if now["low_batt"] and not prev["low_batt"]:
        out.append(db.insert_alert(device_id, ts, "low_battery", "warning", "Mababa na ang battery",
                                   f"{t['batt_soc']}% na lang ang battery. Bawasan muna ang malalaking appliances."))

    if now["high_temp"] and not prev["high_temp"]:
        out.append(db.insert_alert(device_id, ts, "high_temp", "warning", "Mainit ang inverter",
                                   f"{t['inv_temp_c']}°C ang inverter. Siguraduhing may hangin sa paligid nito."))
    return out


def _sync_outage(device_id: str, t: dict) -> None:
    o = db.open_outage(device_id)
    if not t["grid_on"] and o is None:
        db.execute("INSERT INTO outages (device_id, start_ts) VALUES (?, ?)", (device_id, t["ts"]))
    elif t["grid_on"] and o is not None:
        db.execute("UPDATE outages SET end_ts=? WHERE id=?", (t["ts"], o["id"]))


def device_online_changed(device_id: str, online: bool, ts: int) -> dict:
    if online:
        return db.insert_alert(device_id, ts, "device_online", "info", "Konektado na ang Solaris device",
                               "Tumatanggap na ulit ng data mula sa inverter.")
    return db.insert_alert(device_id, ts, "device_offline", "warning", "Offline ang Solaris device",
                           "Walang natatanggap na data. Tingnan kung naka-on ang device at ang Wi-Fi.")
