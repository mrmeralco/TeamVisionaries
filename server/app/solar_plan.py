"""Solar plan (/api/solar-plan): how big a solar setup this household needs, for a home with no solar yet.

From the last PLAN_DAYS days of the home's own use (the meter, for setup meter_only), two options:

  grid_tie  panels + grid-tie inverter, no battery: sized to the use while the sun is up (6 AM-6 PM).
            Extra solar goes to the grid (net metering credit, SOLAR_EXPORT_PHP_PER_KWH).
  hybrid    panels + hybrid inverter + battery: sized to cover ~90 % of the day's use, the battery to the
            night's. Keeps lights on in a brownout (backup_hours at the usual night load).

Each option is simulated hour by hour on the home's typical day (average kWh for each hour), with a
Philippine-average sun day (SOLAR_YIELD_KWH_PER_KWP_DAY kWh per kWp, a bell from 6 AM to 6 PM):
solar used directly, battery charge/discharge (90 % usable, 95 % each way), and export. The bill after
uses the real Meralco tier math (tariff.cost), so moving to a cheaper level counts. Cost is rough PH
installed prices from config; payback = cost / yearly savings.

The recommendation never depends on sponsors. `sponsors` are ad slots shown apart from it, labelled as
sponsored: entries from SPONSORS_FILE (JSON list) when it exists, else placeholders.
"""
import json
import math
import time
from datetime import timedelta

from . import config, energy, tariff

PLAN_DAYS = 30
MIN_DAYS = 7
SUN_START, SUN_END = 6, 18
DOD = 0.9                  # usable share of a LiFePO4 battery
ETA = 0.95                 # charge and discharge efficiency, each way
HYBRID_COVER = 0.9         # hybrid panels sized to this share of the day's use
BATTERY_STEP = 2.5         # kWh per module
BATTERY_MIN, BATTERY_MAX = 5.0, 20.0
INVERTER_SIZES = (3.0, 3.6, 5.0, 6.0, 8.0, 10.0, 12.0, 15.0)
DC_AC_RATIO = 1.25         # panels may be this much bigger than the inverter
PEAK_MARGIN = 1.1          # hybrid inverter must carry the home's peak + this margin in a brownout
MIN_PANELS = 2
NIGHT_SHARE_FOR_HYBRID = 0.4   # recommend the battery when this much of the use is at night

PLACEHOLDER_SPONSORS = [
    {"id": "slot_installer", "kind": "installer", "name": "Solar installer",
     "tagline": "Ad space for an accredited solar installer near you.", "url": None, "placeholder": True},
    {"id": "slot_panels", "kind": "panel_brand", "name": "Solar panel brand",
     "tagline": "Ad space for a panel or inverter brand.", "url": None, "placeholder": True},
    {"id": "slot_financing", "kind": "financing", "name": "Solar financing",
     "tagline": "Ad space for a solar loan or installment partner.", "url": None, "placeholder": True},
]
SPONSOR_KINDS = ("installer", "panel_brand", "inverter_brand", "battery_brand", "financing")


def _peso(x: float) -> str:
    return f"₱{x:,.0f}"


def sun_shape(yield_kwh: float) -> list[float]:
    """kWh per kWp for each hour of a typical PH day (a sine bell from 6 AM to 6 PM) adding up to yield_kwh."""
    raw = [math.sin((h + 0.5 - SUN_START) / (SUN_END - SUN_START) * math.pi) if SUN_START <= h < SUN_END else 0.0
           for h in range(24)]
    total = sum(raw)
    return [r / total * yield_kwh for r in raw]


# ----------------------------------------------------------------- usage --
def usage(device_id: str, settings: dict) -> dict | None:
    """Typical day from the last PLAN_DAYS finished days: average kWh per hour. None with < MIN_DAYS of data."""
    src = energy.flow_source(settings)
    today = energy.today()
    start = energy.local_midnight(today - timedelta(days=PLAN_DAYS))
    rows = energy.buckets(device_id, [start + i * 3600 for i in range(PLAN_DAYS * 24 + 1)], src)
    by_hour, days = [0.0] * 24, 0
    for d in range(PLAN_DAYS):
        chunk = rows[d * 24:(d + 1) * 24]
        if sum(b["load_kwh"] for b in chunk) <= 0.05:
            continue
        days += 1
        for h, b in enumerate(chunk):
            by_hour[h] += b["load_kwh"]
    if days < MIN_DAYS:
        return {"days": days} if days else None
    by_hour = [x / days for x in by_hour]
    recent = energy.samples(device_id, energy.local_midnight(today - timedelta(days=7)), energy.local_midnight(today), src)
    loads = sorted(float(r["load_w"]) for r in recent)
    peak = loads[min(len(loads) - 1, int(0.99 * len(loads)))] if loads else max(by_hour) * 1000
    return {"days": days, "by_hour": by_hour, "peak_w": peak}


# -------------------------------------------------------------- simulate --
def simulate(by_hour: list[float], kwp: float, battery_kwh: float, inverter_kw: float, yield_kwh: float) -> dict:
    """One typical day, repeated until the battery settles. kWh a day: solar made, home use covered by
    solar or battery, export, and what's still bought from the grid."""
    pv = [kwp * s for s in sun_shape(yield_kwh)]
    usable = battery_kwh * DOD
    soc = 0.0
    for _ in range(4):                              # 4 days: the battery's start doesn't matter any more
        covered = export = grid = 0.0
        for h in range(24):
            ac = min(pv[h], inverter_kw)            # the inverter clips what it can't pass
            direct = min(ac, by_hour[h])
            need = by_hour[h] - direct
            spare = ac - direct
            if usable:
                charge = min(spare, inverter_kw, (usable - soc) / ETA)
                soc += charge * ETA
                spare -= charge
                out = min(need, inverter_kw, soc * ETA)
                soc -= out / ETA
                need -= out
                direct += out
            covered += direct
            export += spare
            grid += need
    return {"solar_kwh_day": sum(pv), "covered_kwh_day": covered, "export_kwh_day": export, "grid_kwh_day": grid}


def _inverter_for(kw: float) -> float:
    return next((s for s in INVERTER_SIZES if s >= kw - 1e-9), INVERTER_SIZES[-1])


def option(kind: str, by_hour: list[float], peak_w: float, rate: float) -> dict:
    yield_kwh = config.SOLAR_YIELD_KWH_PER_KWP_DAY
    day_kwh = sum(by_hour[SUN_START:SUN_END])
    total = sum(by_hour)
    night = total - day_kwh
    if kind == "grid_tie":
        target_kwp, battery = day_kwh / yield_kwh, 0.0
    else:
        target_kwp = total * HYBRID_COVER / yield_kwh
        battery = min(BATTERY_MAX, max(BATTERY_MIN, math.ceil(night / DOD / BATTERY_STEP - 1e-9) * BATTERY_STEP))
    panel_kw = config.SOLAR_PANEL_W / 1000
    panels = max(MIN_PANELS, math.ceil(target_kwp / panel_kw - 1e-9))
    kwp = round(panels * panel_kw, 2)
    inv = _inverter_for(kwp / DC_AC_RATIO) if kind == "grid_tie" else \
        _inverter_for(max(kwp / DC_AC_RATIO, peak_w * PEAK_MARGIN / 1000))

    s = simulate(by_hour, kwp, battery, inv, yield_kwh)
    month_before = total * 30
    month_after = s["grid_kwh_day"] * 30
    export_credit = s["export_kwh_day"] * 30 * config.SOLAR_EXPORT_PHP_PER_KWH
    bill_before = tariff.cost(month_before, rate)
    bill_after = max(0.0, tariff.cost(month_after, rate) - export_credit)
    savings = bill_before - bill_after
    inv_php = inv * (config.SOLAR_GRIDTIE_INVERTER_PHP_PER_KW if kind == "grid_tie"
                     else config.SOLAR_HYBRID_INVERTER_PHP_PER_KW)
    cost = kwp * config.UPGRADE_PV_PHP_PER_KWP + inv_php + battery * config.UPGRADE_BATTERY_PHP_PER_KWH
    night_w = night / 12 * 1000 if night > 0 else 0
    backup_h = round(battery * DOD / night_w * 1000, 1) if battery and night_w > 0 else None
    covers = round(min(100.0, s["covered_kwh_day"] / total * 100)) if total > 0 else 0

    out = {
        "id": kind, "recommended": False,
        "title": "Grid-tie (walang battery)" if kind == "grid_tie" else "Hybrid na may battery",
        "pv_kwp": kwp, "panels": panels, "panel_w": int(config.SOLAR_PANEL_W),
        "roof_m2": round(panels * config.SOLAR_PANEL_M2), "inverter_kw": inv,
        "battery_kwh": battery if battery else None,
        "solar_kwh_day": round(s["solar_kwh_day"], 1), "covers_pct": covers,
        "export_kwh_day": round(s["export_kwh_day"], 1),
        "bill_before_php_month": round(bill_before), "bill_after_php_month": round(bill_after),
        "savings_php_month": round(savings), "cost_php": int(round(cost, -3)),
        "payback_years": round(cost / (savings * 12), 1) if savings > 0 else None,
        "backup_hours": backup_h,
        "co2_kg_year": round((s["covered_kwh_day"] + s["export_kwh_day"]) * 365 * config.GRID_CO2_KG_PER_KWH),
    }
    return out


def _why(o: dict, night_share: float) -> str:
    if o["id"] == "hybrid":
        return (f"{night_share:.0f}% ng gamit mo ay sa gabi, kaya may silbi ang battery: iniipon nito ang sobrang "
                f"araw para sa gabi, at kaya nitong buhayin ang bahay nang mga {o['backup_hours']:g} oras sa brownout.")
    return (f"{100 - night_share:.0f}% ng gamit mo ay habang may araw, kaya diretsong magagamit ang solar kahit walang "
            "battery. Mas mura at mas mabilis bumalik ang puhunan.")


def sponsors() -> list[dict]:
    """Ad slots from SPONSORS_FILE (a JSON list of {id, kind, name, tagline, url}), else placeholders."""
    path = config.SPONSORS_FILE
    try:
        items = json.loads(path.read_text()) if path and path.exists() else None
    except (OSError, ValueError):
        items = None
    if not isinstance(items, list):
        return [dict(s) for s in PLACEHOLDER_SPONSORS]
    out = []
    for i, s in enumerate(items[:6]):
        if isinstance(s, dict) and s.get("name") and s.get("kind") in SPONSOR_KINDS:
            out.append({"id": str(s.get("id") or f"sponsor_{i + 1}"), "kind": s["kind"], "name": str(s["name"]),
                        "tagline": str(s.get("tagline") or ""), "url": s.get("url") or None, "placeholder": False})
    return out or [dict(s) for s in PLACEHOLDER_SPONSORS]


DISCLAIMER = ("Tantiya lang ito mula sa gamit mo at karaniwang araw sa Pilipinas. Ipasukat sa installer ang bubong, "
              "lilim at wiring bago bumili. Ang mga ad ay hiwalay sa rekomendasyon.")


def plan(device_id: str, settings: dict) -> dict:
    """The /api/solar-plan response."""
    rate = settings["rate_php_per_kwh"]
    base = {"generated_ts": int(time.time()), "setup": energy.setup(settings),
            "has_solar": energy.has_solar(settings), "days": 0, "usage": None, "options": [],
            "yield_kwh_per_kwp_day": config.SOLAR_YIELD_KWH_PER_KWP_DAY, "sponsors": sponsors(),
            "disclaimer": DISCLAIMER}
    if base["has_solar"]:
        return base | {"headline": "May solar ka na. Tingnan ang System check para malaman kung kailangan pang dagdagan."}
    u = usage(device_id, settings)
    if not u or "by_hour" not in u:
        days = u["days"] if u else 0
        return base | {"days": days,
                       "headline": f"Kailangan ng {MIN_DAYS} araw ng readings para masukat ang tamang laki ng solar "
                                   f"(mayroon pa lang {days})."}

    by_hour = u["by_hour"]
    total = sum(by_hour)
    day_kwh = sum(by_hour[SUN_START:SUN_END])
    night_share = (total - day_kwh) / total * 100 if total > 0 else 0
    opts = [option("grid_tie", by_hour, u["peak_w"], rate), option("hybrid", by_hour, u["peak_w"], rate)]
    best = opts[1] if night_share >= NIGHT_SHARE_FOR_HYBRID * 100 else opts[0]
    best["recommended"] = True
    for o in opts:
        o["why"] = _why(o, night_share)
    head = (f"Para sa {total:.1f} kWh kada araw mo, {best['pv_kwp']:g} kWp na solar ({best['panels']} panels"
            + (f" + {best['battery_kwh']:g} kWh na battery" if best["battery_kwh"] else "")
            + f"): mga {_peso(best['savings_php_month'])} na tipid kada buwan, balik-puhunan sa mga "
            + (f"{best['payback_years']:g} taon." if best["payback_years"] else "— taon."))
    return base | {
        "days": u["days"], "headline": head,
        "usage": {"kwh_day": round(total, 1), "day_kwh_day": round(day_kwh, 1),
                  "night_kwh_day": round(total - day_kwh, 1), "night_share_pct": round(night_share),
                  "peak_w": round(u["peak_w"]), "bill_php_month": opts[0]["bill_before_php_month"]},
        "options": sorted(opts, key=lambda o: not o["recommended"]),
    }
