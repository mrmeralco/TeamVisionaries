"""Where an answer's data comes from: one entry per fact behind the reply, for the app's source list.

Every entry is built from the same backend fact the answer used, so what the user sees under Mira's
reply is exactly the data the reply was allowed to say. Nothing here comes from the model.

    id        fact id (same as facts_used)
    label     short English name, e.g. "Bill forecast"
    value     headline value when the fact has one, e.g. "₱2,450" (else null)
    detail    the fact as one Taglish sentence, with the full numbers (e.g. the forecast range)
    kind      live | history | forecast | settings | advice   (how the backend got it)
    period    what time it covers, e.g. "Right now", "This month", "Last 7 days"
    screen    app screen that shows it: home | energy | bill | brownout | alerts | settings (or null)
    as_of_ts  when it was measured (live readings) or computed (everything else); null for settings
"""
from .facts import Fact

LIVE, HISTORY, FORECAST, SETTINGS, ADVICE = "live", "history", "forecast", "settings", "advice"

# id -> (label, kind, period, screen)
META: dict[str, tuple[str, str, str, str | None]] = {
    "now.status": ("Home status", LIVE, "Right now", "home"),
    "now.online": ("Device connection", LIVE, "Right now", "home"),
    "now.solar_w": ("Solar now", LIVE, "Right now", "home"),
    "now.load_w": ("Home use now", LIVE, "Right now", "home"),
    "now.grid_w": ("Grid now", LIVE, "Right now", "home"),
    "now.battery_pct": ("Battery level", LIVE, "Right now", "home"),
    "now.battery_w": ("Battery power", LIVE, "Right now", "home"),
    "now.battery_kwh": ("Battery size", SETTINGS, "Your system", "settings"),
    "now.temp_c": ("Inverter temperature", LIVE, "Right now", "home"),
    "usage.peak_hours": ("Peak grid hours", HISTORY, "Last 7 days", "energy"),
    "bill.rate": ("Electricity rate", SETTINGS, "Your settings", "settings"),
    "bill.month_to_date_php": ("Bill so far", HISTORY, "This month", "bill"),
    "bill.forecast_php": ("Bill forecast", FORECAST, "End of this month", "bill"),
    "bill.forecast_kwh": ("Forecast grid use", FORECAST, "End of this month", "bill"),
    "bill.forecast_method": ("How the forecast works", FORECAST, "Based on your history", "bill"),
    "bill.days_left": ("Days left this month", HISTORY, "This month", "bill"),
    "bill.last_month_php": ("Last month's bill", HISTORY, "Last month", "bill"),
    "bill.vs_last_month_pct": ("Forecast vs last month", FORECAST, "This month vs last", "bill"),
    "bill.savings_month_php": ("Saved this month", HISTORY, "This month", "bill"),
    "brownout.active": ("Brownout status", LIVE, "Right now", "brownout"),
    "brownout.runtime_h": ("Battery runtime", FORECAST, "At current use", "brownout"),
    "brownout.advice": ("Brownout advice", ADVICE, "Right now", "brownout"),
    "brownout.count_month": ("Brownouts this month", HISTORY, "This month", "brownout"),
    "outlook.solar_tomorrow_kwh": ("Solar tomorrow", FORECAST, "Tomorrow", "brownout"),
    "outlook.solar_today_kwh": ("Solar expected today", FORECAST, "Today", "brownout"),
    "outlook.battery_reserve": ("Battery reserve", FORECAST, "Next 48 hours", "brownout"),
    "outlook.battery_full": ("Battery full", FORECAST, "Next 48 hours", "brownout"),
    "outlook.brownout_until": ("Battery in a brownout", FORECAST, "Next 48 hours", "brownout"),
    "outlook.advice": ("Sun & battery advice", ADVICE, "Next 48 hours", "brownout"),
    "projection.limits": ("How far Solaris can project", ADVICE, "Up to 3 months ahead", "bill"),
    "projection.m1": ("Projected bill", FORECAST, "Next month (estimate)", "bill"),
    "projection.m2": ("Projected bill", FORECAST, "2 months ahead (estimate)", "bill"),
    "projection.m3": ("Projected bill", FORECAST, "3 months ahead (estimate)", "bill"),
    "upgrade.system": ("Your system", SETTINGS, "Your setup", "bill"),
    "upgrade.verdict": ("System check", ADVICE, "Last 30 days", "bill"),
    "upgrade.battery": ("Battery upgrade", ADVICE, "Last 30 days", "bill"),
    "upgrade.solar": ("Solar panel upgrade", ADVICE, "Last 30 days", "bill"),
    "upgrade.inverter": ("Inverter upgrade", ADVICE, "Last 30 days", "bill"),
    "upgrade.usage": ("Rising household use", ADVICE, "Last 7 days", "bill"),
    "upgrade.not_needed": ("Not needed now", ADVICE, "Last 30 days", "bill"),
    "fault.active": ("Inverter health", LIVE, "Right now", "alerts"),
    "alerts.unread": ("Unread alerts", LIVE, "Right now", "alerts"),
}
# today.* / yesterday.* / week.* share their suffixes.
DAY_LABELS = {"solar_kwh": "Solar", "load_kwh": "Home use", "grid_kwh": "From grid", "cost_php": "Grid cost",
              "saved_php": "Saved", "self_sufficiency_pct": "Not from grid"}
PERIODS = {"today": "Today", "yesterday": "Yesterday", "week": "Last 7 days"}
HIDDEN = {"user.name"}  # used for tone only; not data the user needs to check


def meta(fact_id: str) -> tuple[str, str, str, str | None]:
    if fact_id in META:
        return META[fact_id]
    prefix, _, suffix = fact_id.partition(".")
    if prefix in PERIODS and suffix in DAY_LABELS:
        label = DAY_LABELS[suffix] + ("" if prefix == "week" else " " + PERIODS[prefix].lower())
        return label, HISTORY, PERIODS[prefix], "energy"
    return fact_id, HISTORY, "", None


def build(fact_ids: list[str], by_id: dict[str, Fact], measured_ts: int | None, computed_ts: int) -> list[dict]:
    """One source per cited fact, in citation order. Unknown ids and the user's name are skipped."""
    out, seen = [], set()
    for fid in fact_ids:
        f = by_id.get(fid)
        if f is None or fid in HIDDEN or fid in seen:
            continue
        if fid == "now.online" and not f.text.startswith("OFFLINE"):
            continue  # "device is online" adds nothing; an offline notice does
        seen.add(fid)
        label, kind, period, screen = meta(fid)
        out.append({
            "id": fid, "label": label, "value": f.chip[1] if f.chip else None, "detail": f.spoken,
            "kind": kind, "period": period, "screen": screen,
            "as_of_ts": None if kind == SETTINGS else (measured_ts if kind == LIVE and measured_ts else computed_ts),
        })
    return out
