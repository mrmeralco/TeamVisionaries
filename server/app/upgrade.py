"""System check: does this household's solar setup still fit how it uses electricity?

Looks at the last UPGRADE_DAYS days of the home's own readings (not a generic table) and recommends:
  battery   surplus solar goes to the grid in the day while the nights run on the grid
  solar     the home buys from the grid while the sun is up, or there's too little sun to fill the battery
  inverter  the household's peak load is close to what the inverter can deliver
  usage     no hardware: use is climbing, or heavy loads run at night
Sizes are rounded to what installers sell (0.5 kWp of panels, 2.5 kWh battery modules, 1 kW inverter steps).
Money is a rough estimate from configurable PH prices (config.UPGRADE_*); the app says so.
"""
import math
import time
from datetime import timedelta

from . import config, db, energy

DAY_START_H, DAY_END_H = 6, 18     # "sun hours" for day vs night grid use
MIN_DAYS = 7                       # fewer days of data -> not enough to judge
EMPTY_MARGIN = 3                   # battery "ran out" = reached reserve + this many %
BATTERY_USABLE = 0.8               # share of a new module's kWh you can cycle every day

_cache: dict[str, tuple[float, dict]] = {}
CACHE_S = 600


def _round_up(x: float, step: float) -> float:
    return math.ceil(x / step - 1e-9) * step


def _peso(x: float) -> str:
    return f"₱{x:,.0f}"


def stats(device_id: str, settings: dict, days: int | None = None) -> dict | None:
    """Daily averages over the last `days` full days. None if fewer than MIN_DAYS have data."""
    days = days or config.UPGRADE_DAYS
    end = energy.today()
    start = end - timedelta(days=days)
    edges = [energy.local_midnight(start + timedelta(days=i // 24)) + (i % 24) * 3600 for i in range(days * 24)]
    edges.append(energy.local_midnight(end))
    hourly = energy.buckets(device_id, edges)

    rows = db.telemetry_between(device_id, edges[0], edges[-1])
    if not rows:
        return None
    soc_min: dict[int, float] = {}            # day index -> lowest battery % that day (grid on)
    peak_w, loads = 0, []
    for r in rows:
        di = (r["ts"] - edges[0]) // 86400
        if r["grid_on"]:
            soc_min[di] = min(soc_min.get(di, 100), r["batt_soc"])
        peak_w = max(peak_w, r["load_w"])
        loads.append(r["load_w"])

    per_day = []
    for d in range(days):
        hrs = hourly[d * 24:(d + 1) * 24]
        load = sum(h["load_kwh"] for h in hrs)
        if load <= 0.05:
            continue                           # no data that day
        day_imp = sum(h["grid_import_kwh"] for i, h in enumerate(hrs) if DAY_START_H <= i < DAY_END_H)
        per_day.append({
            "load": load, "pv": sum(h["pv_kwh"] for h in hrs),
            "import": sum(h["grid_import_kwh"] for h in hrs), "day_import": day_imp,
            "night_import": sum(h["grid_import_kwh"] for h in hrs) - day_imp,
            "export": sum(h["grid_export_kwh"] for h in hrs),
            "empty": soc_min.get(d, 100) <= config.BATT_RESERVE_PCT + EMPTY_MARGIN,
        })
    if len(per_day) < MIN_DAYS:
        return None

    n = len(per_day)
    avg = {k: sum(p[k] for p in per_day) / n for k in ("load", "pv", "import", "day_import", "night_import", "export")}
    last7 = per_day[-7:]
    before = per_day[:-7]
    trend = None
    if len(before) >= 7:
        prev = sum(p["load"] for p in before) / len(before)
        trend = round((sum(p["load"] for p in last7) / len(last7) / prev - 1) * 100) if prev > 0 else None
    loads.sort()
    return {
        "days": n,
        "load_kwh_day": round(avg["load"], 1), "pv_kwh_day": round(avg["pv"], 1),
        "grid_import_kwh_day": round(avg["import"], 1),
        "day_import_kwh_day": round(avg["day_import"], 1), "night_import_kwh_day": round(avg["night_import"], 1),
        "export_kwh_day": round(avg["export"], 1),
        "self_sufficiency_pct": round(max(0.0, 1 - avg["import"] / avg["load"]) * 100) if avg["load"] else 0,
        "battery_empty_days_pct": round(sum(p["empty"] for p in per_day) / n * 100),
        "peak_load_w": int(peak_w), "p95_load_w": int(loads[int(len(loads) * 0.95)]) if loads else 0,
        "load_trend_pct": trend,
    }


def recommend(device_id: str, settings: dict) -> dict:
    """The /api/upgrade response. Cached for CACHE_S (Mira asks for it on every upgrade question)."""
    key = f"{device_id}:{settings['battery_kwh']}:{settings['rate_php_per_kwh']}"
    hit = _cache.get(key)
    if hit and time.time() - hit[0] < CACHE_S:
        return hit[1]
    out = _recommend(device_id, settings)
    _cache[key] = (time.time(), out)
    return out


def _recommend(device_id: str, settings: dict) -> dict:
    rate = settings["rate_php_per_kwh"]
    system = {"pv_kwp": config.PV_KWP, "battery_kwh": settings["battery_kwh"], "inverter_kw": config.INVERTER_KW}
    base = {"generated_ts": int(time.time()), "system": system}
    s = stats(device_id, settings)
    if s is None:
        return {**base, "enough_data": False, "verdict": "unknown", "usage": None, "recommendations": [],
                "headline": f"Kailangan pa ng hindi bababa sa {MIN_DAYS} araw ng data bago ko masabi kung sapat ang system mo."}

    recs = []
    yield_per_kwp = s["pv_kwh_day"] / config.PV_KWP if config.PV_KWP > 0 else 0

    # Battery: sun left over in the day (exported) while the nights still run on the grid.
    shiftable = min(s["export_kwh_day"], s["night_import_kwh_day"])
    if s["night_import_kwh_day"] >= 1.0 and s["battery_empty_days_pct"] >= 30 and shiftable >= 1.0:
        add = max(2.5, _round_up(shiftable / BATTERY_USABLE, 2.5))
        save = shiftable * rate * 30
        cost = add * config.UPGRADE_BATTERY_PHP_PER_KWH
        recs.append({
            "id": "battery", "title": "Dagdag na battery", "add": f"+{add:g} kWh",
            "reason": (f"Halos {s['export_kwh_day']:.1f} kWh na solar kada araw ang napupunta lang sa grid, pero "
                       f"{s['night_import_kwh_day']:.1f} kWh ang binibili mo sa grid tuwing gabi. Naubos ang battery "
                       f"sa {s['battery_empty_days_pct']}% ng mga araw. Ang dagdag na {add:g} kWh ay makakaipon ng "
                       f"sobrang araw para sa gabi."),
            "evidence": [{"label": "Solar sent to grid", "value": f"{s['export_kwh_day']:.1f} kWh/day"},
                         {"label": "Grid at night", "value": f"{s['night_import_kwh_day']:.1f} kWh/day"},
                         {"label": "Battery ran out", "value": f"{s['battery_empty_days_pct']}% of days"}],
            "savings_php_month": round(save), "cost_php": round(cost),
            "payback_years": round(cost / (save * 12), 1) if save > 0 else None,
        })

    # Solar: grid bought while the sun is up, plus night use the battery can't cover because there's no surplus.
    unmet_night = max(0.0, s["night_import_kwh_day"] - s["export_kwh_day"])
    deficit = s["day_import_kwh_day"] + (unmet_night if s["battery_empty_days_pct"] >= 30 else 0.0)
    if deficit >= 1.5 and yield_per_kwp > 0.5:
        add = max(0.5, _round_up(deficit / yield_per_kwp, 0.5))
        covered = min(add * yield_per_kwp, deficit)
        save = covered * rate * 30
        cost = add * config.UPGRADE_PV_PHP_PER_KWP
        # The night part only pays off if there's battery room to keep the extra sun for the evening.
        why_night = (f" Kulang din ang araw para sa gabi, kaya {unmet_night:.1f} kWh pa ang kinukuha sa grid tuwing gabi; "
                     "para magamit sa gabi ang dagdag na araw, kailangan ding may puwang sa battery."
                     ) if unmet_night >= 0.5 and s["battery_empty_days_pct"] >= 30 else ""
        recs.append({
            "id": "solar", "title": "Dagdag na solar panels", "add": f"+{add:g} kWp",
            "reason": (f"Kumukuha ka pa ng {s['day_import_kwh_day']:.1f} kWh sa grid kada araw kahit may araw.{why_night} "
                       f"Bawat kWp ng panel mo ay gumagawa ng mga {yield_per_kwp:.1f} kWh kada araw dito."),
            "evidence": [{"label": "Grid while sunny", "value": f"{s['day_import_kwh_day']:.1f} kWh/day"},
                         {"label": "Solar per kWp", "value": f"{yield_per_kwp:.1f} kWh/day"},
                         {"label": "Self-sufficiency", "value": f"{s['self_sufficiency_pct']}%"}],
            "savings_php_month": round(save), "cost_php": round(cost),
            "payback_years": round(cost / (save * 12), 1) if save > 0 else None,
        })

    # Inverter: the household's peaks against what the inverter can deliver.
    rating_w = config.INVERTER_KW * 1000
    if rating_w and (s["p95_load_w"] >= 0.85 * rating_w or s["peak_load_w"] >= rating_w):
        add_kw = max(1.0, _round_up(s["peak_load_w"] * 1.2 / 1000 - config.INVERTER_KW, 1.0))
        recs.append({
            "id": "inverter", "title": "Mas malaking inverter", "add": f"{config.INVERTER_KW + add_kw:g} kW",
            "reason": (f"Umaabot sa {s['peak_load_w']:,} W ang sabay-sabay na gamit ng bahay mo, malapit o lampas sa "
                       f"{config.INVERTER_KW:g} kW na kaya ng inverter. Kapag lumampas, grid ang sasalo o titigil ang "
                       "inverter. Habang wala pa, iwasang sabay-sabayin ang aircon, plantsa at water heater."),
            "evidence": [{"label": "Peak household load", "value": f"{s['peak_load_w']:,} W"},
                         {"label": "Inverter rating", "value": f"{config.INVERTER_KW:g} kW"}],
            "savings_php_month": None, "cost_php": round(config.UPGRADE_INVERTER_PHP), "payback_years": None,
        })

    # Usage (no hardware): rising use, or night-heavy use that panels alone won't fix.
    trend = s["load_trend_pct"]
    if trend is not None and trend >= 15:
        recs.append({
            "id": "usage", "title": "Tumataas ang gamit mo", "add": f"+{trend}%",
            "reason": (f"Mas mataas ng {trend}% ang gamit mo nitong huling 7 araw kumpara sa mga naunang linggo. "
                       "Kung tuloy-tuloy ito, baka kulangin ang system mo; tingnan muna kung may bagong appliance."),
            "evidence": [{"label": "Use per day", "value": f"{s['load_kwh_day']:.1f} kWh"},
                         {"label": "Change, last 7 days", "value": f"+{trend}%"}],
            "savings_php_month": None, "cost_php": None, "payback_years": None,
        })

    hardware = [r for r in recs if r["id"] != "usage"]
    hardware.sort(key=lambda r: (r["payback_years"] is None, r["payback_years"] or 0))
    recs = hardware + [r for r in recs if r["id"] == "usage"]
    for i, r in enumerate(recs, 1):
        r["priority"] = i

    if hardware:
        top = hardware[0]
        headline = f"Pwedeng i-upgrade: {top['title'].lower()} ({top['add']})"
        if top["savings_php_month"]:
            headline += f", mga {_peso(top['savings_php_month'])} na tipid kada buwan."
        else:
            headline += "."
    else:
        headline = (f"Sakto ang system mo para sa gamit mo: {s['self_sufficiency_pct']}% ng kuryente mo ay hindi "
                    "galing sa grid, at hindi pa kailangan ng upgrade.")
    return {**base, "enough_data": True, "verdict": "consider" if hardware else "ok",
            "headline": headline, "usage": s, "recommendations": recs}
