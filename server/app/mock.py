"""SOLARIS_MOCK=1: serve docs/contracts/examples/*.json so the app can be built with no broker or DB.

/ws/live in mock mode pushes the example telemetry every 5 s with small random changes.

Household setup (settings `setup`): PUT /api/settings {"setup": "meter_only"} switches the demo. Each example
then comes from `<name>_<setup>.json` when that file exists (e.g. live_meter_only.json), else `<name>.json`.

Settings saved in mock mode (setup, name, rate, ...) are kept in config.MOCK_SETTINGS_PATH, like the real server
keeps them in its DB: the app remembers it has been set up, so a server restart mustn't undo the answers.
"""
import asyncio
import copy
import json
import random
import time

from . import config, hub

PUSH_EVERY_S = 5.0
SETUPS = ("solar", "meter_only", "solar_and_meter")


def _read_saved() -> dict:
    try:
        saved = json.loads(config.MOCK_SETTINGS_PATH.read_text())
        return saved if isinstance(saved, dict) else {}
    except (OSError, ValueError):
        return {}   # none saved yet, or unreadable: start from the example


_saved: dict = _read_saved()   # settings changed through PUT /api/settings
_setup: str = _saved.get("setup") if _saved.get("setup") in SETUPS else "solar"   # the demo household


def save_settings(changes: dict) -> dict:
    """PUT /api/settings in mock mode: keep the changes (on disk too) and return the full settings."""
    global _setup
    _saved.update(changes)
    if changes.get("setup") in SETUPS:
        _setup = changes["setup"]
    try:
        config.MOCK_SETTINGS_PATH.write_text(json.dumps(_saved, indent=2))
    except OSError:
        pass   # read-only folder: still kept until the server stops
    return load("settings")


def set_setup(setup: str) -> None:
    save_settings({"setup": setup})


def reset() -> None:
    """Back to the example household (tests)."""
    global _setup
    _saved.clear()
    _setup = "solar"
    config.MOCK_SETTINGS_PATH.unlink(missing_ok=True)


def load(name: str):
    variant = config.EXAMPLES_DIR / f"{name}_{_setup}.json"
    path = variant if _setup != "solar" and variant.exists() else config.EXAMPLES_DIR / f"{name}.json"
    data = json.loads(path.read_text())
    return {**data, **_saved, "setup": _setup} if name == "settings" else data


async def ws_loop() -> None:
    while True:
        await asyncio.sleep(PUSH_EVERY_S)
        m = copy.deepcopy(load("live"))  # reloaded each time: follows a setup change
        m["device"]["last_seen_ts"] = int(time.time())
        t = m["telemetry"]
        if t is not None:
            t["ts"] = m["device"]["last_seen_ts"]
            t["pv_w"] = max(0, t["pv_w"] + random.randint(-150, 150))
            t["load_w"] = max(150, t["load_w"] + random.randint(-100, 100))
            t["batt_w"] = -(t["pv_w"] - t["load_w"])
        if m.get("meter"):
            mt = m["meter"]
            mt["ts"] = m["device"]["last_seen_ts"]
            mt["power_w"] = max(80, mt["power_w"] + random.randint(-120, 120)) if t is None else mt["power_w"]
        await hub.broadcast("telemetry", m)
