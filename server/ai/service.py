"""AI service: gathers facts from the DB, asks the LLM, falls back to rule-based text if it can't.

/api/chat -> chat(); /api/summary/daily -> daily_summary() (pre-generated, cached per date).
"""
import logging
from datetime import date, timedelta

from app import db, energy

from . import llm, prompts
from .faults import explain_fault

log = logging.getLogger("sinag.ai")


# ------------------------------------------------------------------- facts --
def peak_hours(device_id: str, days: int = 7) -> list[int]:
    """Hours of the day (0-23) with the most grid import over the last `days` days."""
    start = energy.local_midnight(energy.today() - timedelta(days=days))
    edges = [start + h * 3600 for h in range(days * 24 + 1)]
    by_hour = [0.0] * 24
    for i, b in enumerate(energy.buckets(device_id, edges)):
        by_hour[i % 24] += b["grid_import_kwh"]
    ranked = sorted(range(24), key=lambda h: by_hour[h], reverse=True)
    return sorted(h for h in ranked[:3] if by_hour[h] > 0)


def gather(device_id: str, settings: dict) -> dict:
    rate = settings["rate_php_per_kwh"]
    live = energy.live(device_id, settings)
    t = live["telemetry"]
    today = energy.day_totals(device_id, energy.today())
    bill = energy.bill(device_id, settings)
    bo = energy.brownout(device_id, settings)
    return {
        "live": live, "today": today, "bill": bill, "brownout": bo,
        "peak_hours": peak_hours(device_id),
        "fault": explain_fault(t["fault_code"]) | {"code": t["fault_code"]} if t and t["fault_code"] else None,
        "rate": rate,
        "cost_today_php": round(today["grid_import_kwh"] * rate, 2),
    }


def facts_text(f: dict) -> str:
    live, t, today, bill, bo = f["live"], f["live"]["telemetry"], f["today"], f["bill"], f["brownout"]
    lines = [f"- Ngayon: {live['status_line']}"]
    if t:
        lines.append(f"- Live: solar {t['pv_w']} W, gamit ng bahay {t['load_w']} W, grid {t['grid_w']} W "
                     f"(+ kuha, - benta), battery {t['batt_soc']}%")
    lines += [
        f"- Ngayong araw: solar {today['pv_kwh']:.1f} kWh, gamit {today['load_kwh']:.1f} kWh, "
        f"mula sa grid {today['grid_import_kwh']:.1f} kWh = {prompts.peso(f['cost_today_php'])}, natipid {prompts.peso(bill['savings_today_php'])}",
        f"- Bill ngayong buwan (hanggang ngayon): {prompts.peso(bill['month_to_date_php'])}; "
        f"forecast sa katapusan: {prompts.peso(bill['forecast_php'])} "
        f"({prompts.peso(bill['forecast_low_php'])} hanggang {prompts.peso(bill['forecast_high_php'])})",
        f"- Bill noong nakaraang buwan: {prompts.peso(bill['last_month_php'])}"
        + (f" ({bill['vs_last_month_pct']:+.0f}% ang forecast kumpara dito)" if bill["vs_last_month_pct"] is not None else ""),
        f"- Natipid dahil sa solar ngayong buwan: {prompts.peso(bill['savings_month_php'])}",
        f"- Rate ng kuryente: ₱{f['rate']:.2f}/kWh",
    ]
    if f["peak_hours"]:
        lines.append("- Oras na pinakamaraming kuha sa grid (7 araw): " + ", ".join(f"{h}:00" for h in f["peak_hours"]))
    if bo["active"]:
        lines.append(f"- BROWNOUT ngayon, {bo['duration_min']} minuto na. {bo['advice']}")
    if f["fault"]:
        lines.append(f"- FAULT {f['fault']['code']}: {f['fault']['title']}. {f['fault']['message']}")
    return "\n".join(lines)


def chips(f: dict) -> list[dict]:
    bill, live = f["bill"], f["live"]
    out = [
        {"label": "Bill this month", "value": prompts.peso(bill["month_to_date_php"])},
        {"label": "Forecast", "value": prompts.peso(bill["forecast_php"])},
        {"label": "Saved today", "value": prompts.peso(bill["savings_today_php"])},
    ]
    if live["telemetry"]:
        out.append({"label": "Battery", "value": f"{live['telemetry']['batt_soc']}%"})
    if f["brownout"]["active"] and f["brownout"]["runtime_h"] is not None:
        out.append({"label": "Battery runtime", "value": f"{f['brownout']['runtime_h']:g} h"})
    return out


# -------------------------------------------------------------------- chat --
def fallback_reply(message: str, f: dict) -> str:
    """Rule-based answer used when the LLM is off, down or too slow. Demo must never go silent."""
    m = message.lower()
    bill, bo = f["bill"], f["brownout"]
    if f["fault"] and any(w in m for w in ("fault", "error", "init", "sira", "problema")):
        return f"{f['fault']['title']}. {f['fault']['message']}"
    if any(w in m for w in ("brownout", "battery", "tatagal", "kuryente")) and bo["active"]:
        return bo["advice"]
    if any(w in m for w in ("bill", "bayad", "mahal", "mataas", "gastos", "magkano")):
        peaks = ", ".join(f"{h}:00" for h in f["peak_hours"]) or "gabi"
        return (f"{prompts.peso(bill['month_to_date_php'])} na ang bill mo ngayong buwan, at mga "
                f"{prompts.peso(bill['forecast_php'])} ang forecast sa katapusan. Pinakamaraming kuha sa grid tuwing {peaks}, "
                f"kapag wala nang araw. Subukang gamitin ang malalaking appliances habang maaraw.")
    if any(w in m for w in ("solar", "araw", "tipid", "natipid")):
        return (f"Ngayong araw, {f['today']['pv_kwh']:.1f} kWh ang galing sa solar at {prompts.peso(bill['savings_today_php'])} "
                f"ang natipid mo. Ngayong buwan, {prompts.peso(bill['savings_month_php'])} na ang natipid.")
    return f"{f['live']['status_line']} {prompts.peso(bill['month_to_date_php'])} na ang bill mo ngayong buwan."


async def chat(device_id: str, settings: dict, message: str) -> dict:
    f = gather(device_id, settings)
    try:
        reply = await llm.complete(prompts.SYSTEM, prompts.CHAT_USER.format(
            facts=facts_text(f), user_name=settings["user_name"], message=message))
        source = "llm"
    except llm.LLMUnavailable as e:
        log.warning("chat fallback: %s", e)
        reply, source = fallback_reply(message, f), "fallback"
    return {"reply": reply, "chips": chips(f), "source": source}


# ------------------------------------------------------------ daily summary --
def _summary_totals(device_id: str, d: date, rate: float) -> dict:
    t = energy.day_totals(device_id, d)
    return {
        "pv_kwh": round(t["pv_kwh"], 2), "load_kwh": round(t["load_kwh"], 2),
        "grid_import_kwh": round(t["grid_import_kwh"], 2),
        "cost_php": round(t["grid_import_kwh"] * rate, 2),
        "savings_php": round(energy.saved_kwh(t) * rate, 2),
        "self_sufficiency_pct": energy.self_sufficiency(t),
    }


async def daily_summary(device_id: str, settings: dict, force: bool = False) -> dict:
    d = energy.today() - timedelta(days=1)
    key = f"summary:{device_id}:{d.isoformat()}"
    cached = db.get_kv(key)
    if cached and not force and (cached["source"] == "llm" or not llm_enabled()):
        return cached

    tot = _summary_totals(device_id, d, settings["rate_php_per_kwh"])
    facts = (f"- Solar: {tot['pv_kwh']} kWh; gamit ng bahay: {tot['load_kwh']} kWh\n"
             f"- {tot['self_sufficiency_pct']}% ng kuryente ay hindi galing sa grid (solar + battery)\n"
             f"- Kuha sa grid: {tot['grid_import_kwh']} kWh = {prompts.peso(tot['cost_php'])}\n"
             f"- Natipid dahil sa solar: {prompts.peso(tot['savings_php'])}")
    try:
        text = await llm.complete(prompts.SYSTEM, prompts.SUMMARY_USER.format(
            date=d.isoformat(), facts=facts, user_name=settings["user_name"]), max_tokens=160)
        source = "llm"
    except llm.LLMUnavailable as e:
        log.warning("summary fallback: %s", e)
        text = (f"Kahapon, {tot['self_sufficiency_pct']:.0f}% ng kuryente mo ay galing sa solar at battery. "
                f"{prompts.peso(tot['cost_php'])} lang ang nagastos sa grid at {prompts.peso(tot['savings_php'])} ang natipid mo. "
                f"Tip: gamitin ang washing machine at plantsa habang maaraw.")
        source = "fallback"
    out = {"date": d.isoformat(), "summary": text, "totals": tot, "source": source}
    db.put_kv(key, out)
    return out


def llm_enabled() -> bool:
    from app import config
    return config.LLM_ENABLED
