"""SINAG_MOCK=1: serve docs/contracts/examples/*.json so the app can be built with no broker or DB.

/ws/live in mock mode pushes the example telemetry every 5 s with small random changes.
"""
import asyncio
import copy
import json
import random
import time

from . import config, hub


def load(name: str):
    return json.loads((config.EXAMPLES_DIR / f"{name}.json").read_text())


async def ws_loop() -> None:
    live = load("live")
    while True:
        await asyncio.sleep(5)
        m = copy.deepcopy(live)
        t = m["telemetry"]
        t["ts"] = m["device"]["last_seen_ts"] = int(time.time())
        t["pv_w"] = max(0, t["pv_w"] + random.randint(-150, 150))
        t["load_w"] = max(150, t["load_w"] + random.randint(-100, 100))
        t["batt_w"] = -(t["pv_w"] - t["load_w"])
        await hub.broadcast("telemetry", m)
