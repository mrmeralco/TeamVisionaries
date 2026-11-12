"""MQTT subscriber: solaris/+/telemetry | meter | status  ->  validate  ->  SQLite  ->  alerts  ->  /ws/live.

Runs paho-mqtt's network loop in its own thread and reconnects on its own if the broker restarts.
"""
import json
import logging
import time

import paho.mqtt.client as mqtt

from . import alerts, config, db, energy, hub

log = logging.getLogger("solaris.ingest")
_client: mqtt.Client | None = None
# device_id -> online as last announced. Unknown devices (just after startup) raise no alerts.
_online: dict[str, bool] = {}

TELEMETRY_INT = ("pv_w", "load_w", "grid_w", "batt_soc", "batt_w", "inv_temp_c", "fault_code")


def _publish_live(device_id: str) -> None:
    settings = db.get_settings()
    if device_id == settings["device_id"]:
        hub.publish_threadsafe("telemetry", energy.live(device_id, settings))


def validate_telemetry(p: dict) -> dict:
    """Contract B -> clean dict. Raises ValueError on a bad payload."""
    t = {k: int(round(float(p[k]))) for k in TELEMETRY_INT}
    t["grid_on"] = bool(p["grid_on"])
    ts = int(p.get("ts") or 0)
    now = int(time.time())
    # ts 0 = device has no NTP yet. Also distrust clocks that are way off.
    t["ts"] = ts if abs(ts - now) < 3600 else now
    if not 0 <= t["batt_soc"] <= 100:
        raise ValueError(f"batt_soc out of range: {t['batt_soc']}")
    return t


METER_TYPES = ("sdm120", "ansi-c12")
METER_NUM = ("voltage_v", "current_a", "power_w", "apparent_va", "reactive_var", "pf", "freq_hz", "import_kwh", "export_kwh")
METER_REQUIRED = ("voltage_v", "power_w", "import_kwh", "export_kwh")


def validate_meter(p: dict) -> dict:
    """Contract B meter payload -> clean dict. Raises ValueError/KeyError on a bad payload."""
    if p.get("meter_type") not in METER_TYPES:
        raise ValueError(f"unknown meter_type: {p.get('meter_type')!r}")
    m: dict = {"meter_type": p["meter_type"]}
    for k in METER_NUM:
        if p.get(k) is not None:
            m[k] = float(p[k])
    for k in METER_REQUIRED:
        if k not in m:
            raise KeyError(k)
    if "pf" in m and not -1 <= m["pf"] <= 1:
        raise ValueError(f"pf out of range: {m['pf']}")
    m["grid_on"] = bool(p["grid_on"]) if "grid_on" in p else m["voltage_v"] > 100  # Contract B: V > 100
    ts = int(p.get("ts") or 0)
    now = int(time.time())
    m["ts"] = ts if abs(ts - now) < 3600 else now
    return m


def handle_message(topic: str, payload: bytes) -> None:
    parts = topic.split("/")
    if len(parts) != 3 or parts[0] != "solaris":
        return
    device_id, kind = parts[1], parts[2]
    try:
        p = json.loads(payload or b"{}")
    except json.JSONDecodeError:
        log.warning("bad JSON on %s: %r", topic, payload[:200])
        return

    if kind == "telemetry":
        try:
            t = validate_telemetry(p)
        except (KeyError, ValueError, TypeError) as e:
            log.warning("rejected telemetry from %s: %s", device_id, e)
            return
        db.insert_telemetry(device_id, t)
        db.set_status(device_id, True)
        if _online.get(device_id) is False:
            hub.publish_threadsafe("alert", alerts.device_online_changed(device_id, True, t["ts"]))
        _online[device_id] = True
        for a in alerts.evaluate(device_id, t):
            hub.publish_threadsafe("alert", a)
        _publish_live(device_id)

    elif kind == "meter":
        try:
            m = validate_meter(p)
        except (KeyError, ValueError, TypeError) as e:
            log.warning("rejected meter reading from %s: %s", device_id, e)
            return
        db.insert_meter(device_id, m["ts"], m)
        hub.publish_threadsafe("meter", {"device_id": device_id, **m})
        s = db.get_settings()
        if device_id == s["device_id"] and not energy.has_solar(s):
            # Meter-only home: the meter is the device's heartbeat, outage detector and live reading.
            if _online.get(device_id) is False:
                hub.publish_threadsafe("alert", alerts.device_online_changed(device_id, True, m["ts"], "meter"))
            _online[device_id] = True
            for a in alerts.evaluate_meter(device_id, m):
                hub.publish_threadsafe("alert", a)
            hub.publish_threadsafe("telemetry", energy.live(device_id, s))

    elif kind == "status":
        online = bool(p.get("online"))
        db.set_status(device_id, online, p.get("rssi"), p.get("fw"))
        if device_id not in _online and energy.device_info(device_id, db.latest_telemetry(device_id))["online"]:
            _online[device_id] = True
        if not online and _online.get(device_id):
            _online[device_id] = False
            hub.publish_threadsafe("alert", alerts.device_online_changed(device_id, False, int(time.time())))
        hub.publish_threadsafe("status", energy.device_info(device_id, energy.last_reading(device_id)))
        _publish_live(device_id)


def check_stale() -> None:
    """Called every few seconds: a device that stopped sending (without a last will) goes offline."""
    for device_id, online in list(_online.items()):
        if online and not energy.device_info(device_id, energy.last_reading(device_id))["online"]:
            _online[device_id] = False
            hub.publish_threadsafe("alert", alerts.device_online_changed(device_id, False, int(time.time())))
            hub.publish_threadsafe("status", energy.device_info(device_id, energy.last_reading(device_id)))
            _publish_live(device_id)


def _on_connect(client, userdata, flags, reason_code, properties):
    log.info("MQTT connected to %s:%s (%s)", config.MQTT_HOST, config.MQTT_PORT, reason_code)
    client.subscribe("solaris/+/+")


def _on_message(client, userdata, msg):
    try:
        handle_message(msg.topic, msg.payload)
    except Exception:
        log.exception("error handling %s", msg.topic)


def start() -> None:
    global _client
    if not config.MQTT_ENABLED:
        log.info("MQTT disabled (MQTT_ENABLED=0)")
        return
    _client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="solaris-backend")
    _client.on_connect = _on_connect
    _client.on_message = _on_message
    _client.reconnect_delay_set(1, 10)
    _client.connect_async(config.MQTT_HOST, config.MQTT_PORT, keepalive=30)
    _client.loop_start()
    log.info("MQTT connecting to %s:%s ...", config.MQTT_HOST, config.MQTT_PORT)


def stop() -> None:
    if _client is not None:
        _client.loop_stop()
        _client.disconnect()
