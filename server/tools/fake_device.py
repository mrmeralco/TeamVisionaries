"""Fake Sinag device: publishes Contract B telemetry every 5 s, so the backend works with no hardware.

    python tools/fake_device.py                    # broker on localhost
    python tools/fake_device.py --host 192.168.43.100 --speed 60

Type a key + Enter while it runs:  b = toggle brownout   f = toggle fault 21   s/S = sun -/+   l/L = load -/+   q = quit
"""
import argparse
import json
import math
import sys
import threading
import time
from datetime import datetime

import paho.mqtt.client as mqtt

ap = argparse.ArgumentParser()
ap.add_argument("--host", default="localhost")
ap.add_argument("--port", type=int, default=1883)
ap.add_argument("--device", default="sinag-001")
ap.add_argument("--interval", type=float, default=5.0)
ap.add_argument("--speed", type=float, default=1.0, help="simulated seconds per real second (battery moves faster)")
ap.add_argument("--battery-kwh", type=float, default=10.0)
args = ap.parse_args()

s = {"brownout": False, "fault": False, "sun": 1.0, "load": 1.0, "soc": 70.0, "temp": 40.0}
base = f"sinag/{args.device}"

c = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=f"{args.device}-fake")
c.will_set(f"{base}/status", json.dumps({"online": False}), qos=1, retain=True)
c.connect(args.host, args.port, keepalive=30)
c.loop_start()
c.publish(f"{base}/status", json.dumps({"online": True, "rssi": -55, "fw": "fake-0.1"}), qos=1, retain=True)


def keys():
    for line in sys.stdin:
        k = line.strip()
        if k == "b": s["brownout"] = not s["brownout"]
        elif k == "f": s["fault"] = not s["fault"]
        elif k == "s": s["sun"] = max(0, s["sun"] - 0.25)
        elif k == "S": s["sun"] += 0.25
        elif k == "l": s["load"] = max(0.1, s["load"] - 0.25)
        elif k == "L": s["load"] += 0.25
        elif k == "q": s["quit"] = True; return
        print(f"  -> brownout={s['brownout']} fault={s['fault']} sun x{s['sun']} load x{s['load']}")


threading.Thread(target=keys, daemon=True).start()
print(f"publishing to {args.host}:{args.port} {base}/telemetry every {args.interval}s. Keys: b f s S l L q")

while not s.get("quit"):
    h = datetime.now().hour + datetime.now().minute / 60
    pv = max(0.0, math.sin((h - 6) / 12 * math.pi)) * 4200 * s["sun"]
    load = (350 + (1400 if 18 <= h < 23 else 500 if 7 <= h < 9 else 0)) * s["load"]
    surplus = pv - load  # + = extra solar
    floor = 5 if s["brownout"] else 20
    if surplus > 0:
        batt = -min(surplus, 3000) if s["soc"] < 100 else 0
    else:
        batt = min(-surplus, 3000) if s["soc"] > floor else 0
    grid = 0 if s["brownout"] else load - pv - batt
    if s["brownout"]:
        load = pv + batt  # can't draw more than solar + battery
    s["soc"] = min(100.0, max(0.0, s["soc"] - batt * args.interval * args.speed / 3600 / (args.battery_kwh * 1000) * 100))
    s["temp"] += ((78 if s["fault"] else 38 + pv / 500) - s["temp"]) * 0.2
    msg = {
        "ts": int(time.time()), "pv_w": round(pv), "load_w": round(load), "grid_w": round(grid),
        "batt_soc": round(s["soc"]), "batt_w": round(batt), "grid_on": not s["brownout"],
        "inv_temp_c": round(s["temp"]), "fault_code": 21 if s["fault"] else 0,
    }
    c.publish(f"{base}/telemetry", json.dumps(msg))
    print(json.dumps(msg))
    time.sleep(args.interval)

c.publish(f"{base}/status", json.dumps({"online": False}), qos=1, retain=True)
c.loop_stop()
