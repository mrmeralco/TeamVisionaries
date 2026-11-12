"""SQLite storage: telemetry, meter readings, device status, alerts, outages, settings.

One connection shared across threads (the MQTT thread writes, FastAPI reads), guarded by a lock.
"""
import json
import sqlite3
import threading
import time
from typing import Any

from . import config

_lock = threading.RLock()
_conn: sqlite3.Connection | None = None

SCHEMA = """
CREATE TABLE IF NOT EXISTS telemetry (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  device_id TEXT NOT NULL, ts INTEGER NOT NULL,
  pv_w INTEGER, load_w INTEGER, grid_w INTEGER, batt_soc INTEGER, batt_w INTEGER,
  grid_on INTEGER, inv_temp_c INTEGER, fault_code INTEGER
);
CREATE INDEX IF NOT EXISTS idx_telemetry_ts ON telemetry(device_id, ts);

CREATE TABLE IF NOT EXISTS meter (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  device_id TEXT NOT NULL, ts INTEGER NOT NULL, meter_type TEXT, data TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_meter_ts ON meter(device_id, ts);

CREATE TABLE IF NOT EXISTS device_status (
  device_id TEXT PRIMARY KEY, online INTEGER, rssi INTEGER, fw TEXT, updated_ts INTEGER
);

CREATE TABLE IF NOT EXISTS alerts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  device_id TEXT, ts INTEGER NOT NULL, type TEXT NOT NULL, severity TEXT NOT NULL,
  title TEXT NOT NULL, message TEXT NOT NULL, read INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS outages (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  device_id TEXT, start_ts INTEGER NOT NULL, end_ts INTEGER
);

CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
"""

TELEMETRY_FIELDS = ("pv_w", "load_w", "grid_w", "batt_soc", "batt_w", "grid_on", "inv_temp_c", "fault_code")


def conn() -> sqlite3.Connection:
    global _conn
    if _conn is None:
        _conn = sqlite3.connect(config.DB_PATH, check_same_thread=False, isolation_level=None)
        _conn.row_factory = sqlite3.Row
        _conn.execute("PRAGMA journal_mode=WAL")
        _conn.executescript(SCHEMA)
    return _conn


def query(sql: str, args: tuple = ()) -> list[dict]:
    with _lock:
        return [dict(r) for r in conn().execute(sql, args).fetchall()]


def one(sql: str, args: tuple = ()) -> dict | None:
    rows = query(sql, args)
    return rows[0] if rows else None


def execute(sql: str, args: tuple = ()) -> int:
    with _lock:
        return conn().execute(sql, args).lastrowid


# ---------------------------------------------------------------- telemetry --
def insert_telemetry(device_id: str, t: dict) -> None:
    execute(
        f"INSERT INTO telemetry (device_id, ts, {', '.join(TELEMETRY_FIELDS)}) VALUES (?, ?, {', '.join('?' * len(TELEMETRY_FIELDS))})",
        (device_id, t["ts"], *(int(t[f]) for f in TELEMETRY_FIELDS)),
    )


def row_to_telemetry(r: dict | None) -> dict | None:
    if r is None:
        return None
    out = {"ts": r["ts"], **{f: r[f] for f in TELEMETRY_FIELDS}}
    out["grid_on"] = bool(out["grid_on"])
    return out


def latest_telemetry(device_id: str) -> dict | None:
    return row_to_telemetry(one("SELECT * FROM telemetry WHERE device_id=? ORDER BY ts DESC LIMIT 1", (device_id,)))


def telemetry_between(device_id: str, start_ts: int, end_ts: int) -> list[dict]:
    return query(
        "SELECT ts, pv_w, load_w, grid_w, batt_soc, batt_w, grid_on FROM telemetry "
        "WHERE device_id=? AND ts>=? AND ts<? ORDER BY ts",
        (device_id, start_ts, end_ts),
    )


def insert_meter(device_id: str, ts: int, data: dict) -> None:
    execute("INSERT INTO meter (device_id, ts, meter_type, data) VALUES (?, ?, ?, ?)",
            (device_id, ts, data.get("meter_type"), json.dumps(data)))


def latest_meter(device_id: str) -> dict | None:
    """The newest Contract B meter payload, with the stored ts."""
    r = one("SELECT ts, data FROM meter WHERE device_id=? ORDER BY ts DESC LIMIT 1", (device_id,))
    return {**json.loads(r["data"]), "ts": r["ts"]} if r else None


def meter_between(device_id: str, start_ts: int, end_ts: int, *fields: str) -> list[dict]:
    """Meter rows in [start, end), ts + the requested payload fields (SQLite JSON1, no parsing in Python)."""
    cols = "".join(f", json_extract(data, '$.{f}') AS {f}" for f in fields)
    return query(f"SELECT ts{cols} FROM meter WHERE device_id=? AND ts>=? AND ts<? ORDER BY ts",
                 (device_id, start_ts, end_ts))


def has_meter(device_id: str) -> bool:
    return one("SELECT 1 AS x FROM meter WHERE device_id=? LIMIT 1", (device_id,)) is not None


# ------------------------------------------------------------------ status --
def set_status(device_id: str, online: bool, rssi: int | None = None, fw: str | None = None) -> None:
    execute(
        "INSERT INTO device_status (device_id, online, rssi, fw, updated_ts) VALUES (?, ?, ?, ?, ?) "
        "ON CONFLICT(device_id) DO UPDATE SET online=excluded.online, "
        "rssi=COALESCE(excluded.rssi, rssi), fw=COALESCE(excluded.fw, fw), updated_ts=excluded.updated_ts",
        (device_id, int(online), rssi, fw, int(time.time())),
    )


def get_status(device_id: str) -> dict | None:
    return one("SELECT * FROM device_status WHERE device_id=?", (device_id,))


# ------------------------------------------------------------------ alerts --
def insert_alert(device_id: str, ts: int, type_: str, severity: str, title: str, message: str) -> dict:
    aid = execute(
        "INSERT INTO alerts (device_id, ts, type, severity, title, message) VALUES (?, ?, ?, ?, ?, ?)",
        (device_id, ts, type_, severity, title, message),
    )
    return alert_by_id(aid)


def alert_by_id(aid: int) -> dict | None:
    r = one("SELECT id, ts, type, severity, title, message, read FROM alerts WHERE id=?", (aid,))
    if r:
        r["read"] = bool(r["read"])
    return r


def list_alerts(unread_only: bool = False, limit: int = 100) -> list[dict]:
    where = "WHERE read=0" if unread_only else ""
    rows = query(f"SELECT id, ts, type, severity, title, message, read FROM alerts {where} ORDER BY ts DESC, id DESC LIMIT ?", (limit,))
    for r in rows:
        r["read"] = bool(r["read"])
    return rows


def unread_count() -> int:
    return one("SELECT COUNT(*) AS n FROM alerts WHERE read=0")["n"]


# ----------------------------------------------------------------- outages --
def open_outage(device_id: str) -> dict | None:
    return one("SELECT * FROM outages WHERE device_id=? AND end_ts IS NULL ORDER BY start_ts DESC LIMIT 1", (device_id,))


def last_outage(device_id: str) -> dict | None:
    return one("SELECT * FROM outages WHERE device_id=? ORDER BY start_ts DESC LIMIT 1", (device_id,))


# ---------------------------------------------------------------- settings --
def get_settings() -> dict[str, Any]:
    stored = {r["key"]: json.loads(r["value"]) for r in query("SELECT key, value FROM settings")}
    settings = {k: stored.get(k, v) for k, v in config.DEFAULT_SETTINGS.items()}
    # Legacy manually entered rates are not verified publications. Until the first
    # successful fetch, calculations use the documented estimate and Settings says so.
    record = stored.get("meralco_rate")
    if config.MERALCO_RATE_ENABLED and not (isinstance(record, dict) and record.get("fetched_at")):
        settings["rate_php_per_kwh"] = config.DEFAULT_SETTINGS["rate_php_per_kwh"]
    return settings


def put_settings(changes: dict[str, Any]) -> dict[str, Any]:
    for k, v in changes.items():
        if k in config.DEFAULT_SETTINGS and v is not None:
            execute("INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)", (k, json.dumps(v)))
    return get_settings()


def get_kv(key: str) -> Any:
    r = one("SELECT value FROM settings WHERE key=?", (key,))
    return json.loads(r["value"]) if r else None


def put_kv(key: str, value: Any) -> None:
    execute("INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)", (key, json.dumps(value)))
