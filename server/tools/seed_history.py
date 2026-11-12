"""Seed weeks of fake history into SQLite so charts, bill and forecast have data.

    python tools/seed_history.py              # 45 days at 5-minute resolution (covers last month too)
    python tools/seed_history.py --days 21 --reset

Writes telemetry rows ending 5 minutes ago, plus a few outages with their alerts.
"""
import argparse
import math
import random
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from app import config, db  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--days", type=int, default=45)
ap.add_argument("--step", type=int, default=300, help="seconds between rows")
ap.add_argument("--device", default=config.DEFAULT_SETTINGS["device_id"])
ap.add_argument("--reset", action="store_true", help="delete existing data for the device first")
args = ap.parse_args()

random.seed(7)
c = db.conn()
if args.reset:
    for table in ("telemetry", "outages", "alerts"):
        col = "device_id"
        c.execute(f"DELETE FROM {table} WHERE {col}=?", (args.device,))

battery_wh = config.DEFAULT_SETTINGS["battery_kwh"] * 1000
now = int(time.time()) - 300
start = now - args.days * 86400
start -= start % args.step

# A handful of outages: (start offset seconds, duration seconds)
outages = sorted(random.sample(range(start + 86400, now - 86400, 3600), 5))
outages = [(o, random.choice([1800, 3600, 5400, 7200])) for o in outages]

soc = 60.0
cloud = 1.0
rows = []
day_kind = {}
for ts in range(start, now, args.step):
    lt = time.localtime(ts)  # server TZ; good enough for fake data
    h = lt.tm_hour + lt.tm_min / 60
    day = lt.tm_yday
    if day not in day_kind:
        day_kind[day] = random.choice([1.0, 1.0, 0.9, 0.7, 0.45])  # sunny .. rainy
    cloud = max(0.2, min(1.0, cloud + random.uniform(-0.08, 0.08)))
    pv = max(0.0, math.sin((h - 6) / 12 * math.pi)) * 4200 * day_kind[day] * cloud
    weekend = lt.tm_wday >= 5
    load = 300 + random.uniform(-60, 60)
    if 18 <= h < 23:
        load += 1300 + random.uniform(-200, 300)       # aircon + TV at night
    elif 7 <= h < 9:
        load += 600
    elif weekend and 10 <= h < 17:
        load += 800                                    # everyone home on weekends

    brownout = any(o <= ts < o + d for o, d in outages)
    floor = 5 if brownout else 20
    surplus = pv - load
    if surplus > 0:
        batt = -min(surplus, 3000) if soc < 100 else 0
    else:
        batt = min(-surplus, 3000) if soc > floor else 0
    if brownout:
        load = pv + batt
        grid = 0
    else:
        grid = load - pv - batt
    soc = min(100.0, max(0.0, soc - batt * args.step / 3600 / battery_wh * 100))
    rows.append((args.device, ts, round(pv), round(load), round(grid), round(soc), round(batt),
                 0 if brownout else 1, round(38 + pv / 500), 0))

with db._lock:
    c.execute("BEGIN")
    c.executemany("INSERT INTO telemetry (device_id, ts, pv_w, load_w, grid_w, batt_soc, batt_w, grid_on, inv_temp_c, fault_code) "
                  "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", rows)
    for o, d in outages:
        c.execute("INSERT INTO outages (device_id, start_ts, end_ts) VALUES (?, ?, ?)", (args.device, o, o + d))
        c.execute("INSERT INTO alerts (device_id, ts, type, severity, title, message, read) VALUES (?, ?, 'brownout', 'critical', 'Brownout', "
                  "'Nawalan ng kuryente mula sa grid. Battery at solar na ang gamit ng bahay mo.', 1)", (args.device, o))
        c.execute("INSERT INTO alerts (device_id, ts, type, severity, title, message, read) VALUES (?, ?, 'grid_restored', 'info', "
                  "'Bumalik na ang kuryente', ?, 1)", (args.device, o + d, f"Bumalik na ang grid pagkatapos ng {d // 60} minuto. Magcha-charge ulit ang battery."))
    c.execute("COMMIT")

print(f"seeded {len(rows)} rows ({args.days} days) and {len(outages)} outages for {args.device} into {config.DB_PATH}")
