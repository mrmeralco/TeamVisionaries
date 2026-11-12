"""Seed weeks of fake history into SQLite so charts, bill and forecast have data.

    python tools/seed_history.py              # 45 days at 5-minute resolution (covers last month too)
    python tools/seed_history.py --days 21 --reset
    python tools/seed_history.py --reset --new-load-days 5     # + a "new aircon" (1.1 kW, 9PM-2AM) for 5 days

Writes telemetry rows ending 5 minutes ago, plus a few outages with their alerts.
The --new-load-* options add a load that starts N days ago, for demoing /api/household's new-appliance check.

    python tools/seed_history.py --meter                           # + the utility meter of this solar home
    python tools/seed_history.py --meter-only --device meter-001   # a home with a smart meter and no solar

--meter also writes Contract B meter readings (power = what the grid supplies); --meter-only writes ONLY
meter readings, for a household without solar or battery (power = home use).
"""
import argparse
import json
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
ap.add_argument("--new-load-days", type=int, default=0, help="add a new appliance this many days ago (0 = none)")
ap.add_argument("--new-load-w", type=int, default=1100, help="its watts")
ap.add_argument("--new-load-hours", default="21-2", help="its hours, START-END local (wraps midnight); 0-24 = always on")
ap.add_argument("--meter", action="store_true", help="also write meter readings (solar + meter home)")
ap.add_argument("--meter-only", action="store_true", help="only meter readings: a home without solar")
ap.add_argument("--meter-type", default="sdm120", choices=["sdm120", "ansi-c12"])
args = ap.parse_args()

random.seed(7)
c = db.conn()
if args.reset:
    for table in ("telemetry", "meter", "outages", "alerts"):
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
meter_rows = []
mrng = random.Random(11)  # meter noise has its own generator: --meter must not change the telemetry
register = 1520.0 + mrng.uniform(0, 400)  # kWh on the meter's import register at the start
exported = 12.0
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
    if args.new_load_days and ts >= now - args.new_load_days * 86400:
        a, b = (int(x) for x in args.new_load_hours.split("-"))
        if (a <= h < b) if a < b else (h >= a or h < b):
            load += args.new_load_w                    # the "new appliance"

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
    if not args.meter_only:
        rows.append((args.device, ts, round(pv), round(load), round(grid), round(soc), round(batt),
                     0 if brownout else 1, round(38 + pv / 500), 0))
    if args.meter or args.meter_only:
        # The meter sees the grid side. A home without solar draws all its load from the grid (and runs more
        # air-con in the evening: no battery, no sun-cooled afternoon).
        power = 0.0 if brownout else (load * (1.15 if 18 <= h < 23 else 1.0) if args.meter_only else grid)
        evening = 18 <= h < 22
        volts = 0.0 if brownout else 229 + mrng.uniform(-3, 3) - (14 if evening and mrng.random() < 0.15 else 0)
        pf = 0.0 if brownout else round(min(0.99, (0.84 if evening else 0.94) + mrng.uniform(-0.04, 0.04)), 2)
        register += max(power, 0) * args.step / 3.6e6
        exported += max(-power, 0) * args.step / 3.6e6
        amps = abs(power) / volts / max(pf, 0.1) if volts else 0.0
        meter_rows.append((args.device, ts, args.meter_type, json.dumps({
            "ts": ts, "meter_type": args.meter_type, "voltage_v": round(volts, 1), "current_a": round(amps, 2),
            "power_w": round(power), "apparent_va": round(volts * amps),
            "reactive_var": round(volts * amps * math.sqrt(max(0.0, 1 - pf * pf))),
            "pf": pf, "freq_hz": 0.0 if brownout else round(60 + mrng.uniform(-0.03, 0.03), 2),
            "import_kwh": round(register, 2), "export_kwh": round(exported, 2), "grid_on": not brownout})))

with db._lock:
    c.execute("BEGIN")
    c.executemany("INSERT INTO telemetry (device_id, ts, pv_w, load_w, grid_w, batt_soc, batt_w, grid_on, inv_temp_c, fault_code) "
                  "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", rows)
    c.executemany("INSERT INTO meter (device_id, ts, meter_type, data) VALUES (?, ?, ?, ?)", meter_rows)
    for o, d in outages:
        c.execute("INSERT INTO outages (device_id, start_ts, end_ts) VALUES (?, ?, ?)", (args.device, o, o + d))
        c.execute("INSERT INTO alerts (device_id, ts, type, severity, title, message, read) VALUES (?, ?, 'brownout', 'critical', 'Brownout', "
                  "?, 1)", (args.device, o, "Nawalan ng kuryente mula sa grid. " + (
                      "Hugutin muna ang malalaking appliance." if args.meter_only else "Battery at solar na ang gamit ng bahay mo.")))
        c.execute("INSERT INTO alerts (device_id, ts, type, severity, title, message, read) VALUES (?, ?, 'grid_restored', 'info', "
                  "'Bumalik na ang kuryente', ?, 1)", (args.device, o + d, f"Bumalik na ang grid pagkatapos ng {d // 60} minuto. " + (
                      "Isaksak ulit ang mga appliance nang paisa-isa." if args.meter_only else "Magcha-charge ulit ang battery.")))
    c.execute("COMMIT")

print(f"seeded {len(rows)} telemetry + {len(meter_rows)} meter rows ({args.days} days) and {len(outages)} outages "
      f"for {args.device} into {config.DB_PATH}")
