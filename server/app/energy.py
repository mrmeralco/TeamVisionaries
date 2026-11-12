"""Energy math: live status, kWh series, bill + forecast (tiered, seasonal), brownout runtime.

Power samples (W) are integrated over time: each sample counts until the next one, capped at
MAX_GAP_S so a gap in the data (device off) doesn't count as hours of usage.
"""
import calendar
import statistics
import time
from datetime import date, datetime, timedelta

from . import config, db, tariff

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


def buckets(device_id: str, edges: list[int]) -> list[dict]:
    """kWh totals for each [edges[i], edges[i+1]) window."""
    rows = db.telemetry_between(device_id, edges[0], edges[-1])
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


def totals(device_id: str, start_ts: int, end_ts: int) -> dict:
    return buckets(device_id, [start_ts, end_ts])[0]


_day_cache: dict[tuple[str, date], dict] = {}


def day_totals(device_id: str, d: date) -> dict:
    """Totals for one local day. Finished days are cached."""
    key = (device_id, d)
    if key in _day_cache:
        return _day_cache[key]
    t = totals(device_id, local_midnight(d), local_midnight(d + timedelta(days=1)))
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
        return "offline", "Wala pang natatanggap na data mula sa Sinag device."
    if not device["online"]:
        mins = max(1, round((time.time() - t["ts"]) / 60))
        return "offline", f"Offline ang Sinag device. Huling data {mins} minuto na ang nakaraan."
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


def live(device_id: str, settings: dict) -> dict:
    t = db.latest_telemetry(device_id)
    device = device_info(device_id, t)
    state, line = state_and_line(device, t, settings)
    rate = settings["rate_php_per_kwh"]
    return {
        "device": device,
        "telemetry": t,
        "state": state,
        "status_line": line,
        "saved_today_php": round(saved_kwh(day_totals(device_id, today())) * rate, 2),
        "rate_php_per_kwh": rate,
    }


# ------------------------------------------------------------------- energy --
def energy(device_id: str, period: str) -> dict:
    d = today()
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


# --------------------------------------------------------------------- bill --
def bill(device_id: str, settings: dict) -> dict:
    rate = settings["rate_php_per_kwh"]
    d = today()
    first = d.replace(day=1)
    n_days = calendar.monthrange(d.year, d.month)[1]

    month_days = [first + timedelta(days=i) for i in range(d.day)]  # 1st .. today
    month_t = [day_totals(device_id, x) for x in month_days]
    mtd_kwh = sum(t["grid_import_kwh"] for t in month_t)
    savings_month = sum(saved_kwh(t) for t in month_t) * rate

    # Forecast in kWh first, then priced with Meralco's consumption levels (tariff.py).
    # History = last 28 finished days, each divided by its season factor so a hot April and a cool
    # March can be averaged together; weekday and weekend are averaged separately.
    hist = [(x, day_totals(device_id, x)["grid_import_kwh"]) for x in (d - timedelta(days=i) for i in range(1, 29))]
    hist = [(x, k / tariff.season_factor(x)) for x, k in hist if k > 0 or _has_data(device_id, x)]
    wk = [k for x, k in hist if x.weekday() < 5]
    we = [k for x, k in hist if x.weekday() >= 5]
    allk = [k for _, k in hist]
    avg_all = statistics.mean(allk) if allk else mtd_kwh / max(1, d.day) / tariff.season_factor(d)
    avg_wk = statistics.mean(wk) if wk else avg_all
    avg_we = statistics.mean(we) if we else avg_all
    sd = statistics.pstdev(allk) if len(allk) > 1 else avg_all * 0.2

    def typical(x: date) -> float:
        return (avg_wk if x.weekday() < 5 else avg_we) * tariff.season_factor(x)

    today_kwh = month_t[-1]["grid_import_kwh"]
    future = [first + timedelta(days=i) for i in range(d.day, n_days)]
    fc_kwh = (mtd_kwh - today_kwh) + max(today_kwh, typical(d)) + sum(typical(x) for x in future)
    # Each remaining day (today included) is an independent draw, so the spread grows with √days.
    spread_kwh = max(sd * tariff.season_factor(d) * (len(future) + 1) ** 0.5, fc_kwh * 0.05)

    forecast = tariff.cost(fc_kwh, rate)  # incl. fixed monthly charges
    eff_rate = tariff.rate_at(fc_kwh, rate)  # ₱/kWh at the level this month is heading for
    mtd_php = mtd_kwh * eff_rate
    low = max(mtd_php, tariff.cost(max(mtd_kwh, fc_kwh - spread_kwh), rate))
    high = tariff.cost(fc_kwh + spread_kwh, rate)

    # Last month: its kWh are final, so price them exactly.
    last_end = first - timedelta(days=1)
    last_days = [last_end.replace(day=1) + timedelta(days=i) for i in range(last_end.day)]
    last_month = (tariff.cost(sum(day_totals(device_id, x)["grid_import_kwh"] for x in last_days), rate)
                  if _has_data(device_id, last_days[0], last_end) else None)

    # Weekly costs: the last 4 weeks starting Monday, current week included, at this month's ₱/kWh.
    monday = d - timedelta(days=d.weekday())
    weekly = []
    for w in range(3, -1, -1):
        ws = monday - timedelta(weeks=w)
        days = [ws + timedelta(days=i) for i in range(7) if ws + timedelta(days=i) <= d]
        cost = sum(day_totals(device_id, x)["grid_import_kwh"] for x in days) * eff_rate
        weekly.append({"week_start_ts": local_midnight(ws), "label": _label(ws, "md"), "php": round(cost, 2)})

    lo_kwh, hi_kwh, _ = tariff.bracket(fc_kwh)
    return {
        "month": d.strftime("%Y-%m"), "days_elapsed": d.day, "days_in_month": n_days, "rate_php_per_kwh": rate,
        "month_to_date_kwh": round(mtd_kwh, 2), "month_to_date_php": round(mtd_php, 2),
        "forecast_php": round(forecast, 2),
        "forecast_low_php": round(low, 2),
        "forecast_high_php": round(high, 2),
        "last_month_php": round(last_month, 2) if last_month is not None else None,
        "vs_last_month_pct": round((forecast - last_month) / last_month * 100, 1) if last_month else None,
        "savings_today_php": round(saved_kwh(month_t[-1]) * rate, 2),
        "savings_month_php": round(savings_month, 2),
        "weekly_costs": weekly,
        # Not in Contract C (FastAPI drops them from /api/bill); used by the AI facts.
        "forecast_kwh": round(fc_kwh, 1),
        "forecast_rate_php_per_kwh": round(eff_rate, 2),
        "forecast_bracket_kwh": (lo_kwh, hi_kwh),
    }


def _has_data(device_id: str, start: date, end: date | None = None) -> bool:
    end = end or start
    r = db.one("SELECT 1 AS x FROM telemetry WHERE device_id=? AND ts>=? AND ts<? LIMIT 1",
               (device_id, local_midnight(start), local_midnight(end + timedelta(days=1))))
    return r is not None


# ----------------------------------------------------------------- brownout --
def brownout(device_id: str, settings: dict) -> dict:
    from ai.prompts import brownout_advice, outlook_brownout_note

    from . import outlook

    t = db.latest_telemetry(device_id)
    o = db.open_outage(device_id) or db.last_outage(device_id)
    active = bool(o and o["end_ts"] is None)
    soc = t["batt_soc"] if t else None
    load = t["load_w"] if t else None
    rt = runtime_hours(soc, load, settings["battery_kwh"]) if t else None
    end = o["end_ts"] if o and o["end_ts"] else time.time()
    first = local_midnight(today().replace(day=1))
    n = db.one("SELECT COUNT(*) AS n FROM outages WHERE device_id=? AND start_ts>=?", (device_id, first))["n"]
    return {
        "active": active,
        "start_ts": o["start_ts"] if o else None,
        "duration_min": round((end - o["start_ts"]) / 60) if o else None,
        "batt_soc": soc, "load_w": load, "runtime_h": rt,
        "advice": brownout_advice(active, soc, load, rt, outlook_brownout_note(outlook.outlook(device_id, settings)) if active and t else ""),
        "outages_this_month": n,
    }
