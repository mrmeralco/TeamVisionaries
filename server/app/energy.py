"""Energy math: live status, kWh series, bill + forecast (tiered, seasonal), brownout runtime.

Power samples (W) are integrated over time: each sample counts until the next one, capped at
MAX_GAP_S so a gap in the data (device off) doesn't count as hours of usage.

Two sources of samples (settings `setup`, see config.SETUPS):
  inverter  Contract B telemetry: solar, home use, grid, battery.
  meter     Contract B meter readings (smart or utility meter): only the grid, so pv = battery = 0 and
            home use = grid import. A meter-only home uses it for everything; a solar + meter home keeps the
            inverter for its flows and bills from the meter (the utility-side truth, `grid_source`).
"""
import calendar
import statistics
import time
from datetime import date, datetime, timedelta

from . import config, db, sarima, tariff

MAX_GAP_S = 15 * 60
KEYS = ("pv_kwh", "load_kwh", "grid_import_kwh", "grid_export_kwh", "batt_charge_kwh", "batt_discharge_kwh")


# ------------------------------------------------------------- time helpers --
def local_midnight(d: date) -> int:
    return int(datetime(d.year, d.month, d.day, tzinfo=config.TZ).timestamp())


def today() -> date:
    return datetime.now(config.TZ).date()


def to_local(ts: int) -> datetime:
    return datetime.fromtimestamp(ts, config.TZ)


def _label(d: date, fmt: str) -> str:
    # "md" = "Nov 3" (strftime's %-d isn't available on Windows)
    return f"{d:%b} {d.day}" if fmt == "md" else d.strftime(fmt)


# -------------------------------------------------------------------- setup --
def setup(settings: dict | None = None) -> str:
    """solar | meter_only | solar_and_meter (unknown values count as solar, the original behaviour)."""
    v = (settings if settings is not None else db.get_settings()).get("setup", "solar")
    return v if v in config.SETUPS else "solar"


def has_solar(settings: dict | None = None) -> bool:
    return setup(settings) != "meter_only"


def flow_source(settings: dict | None = None) -> str:
    """Where solar / home use / battery come from: the inverter, or the meter in a home without solar."""
    return "inverter" if has_solar(settings) else "meter"


def grid_source(device_id: str, settings: dict | None = None) -> str:
    """Where the bill's grid kWh come from: the meter whenever the home has one that has reported."""
    mode = setup(settings)
    if mode == "meter_only" or (mode == "solar_and_meter" and db.has_meter(device_id)):
        return "meter"
    return "inverter"


def samples(device_id: str, start_ts: int, end_ts: int, source: str = "inverter") -> list[dict]:
    """Telemetry-shaped rows (ts, pv_w, load_w, grid_w, batt_w, grid_on) from either source."""
    if source == "inverter":
        return db.telemetry_between(device_id, start_ts, end_ts)
    out = []
    for r in db.meter_between(device_id, start_ts, end_ts, "power_w", "grid_on"):
        p = float(r["power_w"] or 0)
        out.append({"ts": r["ts"], "pv_w": 0, "load_w": max(p, 0.0), "grid_w": p, "batt_soc": None, "batt_w": 0,
                    "grid_on": r["grid_on"]})
    return out


# -------------------------------------------------------------- integration --
def _zero() -> dict:
    return {k: 0.0 for k in KEYS}


def _add_sample(acc: dict, r: dict, dt: float) -> None:
    h = dt / 3.6e6  # W*s -> kWh
    acc["pv_kwh"] += r["pv_w"] * h
    acc["load_kwh"] += r["load_w"] * h
    acc["grid_import_kwh"] += max(r["grid_w"], 0) * h
    acc["grid_export_kwh"] += max(-r["grid_w"], 0) * h
    acc["batt_charge_kwh"] += max(-r["batt_w"], 0) * h
    acc["batt_discharge_kwh"] += max(r["batt_w"], 0) * h


def _round(acc: dict) -> dict:
    return {k: round(v, 3) for k, v in acc.items()}


def buckets(device_id: str, edges: list[int], source: str | None = None) -> list[dict]:
    """kWh totals for each [edges[i], edges[i+1]) window. source None = flow_source() of the current setup."""
    rows = samples(device_id, edges[0], edges[-1], source or flow_source())
    out = [_zero() for _ in range(len(edges) - 1)]
    now = time.time()
    b = 0
    for i, r in enumerate(rows):
        nxt = rows[i + 1]["ts"] if i + 1 < len(rows) else min(edges[-1], now)
        dt = max(0.0, min(nxt - r["ts"], MAX_GAP_S))
        while b + 1 < len(edges) - 1 and r["ts"] >= edges[b + 1]:
            b += 1
        _add_sample(out[b], r, dt)
    return [_round(a) for a in out]


def totals(device_id: str, start_ts: int, end_ts: int, source: str | None = None) -> dict:
    return buckets(device_id, [start_ts, end_ts], source)[0]


_day_cache: dict[tuple[str, date, str], dict] = {}


def day_totals(device_id: str, d: date, source: str | None = None) -> dict:
    """Totals for one local day. Finished days are cached."""
    source = source or flow_source()
    key = (device_id, d, source)
    if key in _day_cache:
        return _day_cache[key]
    t = totals(device_id, local_midnight(d), local_midnight(d + timedelta(days=1)), source)
    if d < today():
        _day_cache[key] = t
    return t


def self_sufficiency(t: dict) -> float:
    if t["load_kwh"] <= 0:
        return 0.0
    return round(max(0.0, 1 - t["grid_import_kwh"] / t["load_kwh"]) * 100, 1)


def saved_kwh(t: dict) -> float:
    """Home use that did not come from the grid (solar direct + battery)."""
    return max(0.0, t["load_kwh"] - t["grid_import_kwh"])


# --------------------------------------------------------------------- live --
def device_info(device_id: str, latest: dict | None) -> dict:
    st = db.get_status(device_id) or {}
    last_seen = latest["ts"] if latest else None
    fresh = last_seen is not None and time.time() - last_seen <= config.OFFLINE_AFTER_S
    online = fresh and st.get("online", 1) != 0
    return {"id": device_id, "online": bool(online), "rssi": st.get("rssi"), "fw": st.get("fw"), "last_seen_ts": last_seen}


def runtime_hours(soc: int, load_w: int, battery_kwh: float) -> float | None:
    if load_w <= 0:
        return None
    return round(soc / 100 * battery_kwh * 1000 / load_w, 1)


def state_and_line(device: dict, t: dict | None, settings: dict) -> tuple[str, str]:
    from ai.faults import explain_fault

    if t is None:
        return "offline", "Wala pang natatanggap na data mula sa Solaris device."
    if not device["online"]:
        mins = max(1, round((time.time() - t["ts"]) / 60))
        return "offline", f"Offline ang Solaris device. Huling data {mins} minuto na ang nakaraan."
    if t["fault_code"]:
        return "fault", f"May problema ang inverter (fault {t['fault_code']}): {explain_fault(t['fault_code'])['title']}."
    if not t["grid_on"]:
        rt = runtime_hours(t["batt_soc"], t["load_w"], settings["battery_kwh"])
        extra = f" Aabot pa ng mga {rt:g} oras ang battery." if rt is not None else ""
        return "brownout", f"Brownout! Battery at solar ang gamit ng bahay mo.{extra}"
    if t["pv_w"] >= t["load_w"]:
        if t["batt_w"] < -50:
            return "solar", "Araw ang nagpapagana sa bahay mo ngayon, at nagcha-charge pa ang battery."
        if t["grid_w"] < -50:
            return "solar", "Araw ang nagpapagana sa bahay mo, at may sobra pang napupunta sa grid."
        return "solar", "Araw ang nagpapagana sa bahay mo ngayon."
    if t["batt_w"] > 0 and t["batt_w"] >= t["grid_w"]:
        return "battery", f"Battery ang gamit ng bahay mo ngayon ({t['batt_soc']}%)."
    return "grid", f"Kumukuha ka ng {t['grid_w']} W mula sa grid ngayon."


METER_REQUIRED = ("voltage_v", "power_w", "import_kwh", "export_kwh", "grid_on")
METER_FIELDS = ("meter_type", *METER_REQUIRED, "current_a", "apparent_va", "reactive_var", "pf", "freq_hz")


def meter_reading(m: dict | None) -> dict | None:
    """A stored meter payload as Contract C `meter` (Contract B fields only); None if it lacks the basics."""
    if m is None or any(m.get(k) is None for k in ("meter_type", *METER_REQUIRED)):
        return None
    return {"ts": m["ts"], **{k: m[k] for k in METER_FIELDS if m.get(k) is not None}}


def last_reading(device_id: str, settings: dict | None = None) -> dict | None:
    """What decides whether the device is online: telemetry, or meter readings in a home without solar."""
    return db.latest_telemetry(device_id) if has_solar(settings) else db.latest_meter(device_id)


def watts(w: float) -> str:
    return f"{w / 1000:.1f} kW" if abs(w) >= 1000 else f"{round(w)} W"


def meter_state_and_line(device: dict, m: dict | None) -> tuple[str, str]:
    """Status for a home with only a meter: there is no solar or battery to talk about, only the grid."""
    if m is None:
        return "offline", "Wala pang natatanggap na reading mula sa meter."
    if not device["online"]:
        mins = max(1, round((time.time() - m["ts"]) / 60))
        return "offline", f"Offline ang Solaris device. Huling reading {mins} minuto na ang nakaraan."
    if not m.get("grid_on", True):
        return "brownout", "Brownout! Walang kuryente mula sa grid ngayon."
    p = float(m.get("power_w") or 0)
    if p >= 20:
        return "grid", f"Kumukuha ang bahay mo ng {watts(p)} mula sa grid ngayon."
    if p <= -20:
        return "grid", f"Nagbabalik ang bahay mo ng {watts(-p)} sa grid ngayon."
    return "grid", "Halos walang kinukuha ang bahay mo sa grid ngayon."


def live(device_id: str, settings: dict) -> dict:
    mode = setup(settings)
    m = db.latest_meter(device_id) if mode != "solar" else None
    if mode == "meter_only":
        t = None
        device = device_info(device_id, m)
        state, line = meter_state_and_line(device, m)
    else:
        t = db.latest_telemetry(device_id)
        device = device_info(device_id, t)
        state, line = state_and_line(device, t, settings)
    rate = settings["rate_php_per_kwh"]
    return {
        "device": device,
        "telemetry": t,
        "state": state,
        "status_line": line,
        "saved_today_php": round(saved_kwh(day_totals(device_id, today(), flow_source(settings))) * rate, 2),
        "rate_php_per_kwh": rate,
        "setup": mode,
        "meter": meter_reading(m),
    }


# ------------------------------------------------------------------- energy --
def _months_back(d: date, n: int) -> date:
    """The day-1 date of the month n months before d's month."""
    m = d.year * 12 + (d.month - 1) - n
    return date(m // 12, m % 12 + 1, 1)


def energy(device_id: str, period: str, back: int = 0) -> dict:
    """`back` = how many whole periods before the current one (0 = today / past 7 days / this month,
    1 = yesterday / the 7 days before / last month)."""
    if back < 0:
        raise ValueError("back must be 0 or more")
    d = today()
    if period == "day":
        d -= timedelta(days=back)
    elif period == "week":
        d -= timedelta(days=7 * back)
    elif period == "month" and back:
        first = _months_back(d, back)
        d = date(first.year, first.month, calendar.monthrange(first.year, first.month)[1])
    if period == "day":
        start = local_midnight(d)
        edges = [start + h * 3600 for h in range(25)]
        bucket, fmt = "hour", "%H:00"
    elif period == "week":
        days = [d - timedelta(days=6 - i) for i in range(8)]
        edges = [local_midnight(x) for x in days]
        bucket, fmt = "day", "%a"
    elif period == "month":
        first = d.replace(day=1)
        n = calendar.monthrange(d.year, d.month)[1]
        edges = [local_midnight(first + timedelta(days=i)) for i in range(n + 1)]
        bucket, fmt = "day", "md"
    else:
        raise ValueError("period must be day, week or month")

    vals = buckets(device_id, edges)
    points = [{"ts": edges[i], "label": _label(to_local(edges[i]), fmt), **v} for i, v in enumerate(vals)]
    tot = _zero()
    for v in vals:
        for k in KEYS:
            tot[k] += v[k]
    tot = _round(tot)
    return {"period": period, "bucket": bucket, "start_ts": edges[0], "end_ts": edges[-1],
            "points": points, "totals": tot, "self_sufficiency_pct": self_sufficiency(tot)}


# ----------------------------------------------------------------- forecast --
AVG_DAYS = 28  # window for the weekday/weekend average fallback
# The month's range also allows for the household's LEVEL shifting (heat, a new appliance, guests), not only
# for day-to-day noise around the recent level: without it the "about 68%" range held the actual month only
# 30-40% of the time early in the month (tools/backtest_ranges.py). Its size, as a log-scale std dev of the
# remaining days' total, is how much this home's weekly use varies, at least LEVEL_SD_MIN.
LEVEL_SD_MIN = 0.2
LEVEL_SD_DEFAULT = 0.3   # fewer than 3 weeks with use to measure it on
# The level of the days ahead comes from the last RECENT_DAYS, not SARIMA's 8 weeks: in backtests SARIMA's
# level lagged the season and recent_level() cut the month-end error by 20-40% from day 1 to day 15. With
# fewer than RELEVEL_DAYS left, SARIMA's own level takes over gradually (it was slightly better there).
RECENT_DAYS = 14
RELEVEL_DAYS = 10
RATIO_BOUNDS = (0.5, 2.0)   # how far the simulated season change may move the recent level


def daily_history(device_id: str, d: date, n: int, source: str | None = None) -> list[tuple[date, float | None]]:
    """Grid import kWh of the n finished days before d, each divided by its season factor. None = no data.
    source None = grid_source(): the meter when the home has one."""
    source = source or grid_source(device_id)
    out = []
    for i in range(n, 0, -1):
        x = d - timedelta(days=i)
        k = day_totals(device_id, x, source)["grid_import_kwh"]
        out.append((x, k / tariff.season_factor(x) if k > 0 or _has_data(device_id, x, source=source) else None))
    return out


def forecast_days(device_id: str, d: date, n: int, today_kwh: float = 0.0, fallback_level: float = 0.0,
                  method: str | None = None, settings: dict | None = None, source: str | None = None) -> dict:
    """Expected grid import for days d .. d+n-1, season factor applied; day d is at least `today_kwh`.

    Day-to-day SHAPE and noise: SARIMA (sarima.py) when there are 4+ weeks of history, else weekday/weekend
    averages of the last 28 days (or `fallback_level` per day with no history at all). `method` overrides
    FORECAST_METHOD. LEVEL: re-levelled to `recent_level()` (the last 14 days carried to these days with
    the battery simulation), fully while RELEVEL_DAYS or more days are left, fading out after that.
    Returns {method, model, kwh: per day, totals: SARIMA's simulated sums of the n days (None for averages),
    sd: daily std dev (averages only), level_sd: uncertainty of the household's level, see LEVEL_SD_MIN}.
    """
    source = source or grid_source(device_id, settings)
    hist = daily_history(device_id, d, sarima.HISTORY_DAYS, source)
    days = [d + timedelta(days=i) for i in range(n)]
    f = [tariff.season_factor(x) for x in days]
    level_sd = _level_sd([v for _, v in hist])
    method = method or config.FORECAST_METHOD
    model = sarima.cached_forecast(f"{device_id}|{source}", d, [v for _, v in hist], n) if method == "sarima" else None
    if model is not None:
        import numpy as np
        kwh = [float(m * fx) for m, fx in zip(model["mean"], f)]
        sims = model["paths"] * np.array(f)[:, None]
        out = {"method": "sarima", "model": model["model"], "sd": None}
    else:
        recent = [(x, v) for x, v in hist[-AVG_DAYS:] if v is not None]
        wk = [v for x, v in recent if x.weekday() < 5]
        we = [v for x, v in recent if x.weekday() >= 5]
        allv = [v for _, v in recent]
        avg_all = statistics.mean(allv) if allv else fallback_level
        avg_wk = statistics.mean(wk) if wk else avg_all
        avg_we = statistics.mean(we) if we else avg_all
        sd = statistics.pstdev(allv) if len(allv) > 1 else avg_all * 0.2
        kwh = [(avg_wk if x.weekday() < 5 else avg_we) * fx for x, fx in zip(days, f)]
        sims = None
        out = {"method": "average", "model": "weekday/weekend average", "sd": sd * f[0]}

    level = recent_level(device_id, d, n, hist, settings)
    if level is not None and sum(kwh) > 0:
        w = min(1.0, n / RELEVEL_DAYS)
        x = (w * level * n + (1 - w) * sum(kwh)) / sum(kwh)
        kwh = [k * x for k in kwh]
        if sims is not None:
            sims = sims * x
        if out["sd"] is not None:
            out["sd"] *= x

    kwh[0] = max(today_kwh, kwh[0])
    if sims is not None:
        import numpy as np
        sims[0] = np.maximum(sims[0], today_kwh)
    return {**out, "kwh": kwh, "totals": sims.sum(axis=0) if sims is not None else None, "level_sd": level_sd}


def recent_level(device_id: str, d: date, n: int, hist: list[tuple[date, float | None]],
                 settings: dict | None = None) -> float | None:
    """Expected grid kWh per day over days d .. d+n-1: the mean of the last RECENT_DAYS metered days, times
    how much the battery simulation (projection.py: this home's own hourly profiles, load and sun scaled
    for the season) says grid use changes from the middle of those days to the middle of the forecast.
    A solar home's grid use is what is left after sun and battery, so it swings with the season far more
    than tariff.SEASON_INDEX (a whole-home prior) suggests. None = fewer than 7 recent days with data."""
    from . import outlook, projection

    recent = [v * tariff.season_factor(x) for x, v in hist[-RECENT_DAYS:] if v is not None]
    if len(recent) < 7:
        return None
    then = d - timedelta(days=RECENT_DAYS // 2)
    mid = d + timedelta(days=(n - 1) // 2)
    if not has_solar(settings):
        # No solar: grid use IS home use, so it follows the air-con season directly.
        ratio = projection._season(projection.LOAD_SEASON, mid) / projection._season(projection.LOAD_SEASON, then)
        return statistics.mean(recent) * min(max(ratio, RATIO_BOUNDS[0]), RATIO_BOUNDS[1])
    prof = outlook.profiles(device_id)
    if len(prof["pv"]) < 24 or len(prof["load"]) < 24:
        ratio = tariff.season_factor(mid) / tariff.season_factor(then)
    else:
        s = settings or db.get_settings()
        now = projection._daily_grid(prof, 1.0, 1.0, s)["grid"]
        later = projection._daily_grid(
            prof, projection._season(projection.LOAD_SEASON, mid) / projection._season(projection.LOAD_SEASON, then),
            projection._season(projection.SOLAR_SEASON, mid) / projection._season(projection.SOLAR_SEASON, then), s)["grid"]
        ratio = later / now if now > 0.05 else 1.0
    return statistics.mean(recent) * min(max(ratio, RATIO_BOUNDS[0]), RATIO_BOUNDS[1])


def _level_sd(series: list[float | None]) -> float:
    """Std dev of log weekly totals (newest full weeks of the days with data), at least LEVEL_SD_MIN."""
    import math
    v = [x for x in series if x is not None]
    weeks = [w for w in (sum(v[i:i + 7]) for i in range(len(v) % 7, len(v), 7)) if w > 0]
    if len(weeks) < 3:
        return LEVEL_SD_DEFAULT
    return max(LEVEL_SD_MIN, statistics.pstdev(math.log(w) for w in weeks))


def month_range(done_kwh: float, fc: dict) -> tuple[float, float, float]:
    """(expected, low, high) kWh for the month: finished days + forecast_days() for the rest.
    Low-high is about +-1 std dev (16th-84th percentile) and never narrower than +-5%."""
    rem = sum(fc["kwh"])
    mid = done_kwh + rem
    s = fc["level_sd"]
    if fc["totals"] is not None:
        # SARIMA paths carry day-to-day noise; each path's remaining total is also scaled by one level draw
        # (log-normal, mean 1, so the expected value doesn't move).
        import numpy as np
        z = np.random.default_rng(1).standard_normal(len(fc["totals"]))
        p16, p84 = (done_kwh + float(v) for v in np.percentile(fc["totals"] * np.exp(s * z - s * s / 2), [16, 84]))
        return mid, mid - max(mid - p16, mid * 0.05), mid + max(p84 - mid, mid * 0.05)
    # Averages: each remaining day is an independent draw (spread grows with √days), plus the level term.
    spread = max((fc["sd"] ** 2 * len(fc["kwh"]) + (s * rem) ** 2) ** 0.5, mid * 0.05)
    return mid, mid - spread, mid + spread


# --------------------------------------------------------------------- bill --
def bill(device_id: str, settings: dict) -> dict:
    rate = settings["rate_php_per_kwh"]
    d = today()
    first = d.replace(day=1)
    n_days = calendar.monthrange(d.year, d.month)[1]

    # Grid kWh from the bill's source (the meter when there is one); savings from the home's flows.
    src = grid_source(device_id, settings)
    flows_src = flow_source(settings)
    month_days = [first + timedelta(days=i) for i in range(d.day)]  # 1st .. today
    month_t = [day_totals(device_id, x, src) for x in month_days]
    flows = month_t if src == flows_src else [day_totals(device_id, x, flows_src) for x in month_days]
    mtd_kwh = sum(t["grid_import_kwh"] for t in month_t)
    savings_month = sum(saved_kwh(t) for t in flows) * rate

    # Forecast in kWh first (SARIMA, or weekday/weekend averages), then priced with Meralco's levels.
    today_kwh = month_t[-1]["grid_import_kwh"]
    fc = forecast_days(device_id, d, n_days - d.day + 1, today_kwh,
                       fallback_level=mtd_kwh / max(1, d.day) / tariff.season_factor(d), settings=settings, source=src)
    done_kwh = mtd_kwh - today_kwh  # finished days this month
    fc_kwh, lo_kwh, hi_kwh = month_range(done_kwh, fc)

    forecast = tariff.cost(fc_kwh, rate)  # incl. fixed monthly charges
    eff_rate = tariff.rate_at(fc_kwh, rate)  # ₱/kWh at the level this month is heading for
    mtd_php = mtd_kwh * eff_rate
    low = max(mtd_php, tariff.cost(max(mtd_kwh, lo_kwh), rate))
    high = tariff.cost(hi_kwh, rate)

    # Last month: its kWh are final, so price them exactly.
    last_end = first - timedelta(days=1)
    last_days = [last_end.replace(day=1) + timedelta(days=i) for i in range(last_end.day)]
    last_month = (tariff.cost(sum(day_totals(device_id, x, src)["grid_import_kwh"] for x in last_days), rate)
                  if _has_data(device_id, last_days[0], last_end, src) else None)

    # Weekly costs: the last 4 weeks starting Monday, current week included, at this month's ₱/kWh.
    monday = d - timedelta(days=d.weekday())
    weekly = []
    for w in range(3, -1, -1):
        ws = monday - timedelta(weeks=w)
        days = [ws + timedelta(days=i) for i in range(7) if ws + timedelta(days=i) <= d]
        cost = sum(day_totals(device_id, x, src)["grid_import_kwh"] for x in days) * eff_rate
        weekly.append({"week_start_ts": local_midnight(ws), "label": _label(ws, "md"), "php": round(cost, 2)})

    level_lo, level_hi, _ = tariff.bracket(fc_kwh)
    return {
        "month": d.strftime("%Y-%m"), "days_elapsed": d.day, "days_in_month": n_days, "rate_php_per_kwh": rate,
        "month_to_date_kwh": round(mtd_kwh, 2), "month_to_date_php": round(mtd_php, 2),
        "forecast_php": round(forecast, 2),
        "forecast_low_php": round(low, 2),
        "forecast_high_php": round(high, 2),
        "last_month_php": round(last_month, 2) if last_month is not None else None,
        "vs_last_month_pct": round((forecast - last_month) / last_month * 100, 1) if last_month else None,
        "savings_today_php": round(saved_kwh(flows[-1]) * rate, 2),
        "savings_month_php": round(savings_month, 2),
        "weekly_costs": weekly,
        "grid_source": src,
        # Not in Contract C (FastAPI drops them from /api/bill); used by the AI facts.
        "forecast_kwh": round(fc_kwh, 1),
        "forecast_rate_php_per_kwh": round(eff_rate, 2),
        "forecast_bracket_kwh": (level_lo, level_hi),
        "forecast_method": fc["method"],
        "forecast_model": fc["model"],
    }


def _has_data(device_id: str, start: date, end: date | None = None, source: str = "inverter") -> bool:
    end = end or start
    table = "meter" if source == "meter" else "telemetry"
    r = db.one(f"SELECT 1 AS x FROM {table} WHERE device_id=? AND ts>=? AND ts<? LIMIT 1",
               (device_id, local_midnight(start), local_midnight(end + timedelta(days=1))))
    return r is not None


# ----------------------------------------------------------------- brownout --
def brownout(device_id: str, settings: dict) -> dict:
    from ai.prompts import brownout_advice, meter_brownout_advice, outlook_brownout_note

    from . import outlook

    o = db.open_outage(device_id) or db.last_outage(device_id)
    active = bool(o and o["end_ts"] is None)
    first = local_midnight(today().replace(day=1))
    n = db.one("SELECT COUNT(*) AS n FROM outages WHERE device_id=? AND start_ts>=?", (device_id, first))["n"]
    if not has_solar(settings):
        # Meter only: outages come from the meter's grid_on; no battery, so no runtime.
        end = o["end_ts"] if o and o["end_ts"] else time.time()
        return {"active": active, "start_ts": o["start_ts"] if o else None,
                "duration_min": round((end - o["start_ts"]) / 60) if o else None,
                "batt_soc": None, "load_w": None, "runtime_h": None,
                "advice": meter_brownout_advice(active), "outages_this_month": n}
    t = db.latest_telemetry(device_id)
    soc = t["batt_soc"] if t else None
    load = t["load_w"] if t else None
    rt = runtime_hours(soc, load, settings["battery_kwh"]) if t else None
    end = o["end_ts"] if o and o["end_ts"] else time.time()
    return {
        "active": active,
        "start_ts": o["start_ts"] if o else None,
        "duration_min": round((end - o["start_ts"]) / 60) if o else None,
        "batt_soc": soc, "load_w": load, "runtime_h": rt,
        "advice": brownout_advice(active, soc, load, rt, outlook_brownout_note(outlook.outlook(device_id, settings)) if active and t else ""),
        "outages_this_month": n,
    }
