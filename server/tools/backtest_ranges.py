"""Are the bill forecast's and the projection's ranges honest? Walk-forward backtest on synthetic years.

    python tools/backtest_ranges.py              # 4 households, seed 23, ~5 min (SARIMA fits in parallel)
    python tools/backtest_ranges.py --seed 7 --scenarios base,noac

The real DB has weeks of history, not a year, so this generates a year of 15-minute telemetry per household
into throwaway DBs and replays it: on each cutoff day the forecast only sees the days before it, and its
low-high range is checked against what the month really used. Ranges are meant as about +-1 standard
deviation, so the actual month should land inside roughly 2 times out of 3 (≈68%) at every point in the
month and every month ahead. Much lower = the app sounds surer than it is; much higher = the range is
wider than it needs to be.

The synthetic homes do NOT use the model's own season tables: solar follows approximate Manila monthly
irradiance with a Markov chain of sunny / cloudy / rainy days (wetter Jun-Oct), aircon follows a monthly
temperature curve plus hot-day noise. Households:
  base    typical home: 5 kWp, 10 kWh battery, evening + overnight aircon that grows with the heat
  shift   base + a new aircon from day 200 (+0.9 kW evening load): a change the past can't show
  messy   base + a 7-day vacation, 3 offline days, frequent brownouts
  noac    no aircon: grid use is close to zero most months
A pass here is evidence on plausible data, not proof for a real home: rerun on real history once there is a year.
Read-only for the real DB: everything goes to a temp directory.
"""
import argparse
import calendar
import json
import math
import os
import random
import sqlite3
import statistics
import subprocess
import sys
import tempfile
from datetime import date, datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

SERVER = Path(__file__).resolve().parent.parent
END = date(2026, 11, 12)     # first day NOT in the synthetic data
DAYS = 400
DEVICE = "solaris-001"
SCENARIOS = ("base", "shift", "messy", "noac")
CURRENT_DAYS = (1, 4, 8, 12, 15, 19, 22, 26)    # cutoffs inside each month for this month's bill

GHI = (4.6, 5.4, 6.2, 6.6, 6.0, 5.0, 4.5, 4.3, 4.4, 4.5, 4.3, 4.0)          # kWh/m2/day, approx. Manila
TEMP = (26.0, 26.5, 27.8, 29.3, 29.8, 28.6, 27.9, 27.6, 27.5, 27.3, 26.9, 26.3)  # monthly mean °C
P_RAIN = (0.10, 0.08, 0.07, 0.08, 0.18, 0.40, 0.55, 0.60, 0.55, 0.45, 0.30, 0.18)


# ------------------------------------------------------------- synthetic year --
def generate(path: Path, scenario: str, seed: int) -> None:
    sys.path.insert(0, str(SERVER))
    from app.db import SCHEMA

    tz = ZoneInfo("Asia/Manila")
    rng = random.Random(seed)
    start = datetime(END.year, END.month, END.day, tzinfo=tz) - timedelta(days=DAYS)
    step, cap = 900, 10_000.0
    soc, wx, out_left = 60.0, "sun", 0
    vacation = set(range(250, 257)) if scenario == "messy" else set()
    offline = {120, 121, 300} if scenario == "messy" else set()
    outage_p = 1 / 600 if scenario == "messy" else 1 / 1500    # chance per 15-minute slot
    rows = []
    for day in range(DAYS):
        d0 = start + timedelta(days=day)
        m = d0.month - 1
        if wx == "rain":
            wx = "rain" if rng.random() < 0.6 else rng.choice(["cloud", "sun"])
        else:
            wx = "rain" if rng.random() < P_RAIN[m] else ("cloud" if rng.random() < 0.35 else "sun")
        sky = {"sun": rng.uniform(0.9, 1.05), "cloud": rng.uniform(0.55, 0.8), "rain": rng.uniform(0.2, 0.45)}[wx]
        peak = 5000 * 0.8 * sky * GHI[m] / 5.0
        heat = TEMP[m] + rng.gauss(0, 0.8) - (0.6 if wx == "rain" else 0)
        ac_kw = 0.0 if scenario == "noac" else max(0.0, (heat - 26.0) * 0.45)
        if scenario == "shift" and day >= 200:
            ac_kw += 0.9
        weekend = d0.weekday() >= 5
        if day in offline:
            continue
        for k in range(96):
            ts = int(d0.timestamp()) + k * step
            h = k / 4
            pv = max(0.0, math.sin((h - 6) / 12 * math.pi)) * peak * rng.uniform(0.85, 1.05)
            load = 280 + rng.uniform(-50, 50)
            if day in vacation:
                load = 150 + rng.uniform(-20, 20)
            elif 18 <= h < 23:
                load += 500 + ac_kw * 1000 * rng.uniform(0.8, 1.2)
            elif h >= 23 or h < 5:
                load += ac_kw * 600 * rng.uniform(0.7, 1.1)
            elif 6 <= h < 8:
                load += 600
            elif weekend and 10 <= h < 17:
                load += 400 + ac_kw * 700
            if out_left == 0 and rng.random() < outage_p:
                out_left = rng.choice([2, 4, 6, 8])
            brownout = out_left > 0
            out_left = max(0, out_left - 1)
            floor = 5 if brownout else 20
            surplus = pv - load
            if surplus > 0:
                batt = -min(surplus, 3000) if soc < 100 else 0
            else:
                batt = min(-surplus, 3000) if soc > floor else 0
            if brownout:
                load, grid = pv + batt, 0
            else:
                grid = load - pv - batt
            soc = min(100.0, max(0.0, soc - batt * step / 3600 / cap * 100))
            rows.append((DEVICE, ts, round(pv), round(load), round(grid), round(soc), round(batt),
                         0 if brownout else 1, 40, 0))
    c = sqlite3.connect(path)
    c.executescript(SCHEMA)
    c.executemany("INSERT INTO telemetry (device_id, ts, pv_w, load_w, grid_w, batt_soc, batt_w, grid_on, inv_temp_c, "
                  "fault_code) VALUES (?,?,?,?,?,?,?,?,?,?)", rows)
    c.commit()
    c.close()


# ------------------------------------------------------------- walk-forward --
def worker(scenario: str) -> None:
    """Runs in a subprocess with SOLARIS_DB pointing at the synthetic year. Prints one JSON line per check."""
    sys.path.insert(0, str(SERVER))
    from app import config, energy, projection

    settings = {**config.DEFAULT_SETTINGS, "device_id": DEVICE}
    today = [END]
    energy.today = lambda: today[0]
    kwh = lambda d: energy.day_totals(DEVICE, d)["grid_import_kwh"]  # noqa: E731

    def month_kwh(y: int, m: int) -> float:
        return sum(kwh(date(y, m, i)) for i in range(1, calendar.monthrange(y, m)[1] + 1))

    def months_back(k: int) -> tuple[int, int]:
        i = END.year * 12 + END.month - 1 - k
        return i // 12, i % 12 + 1

    for back in range(10, 0, -1):                 # this month's bill, at several days into the month
        y, m = months_back(back)
        actual = month_kwh(y, m)
        for day in CURRENT_DAYS:
            d = today[0] = date(y, m, day)
            done = sum(kwh(date(y, m, i)) for i in range(1, day))
            # today's use counts as not metered yet (0), so no part of the day being forecast leaks in
            fc = energy.forecast_days(DEVICE, d, calendar.monthrange(y, m)[1] - day + 1, 0.0, fallback_level=1.0)
            mid, lo, hi = energy.month_range(done, fc)
            print(json.dumps({"kind": "current", "sc": scenario, "day": day, "actual": actual,
                              "fc": mid, "lo": lo, "hi": hi}), flush=True)

    for back in range(12, 3, -1):                 # projections made on the 12th, for the next 1-3 months
        y, m = months_back(back)
        today[0] = date(y, m, 12)
        projection._cache.clear()
        p = projection._project(DEVICE, settings)
        for pm in p["months"][1:] if p["enough_data"] else []:
            py, pmn = map(int, pm["month"].split("-"))
            if date(py, pmn, calendar.monthrange(py, pmn)[1]) >= END:
                continue
            print(json.dumps({"kind": "proj", "sc": scenario, "ahead": pm["months_ahead"], "actual": month_kwh(py, pmn),
                              "fc": pm["grid_kwh"], "lo": pm["low_kwh"], "hi": pm["high_kwh"]}), flush=True)


# ------------------------------------------------------------------- report --
def report(rows: list[dict], scenarios: list[str]) -> None:
    def line(label: str, rr: list[dict]) -> str:
        cells = []
        for sc in [*scenarios, None]:
            r = [x for x in rr if sc is None or x["sc"] == sc]
            if not r:
                continue
            inside = statistics.mean(x["lo"] <= x["actual"] <= x["hi"] for x in r) * 100
            err = statistics.mean(abs(x["fc"] - x["actual"]) for x in r)
            cells.append(f"{(sc or 'ALL'):>5} {inside:3.0f}% in, ±{err:5.1f} kWh")
        return f"  {label:<14}" + " | ".join(cells)

    print("Actual month inside the range (target ≈68%) and mean absolute error of the middle number")
    print("This month's bill, forecast on day:")
    for days in ((1, 4), (8, 12), (15, 19), (22, 26)):
        print(line(f"{days[0]}-{days[1]}", [x for x in rows if x["kind"] == "current" and x["day"] in days]))
    print("Projection, months ahead:")
    for k in (1, 2, 3):
        print(line(f"+{k}", [x for x in rows if x["kind"] == "proj" and x["ahead"] == k]))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=23)
    ap.add_argument("--scenarios", default=",".join(SCENARIOS))
    ap.add_argument("--worker", help=argparse.SUPPRESS)
    args = ap.parse_args()
    if args.worker:
        return worker(args.worker)

    scenarios = args.scenarios.split(",")
    tmp = Path(tempfile.mkdtemp(prefix="solaris-backtest-"))
    procs = []
    for sc in scenarios:
        db = tmp / f"{sc}.db"
        generate(db, sc, args.seed)
        env = {**os.environ, "SOLARIS_DB": str(db), "MQTT_ENABLED": "0", "WEATHER_ENABLED": "0", "LLM_ENABLED": "0",
               "SOLARIS_MOCK": "0", "AI_LOG": str(tmp / "ai.jsonl")}
        procs.append(subprocess.Popen([sys.executable, __file__, "--worker", sc], env=env, stdout=subprocess.PIPE,
                                      text=True))
    print(f"seed {args.seed}: {len(scenarios)} synthetic years in {tmp}, replaying ...", flush=True)
    rows = []
    for p in procs:
        out, _ = p.communicate()
        if p.returncode:
            sys.exit(f"worker failed (exit {p.returncode})")
        rows += [json.loads(x) for x in out.splitlines() if x.startswith("{")]
    report(rows, scenarios)


if __name__ == "__main__":
    main()
