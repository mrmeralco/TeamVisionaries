"""Smart meter mode (/api/meter): what the household's meter reads, and what it means for the bill.

For any home whose Solaris device reads a meter (Contract A2 smart meter or A3 Meralco meter): a home with
no solar (`setup` meter_only, where the meter sees everything the house uses) or with solar too
(solar_and_meter, where the meter sees only what is bought from / sent to the grid).

    reading   the latest Contract B meter payload (V, A, W, VA, VAr, PF, Hz, kWh registers, grid on)
    quality   voltage against the nominal 230 V ± 10 % (GRID_NOMINAL_V, GRID_V_TOLERANCE), last 24 h; power factor
    usage     last USAGE_DAYS finished days: kWh a day, always-on base load, peak, peak hours, night share,
              the typical day hour by hour
    tier      the Meralco consumption level this month's forecast lands in (energy.bill, tariff.bracket), how far
              it is above the cheaper level below or below the dearer level above
    insights  Taglish cards built only from the numbers above, warnings first
"""
import statistics
import time
from datetime import timedelta

from . import config, db, energy, tariff

USAGE_DAYS = 7
BASE_PERCENTILE = 10        # always-on use = 10th percentile of the power drawn
NIGHT_HOURS = set(range(18, 24)) | set(range(0, 6))
TIER_DROP_SHARE = 0.25      # suggest getting under the lower level only if that's within 25 % of the forecast
TIER_NEAR_SHARE = 0.10      # warn about the next level within 10 % of the forecast
PF_GOOD, PF_FAIR = 0.90, 0.80
VOLTAGE_WARN_PCT = 5        # share of the last 24 h out of range that earns a warning


def _hour(h: int) -> str:
    return f"{h % 12 or 12}{'AM' if h < 12 else 'PM'}"


def _hours_label(hours: list[int]) -> str:
    labels = [_hour(h) for h in hours]
    return labels[0] if len(labels) == 1 else ", ".join(labels[:-1]) + " at " + labels[-1]


def level_label(lo: float, hi: float | None) -> str:
    if hi is None:
        return f"lampas {lo:.0f} kWh"
    return f"hanggang {hi:.0f} kWh" if lo == 0 else f"{lo + 1:.0f}–{hi:.0f} kWh"


def _quality(device_id: str, reading: dict | None, now: int) -> dict | None:
    if reading is None:
        return None
    nominal = config.GRID_NOMINAL_V
    lo, hi = nominal * (1 - config.GRID_V_TOLERANCE), nominal * (1 + config.GRID_V_TOLERANCE)
    rows = db.meter_between(device_id, now - 86400, now + 1, "voltage_v", "grid_on")
    vs = [float(r["voltage_v"]) for r in rows if r["grid_on"] and r["voltage_v"] is not None]
    v = reading["voltage_v"]
    status = "off" if not reading["grid_on"] else "low" if v < lo else "high" if v > hi else "normal"
    pf = reading.get("pf")
    pf_status = None if pf is None else "good" if abs(pf) >= PF_GOOD else "fair" if abs(pf) >= PF_FAIR else "poor"
    return {
        "nominal_v": nominal, "low_limit_v": round(lo, 1), "high_limit_v": round(hi, 1), "voltage_status": status,
        "min_v_24h": round(min(vs), 1) if vs else None,
        "avg_v_24h": round(statistics.mean(vs), 1) if vs else None,
        "max_v_24h": round(max(vs), 1) if vs else None,
        "out_of_range_pct_24h": round(sum(1 for x in vs if x < lo or x > hi) / len(vs) * 100, 1) if vs else None,
        "pf_status": pf_status,
    }


def _usage(device_id: str) -> dict | None:
    """Last USAGE_DAYS finished days of grid import from the meter (days without any reading are skipped)."""
    end = energy.local_midnight(energy.today())
    start = energy.local_midnight(energy.today() - timedelta(days=USAGE_DAYS))
    hourly = energy.buckets(device_id, [start + i * 3600 for i in range(USAGE_DAYS * 24 + 1)], "meter")
    by_hour = [0.0] * 24
    weekday, weekend, total, days = [], [], 0.0, 0
    for day in range(USAGE_DAYS):
        chunk = hourly[day * 24:(day + 1) * 24]
        kwh = sum(b["grid_import_kwh"] for b in chunk)
        if kwh <= 0 and not energy._has_data(device_id, energy.today() - timedelta(days=USAGE_DAYS - day), source="meter"):
            continue
        days += 1
        total += kwh
        (weekend if energy.to_local(start + day * 86400).weekday() >= 5 else weekday).append(kwh)
        for h, b in enumerate(chunk):   # hour h of a local day (Manila has no DST)
            by_hour[h] += b["grid_import_kwh"]
    if days == 0:
        return None
    by_hour = [x / days for x in by_hour]
    ranked = sorted(range(24), key=lambda h: by_hour[h], reverse=True)
    powers = sorted(float(r["power_w"]) for r in db.meter_between(device_id, start, end, "power_w")
                    if r["power_w"] is not None and float(r["power_w"]) > 0)
    base = powers[min(len(powers) - 1, len(powers) * BASE_PERCENTILE // 100)] if powers else 0.0
    return {
        "days": days,
        "import_kwh_day": round(total / days, 2),
        "base_w": round(base),
        "peak_w": round(powers[-1]) if powers else 0,
        "peak_hours": sorted(h for h in ranked[:3] if by_hour[h] > 0),
        "night_share_pct": round(sum(by_hour[h] for h in NIGHT_HOURS) / sum(by_hour) * 100) if sum(by_hour) > 0 else 0,
        "weekday_kwh_day": round(statistics.mean(weekday), 2) if weekday else None,
        "weekend_kwh_day": round(statistics.mean(weekend), 2) if weekend else None,
        "by_hour_kwh": [round(x, 3) for x in by_hour],
    }


def _tier(device_id: str, settings: dict) -> dict:
    b = energy.bill(device_id, settings)
    rate = settings["rate_php_per_kwh"]
    fc = b["forecast_kwh"]
    lo, hi, _ = tariff.bracket(fc)
    above = fc - lo if lo > 0 else None
    to_next = hi - fc if hi is not None else None
    return {
        "month": b["month"], "days_left": b["days_in_month"] - b["days_elapsed"] + 1,   # today included
        "month_to_date_kwh": b["month_to_date_kwh"], "forecast_kwh": fc,
        "level_min_kwh": lo, "level_max_kwh": hi,
        "rate_php_per_kwh": round(tariff.rate_at(fc, rate), 2),
        "kwh_above_lower_level": round(above, 1) if above is not None else None,
        "save_php_at_lower_level": round(tariff.cost(fc, rate) - tariff.cost(lo, rate)) if above is not None else None,
        "kwh_to_next_level": round(to_next, 1) if to_next is not None else None,
        "next_level_rate_php_per_kwh": round(tariff.rate_at(hi + 1, rate), 2) if hi is not None else None,
    }


def _ev(label: str, value: str) -> dict:
    return {"label": label, "value": value}


def _insights(r: dict, settings: dict) -> list[dict]:
    """Every number in a card comes from `r` (this response). Warnings first, then money, habits, the reading."""
    solar = energy.has_solar(settings)
    use = "kinukuha mo sa grid" if solar else "ginagamit ng bahay mo"
    warn, money, habit, info = [], [], [], []
    q, u, t, m = r["quality"], r["usage"], r["tier"], r["reading"]

    if q and m and m["grid_on"]:
        v, lo, hi = m["voltage_v"], q["low_limit_v"], q["high_limit_v"]
        bad = q["out_of_range_pct_24h"]
        if q["voltage_status"] in ("low", "high") or (bad is not None and bad >= VOLTAGE_WARN_PCT):
            word = "mataas" if q["voltage_status"] == "high" else "mababa"
            warn.append({"id": "voltage", "tone": "warning", "title": f"{word.capitalize()} ang boltahe",
                         "body": f"{v:.0f} V ang boltahe ngayon; ang normal ay {lo:.0f}–{hi:.0f} V"
                                 + (f", at {bad:g}% ng huling 24 oras ay lampas dito" if bad else "")
                                 + ". Nakakasira ito sa motor ng aircon at ref. Kung madalas, i-report sa Meralco.",
                         "evidence": [_ev("Voltage now", f"{v:.0f} V"), _ev("Normal range", f"{lo:.0f}–{hi:.0f} V")]})
        else:
            info.append({"id": "voltage", "tone": "good", "title": "Normal ang boltahe",
                         "body": f"{v:.0f} V ang boltahe ngayon, pasok sa normal na {lo:.0f}–{hi:.0f} V.",
                         "evidence": [_ev("Voltage now", f"{v:.0f} V"), _ev("Normal range", f"{lo:.0f}–{hi:.0f} V")]})
        if q["pf_status"] == "poor":
            pf = m["pf"]
            warn.append({"id": "power_factor", "tone": "warning", "title": "Mababa ang power factor",
                         "body": f"{pf:.2f} ang power factor ngayon. Karaniwan ito kapag tumatakbo ang lumang aircon, "
                                 "ref o bomba ng tubig. Hindi ito sinisingil ng Meralco sa bahay, pero tanda ito na may "
                                 "motor na hindi na episyente.",
                         "evidence": [_ev("Power factor", f"{pf:.2f}")]})

    if t:
        fc, lo, hi = t["forecast_kwh"], t["level_min_kwh"], t["level_max_kwh"]
        above, days = t["kwh_above_lower_level"], t["days_left"]
        if above is not None and above <= TIER_DROP_SHARE * fc and days >= 3 and t["save_php_at_lower_level"]:
            per_day = above / days
            money.append({"id": "tier_drop", "tone": "info", "title": "Kaya pang bumaba sa mas murang antas",
                          "body": f"Mga {fc:.0f} kWh ang inaasahang gamit mo ngayong buwan, {above:.0f} kWh lampas sa "
                                  f"{lo:.0f} kWh. Kung mababawasan mo ito ng mga {per_day:.1f} kWh kada araw sa natitirang "
                                  f"{days} araw, mas murang antas ng Meralco ang sisingilin sa buong buwan: mga "
                                  f"₱{t['save_php_at_lower_level']:,.0f} na tipid.",
                          "evidence": [_ev("Forecast use", f"{fc:.0f} kWh"), _ev("Cheaper level", f"up to {lo:.0f} kWh"),
                                       _ev("Possible savings", f"₱{t['save_php_at_lower_level']:,.0f}")]})
        elif t["kwh_to_next_level"] is not None and t["kwh_to_next_level"] <= TIER_NEAR_SHARE * fc:
            money.append({"id": "tier_near", "tone": "warning", "title": "Malapit na sa mas mahal na antas",
                          "body": f"Mga {fc:.0f} kWh ang inaasahang gamit mo, {t['kwh_to_next_level']:.0f} kWh na lang bago "
                                  f"lumampas sa {hi:.0f} kWh. Lampas doon, mas mahal ang bawat kWh ng buong buwan "
                                  f"(₱{t['rate_php_per_kwh']:.2f} → ₱{t['next_level_rate_php_per_kwh']:.2f}).",
                          "evidence": [_ev("Forecast use", f"{fc:.0f} kWh"), _ev("Next level from", f"{hi:.0f} kWh")]})
        else:
            money.append({"id": "tier", "tone": "info", "title": f"Antas ngayong buwan: {level_label(lo, hi)}",
                          "body": f"Mga {fc:.0f} kWh ang inaasahang gamit mo ngayong buwan, kaya nasa {level_label(lo, hi)} "
                                  f"na antas ka ng Meralco, mga ₱{t['rate_php_per_kwh']:.2f} kada kWh.",
                          "evidence": [_ev("Forecast use", f"{fc:.0f} kWh"), _ev("Rate", f"₱{t['rate_php_per_kwh']:.2f}/kWh")]})

    if u:
        if u["peak_hours"]:
            habit.append({"id": "peak_hours", "tone": "info", "title": f"Pinakamalakas tuwing {_hours_label(u['peak_hours'])}",
                          "body": f"Sa huling {u['days']} araw, pinakamarami ang {use} tuwing {_hours_label(u['peak_hours'])}, "
                                  f"at {u['night_share_pct']}% nito ay sa gabi (6PM–6AM). Doon unang magtipid: aircon sa 25°C, "
                                  "at isang kuwarto lang ang palamigin kung kaya.",
                          "evidence": [_ev("Peak hours", _hours_label(u["peak_hours"])),
                                       _ev("At night", f"{u['night_share_pct']}%")]})
        if u["base_w"] >= 50:
            kwh_month = u["base_w"] * 24 * 30 / 1000
            php = kwh_month * (t["rate_php_per_kwh"] if t else settings["rate_php_per_kwh"])
            habit.append({"id": "base_load", "tone": "info", "title": f"Laging bukas: mga {u['base_w']} W",
                          "body": f"Kahit tulog ang lahat, mga {u['base_w']} W ang {use} (ref, router, mga naka-standby). "
                                  f"Mga {kwh_month:.0f} kWh iyan kada buwan, mga ₱{php:,.0f}. Hugutin ang mga charger at "
                                  "appliance na hindi ginagamit.",
                          "evidence": [_ev("Always on", f"{u['base_w']} W"), _ev("Per month", f"{kwh_month:.0f} kWh")]})

    if m:
        if m["meter_type"] == "ansi-c12":
            body = (f"{m['import_kwh']:,.1f} kWh ang basa ng Meralco meter mo ngayon. Ang kWh sa bill mo = basa sa "
                    "araw ng pagbasa ngayong buwan bawas ang basa noong nakaraang buwan.")
        else:
            body = (f"{m['import_kwh']:,.1f} kWh na ang nasukat ng smart meter mo mula nang ikabit ito. Ihambing ang "
                    "pagtaas nito sa kWh na nakasulat sa Meralco bill mo.")
        info.append({"id": "reading", "tone": "info", "title": f"Basa ng meter: {m['import_kwh']:,.1f} kWh", "body": body,
                     "evidence": [_ev("Meter reading", f"{m['import_kwh']:,.1f} kWh")]})
    return warn + money + habit + info


def info(device_id: str, settings: dict) -> dict:
    now = int(time.time())
    m = db.latest_meter(device_id)
    reading = energy.meter_reading(m)
    out = {
        "generated_ts": now,
        "setup": energy.setup(settings),
        "online": bool(reading) and energy.device_info(device_id, m)["online"],
        "reading": reading,
        "quality": _quality(device_id, reading, now),
        "usage": _usage(device_id) if reading else None,
        "tier": _tier(device_id, settings) if reading and energy.grid_source(device_id, settings) == "meter" else None,
    }
    out["insights"] = _insights(out, settings)
    return out
