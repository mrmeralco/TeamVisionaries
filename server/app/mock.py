"""SOLARIS_MOCK=1: serve docs/contracts/examples/*.json so the app can be built with no broker or DB.

/ws/live in mock mode pushes the example telemetry every 5 s with small random changes.

Household setup (settings `setup`): PUT /api/settings {"setup": "meter_only"} switches the demo. Each example
then comes from `<name>_<setup>.json` when that file exists (e.g. live_meter_only.json), else `<name>.json`.
"""
import asyncio
import copy
import json
import random
import time

from . import config, hub

PUSH_EVERY_S = 5.0
_setup = "solar"   # the demo household; not persisted


def set_setup(setup: str) -> None:
    global _setup
    _setup = setup


def load(name: str):
    variant = config.EXAMPLES_DIR / f"{name}_{_setup}.json"
    path = variant if _setup != "solar" and variant.exists() else config.EXAMPLES_DIR / f"{name}.json"
    data = json.loads(path.read_text())
    return {**data, "setup": _setup} if name == "settings" else data


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
