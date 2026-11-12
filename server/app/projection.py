"""Bill projection for the next months: this month's forecast + up to MAX_MONTHS calendar months after it.

Only THIS month is a forecast (energy.bill: SARIMA on the last 8 weeks + the days already metered). Months
after it are PROJECTIONS: "if the household keeps using electricity the way it did the last few weeks",
adjusted for the season. They are less reliable and the range widens every month, because weather, new
appliances, and Meralco's monthly rate change in ways the past can't show. Beyond MAX_MONTHS the range
is too wide to be useful, so nothing is projected (Mira explains why: ai/facts.py "projection.limits").

How a month is projected (a solar home's grid use depends on BOTH how much it uses and how much sun):
  1. This home's typical hour-by-hour day (outlook.profiles: last 28 days of load, 14 days of solar).
  2. Load scaled by LOAD_SEASON (air-con: Apr-May high, Dec-Feb low) and solar by SOLAR_SEASON (dry
     season Mar-May sunny, rainy season Jul-Oct and short December days less), relative to today.
  3. Three weeks simulated hour by hour with the battery (outlook.simulate): the last week's grid use per
     day is the month's steady state.
  4. Anchored to reality: the same simulation for today is compared with the grid use actually metered
     over the last 14 days, and every month is corrected by that ratio (bounded).
  5. Priced with Meralco's tiers (tariff.cost) at TODAY's rate: the rate changes monthly, which is one
     reason projections are rough.
Range: +-(spread + RANGE_GROWTH x months ahead), spread = how much this home's weekly grid use varies.

LOAD_SEASON and SOLAR_SEASON are rough Metro Manila priors (monthly / yearly average). SOLAR_SEASON follows
typical monthly global horizontal irradiance for Manila (approx. 4.1-6.6 kWh/m2/day, NASA POWER-style
climatology). Replace both with the household's own pattern once there is a year of history.
"""
import calendar
import statistics
import time
from datetime import date, timedelta

from . import config, energy, outlook, tariff

MAX_MONTHS = 3                 # projected months after the current one
MIN_DAYS = 14                  # days of history needed before projecting
RANGE_GROWTH = 0.10            # extra +-share of the range for each month further out
RANGE_MAX = 0.6
ANCHOR_BOUNDS = (0.5, 2.0)     # how far the reality correction may move the simulation

LOAD_SEASON = (0.91, 0.92, 0.99, 1.13, 1.17, 1.08, 1.01, 0.99, 0.98, 0.96, 0.94, 0.92)
SOLAR_SEASON = (0.93, 1.09, 1.24, 1.32, 1.21, 1.00, 0.88, 0.84, 0.88, 0.90, 0.87, 0.82)

MONTHS_TL = ("Enero", "Pebrero", "Marso", "Abril", "Mayo", "Hunyo", "Hulyo", "Agosto", "Setyembre",
             "Oktubre", "Nobyembre", "Disyembre")

_cache: dict[tuple, dict] = {}


def _season(table: tuple, d: date) -> float:
    """Monthly value interpolated between mid-month points (same convention as tariff.season_factor)."""
    n = calendar.monthrange(d.year, d.month)[1]
    t = (d.month - 1) + (d.day - 0.5) / n - 0.5
    i = int(t // 1)
    frac = t - i
    return table[i % 12] * (1 - frac) + table[(i + 1) % 12] * frac


def _month_add(d: date, k: int) -> date:
    m = d.month - 1 + k
    return date(d.year + m // 12, m % 12 + 1, 1)


def month_label(d: date) -> str:
    return f"{MONTHS_TL[d.month - 1]} {d.year}"


def _daily_grid(prof: dict, load_x: float, pv_x: float, settings: dict) -> dict:
    """Steady-state kWh per day for a typical week with load and solar scaled: (grid, load, pv)."""
    fallback = sum(prof["load"].values()) / max(1, len(prof["load"]))
    slots, start = [], 0
    for day in range(21):
        weekend = day % 7 >= 5
        for h in range(24):
            slots.append((start + (day * 24 + h) * 3600, 1.0, prof["pv"].get(h, 0.0) * pv_x,
                          outlook._load_at(prof, weekend, h, fallback) * load_x))
    sim = outlook.simulate(50.0, settings["battery_kwh"], config.BATT_RESERVE_PCT, slots)
    last = slice(14 * 24, 21 * 24)
    return {"grid": sum(sim["short_kwh"][last]) / 7, "load": sum(s[3] for s in slots[last]) / 7,
            "pv": sum(s[2] for s in slots[last]) / 7}


def project(device_id: str, settings: dict) -> dict:
    key = (device_id, energy.today(), settings["battery_kwh"], settings["rate_php_per_kwh"])
    if key not in _cache:
        if len(_cache) > 32:
            _cache.clear()
        _cache[key] = _project(device_id, settings)
    return _cache[key]


def _project(device_id: str, settings: dict) -> dict:
    today = energy.today()
    rate = settings["rate_php_per_kwh"]
    base = {"generated_ts": int(time.time()), "rate_php_per_kwh": rate, "max_months": MAX_MONTHS}
    bill = energy.bill(device_id, settings)
    current = {
        "month": today.strftime("%Y-%m"), "label": month_label(today), "months_ahead": 0, "kind": "forecast",
        "grid_kwh": bill["forecast_kwh"], "low_kwh": None, "high_kwh": None,
        "bill_php": bill["forecast_php"], "low_php": bill["forecast_low_php"], "high_php": bill["forecast_high_php"],
        "load_kwh": None, "solar_kwh": None, "range_pct": None,
    }

    hist = [(d, k) for d, k in energy.daily_history(device_id, today, 28) if k is not None]
    prof = outlook.profiles(device_id)
    if len(hist) < MIN_DAYS or len(prof["pv"]) < 24 or len(prof["load"]) < 24:
        return {**base, "enough_data": False, "basis_days": len(hist), "months": [current]}

    # Reality anchor: simulated grid use for today vs. metered (season factors divided back out by
    # daily_history, so put today's grid-season back in).
    now_sim = _daily_grid(prof, 1.0, 1.0, settings)
    recent = [k * tariff.season_factor(d) for d, k in hist[-14:]]
    actual = statistics.mean(recent)
    anchor = actual / now_sim["grid"] if now_sim["grid"] > 0.05 else 1.0
    anchor = min(max(anchor, ANCHOR_BOUNDS[0]), ANCHOR_BOUNDS[1])

    # How much this home's weekly grid use varies: the floor of every range.
    weeks = [sum(k for _, k in hist[j - 7:j]) for j in range(len(hist), 6, -7)][:4]   # newest full weeks
    spread = statistics.pstdev(weeks) / statistics.mean(weeks) if len(weeks) >= 2 and statistics.mean(weeks) > 0 else 0.15
    spread = max(0.10, min(spread, 0.25))

    months = [current]
    for k in range(1, MAX_MONTHS + 1):
        m = _month_add(today, k)
        mid = date(m.year, m.month, 15)
        n = calendar.monthrange(m.year, m.month)[1]
        load_x = _season(LOAD_SEASON, mid) / _season(LOAD_SEASON, today)
        pv_x = _season(SOLAR_SEASON, mid) / _season(SOLAR_SEASON, today)
        day = _daily_grid(prof, load_x, pv_x, settings)
        kwh = day["grid"] * anchor * n
        w = min(RANGE_MAX, spread + RANGE_GROWTH * k)
        lo_kwh, hi_kwh = kwh * (1 - w), kwh * (1 + w)
        months.append({
            "month": m.strftime("%Y-%m"), "label": month_label(m), "months_ahead": k, "kind": "projection",
            "grid_kwh": round(kwh, 1), "low_kwh": round(lo_kwh, 1), "high_kwh": round(hi_kwh, 1),
            "bill_php": round(tariff.cost(kwh, rate), 2),
            "low_php": round(tariff.cost(lo_kwh, rate), 2), "high_php": round(tariff.cost(hi_kwh, rate), 2),
            "load_kwh": round(day["load"] * n, 1), "solar_kwh": round(day["pv"] * n, 1),
            "range_pct": round(w * 100),
        })
    return {**base, "enough_data": True, "basis_days": len(hist), "months": months}
