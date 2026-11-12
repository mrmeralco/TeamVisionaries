"""Backtest the daily-kWh forecast: SARIMA vs weekday/weekend averages, on this DB's own history.

    python tools/backtest_forecast.py                       # default device, 14-day horizon, 30 cutoffs
    python tools/backtest_forecast.py --horizon 7 --cutoffs 45 --device sinag-001

For each cutoff day c, both methods forecast c .. c+horizon-1 using only the days before c, and the
forecast total is compared with the grid import that actually happened. Reports mean absolute error
(kWh and % of actual), bias, and for SARIMA how often the actual total fell inside its 16-84% range.
Read-only: nothing is written to the DB.
"""
import argparse
import statistics
import sys
from datetime import timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from app import config, energy  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--device", default=config.DEFAULT_SETTINGS["device_id"])
ap.add_argument("--horizon", type=int, default=14)
ap.add_argument("--cutoffs", type=int, default=30)
args = ap.parse_args()

last = energy.today() - timedelta(days=1)  # last finished day
cutoffs = [last - timedelta(days=args.horizon - 1 + i) for i in range(args.cutoffs)][::-1]
rows = {"sarima": [], "average": []}
inside = []
for c in cutoffs:
    days = [c + timedelta(days=i) for i in range(args.horizon)]
    actual = sum(energy.day_totals(args.device, x)["grid_import_kwh"] for x in days)
    if actual <= 0:
        continue
    for method in ("sarima", "average"):
        fc = energy.forecast_days(args.device, c, args.horizon, method=method)
        if method == "sarima" and fc["method"] != "sarima":
            break  # not enough history before this cutoff for SARIMA: skip it for both
        pred = sum(fc["kwh"])
        rows[fc["method"]].append((pred - actual, actual))
        if fc["totals"] is not None:
            import numpy as np
            lo, hi = np.percentile(fc["totals"], [16, 84])
            inside.append(lo <= actual <= hi)

n = len(rows["sarima"])
if not n:
    sys.exit(f"No cutoff had {energy.sarima.MIN_DAYS}+ days of history before it. Seed more: tools/seed_history.py --days 120")
print(f"device {args.device}: {n} cutoffs, {args.horizon}-day horizon, actual total ≈ "
      f"{statistics.mean(a for _, a in rows['sarima']):.1f} kWh")
for method, errs in rows.items():
    mae = statistics.mean(abs(e) for e, _ in errs)
    mape = statistics.mean(abs(e) / a for e, a in errs) * 100
    bias = statistics.mean(e for e, _ in errs)
    print(f"  {method:8s} MAE {mae:6.2f} kWh  ({mape:5.1f}%)   bias {bias:+6.2f} kWh")
print(f"  SARIMA 16-84% range held the actual total {sum(inside)}/{len(inside)} times (≈68% expected)")
