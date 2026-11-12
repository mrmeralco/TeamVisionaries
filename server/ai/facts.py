"""FACTS: the only things the AI is allowed to say.

Every fact is computed by the backend from SQLite. Each one has:
  id      stable name the model must cite in `fact_ids` (e.g. "bill.forecast_php")
  topic   used by the router to pick which facts go into the prompt
  text    one Taglish line shown to the model, with the number already formatted
  values  every number the model may quote from this fact (the guard checks the reply against these)
  chip    optional (label, value) shown as a data chip in the app when the model cites this fact
  say     optional natural sentence for the user, used by direct and rule-based answers instead of the
          label-style `text` (same numbers, same meaning; tests check it adds no numbers)

To teach Mira something new: add a Fact here (and a keyword in router.py). Never let the model compute.
"""
import re
from dataclasses import dataclass, field
from datetime import timedelta

from app import db, energy, outlook

from .faults import explain_fault
from .prompts import when


@dataclass
class Fact:
    id: str
    topic: str
    text: str
    values: tuple[float, ...] = ()
    chip: tuple[str, str] | None = None
    say: str | None = None

    @property
    def spoken(self) -> str:
        """What a rule-based answer says to the user: the natural sentence if there is one."""
        return self.say or self.text


@dataclass
class FactSet:
    facts: list[Fact] = field(default_factory=list)

    def add(self, *a, **kw) -> None:
        f = Fact(*a, **kw)
        # Any number written in the sentence the model sees is grounded by definition (e.g. the
        # "32 minuto" inside a status line), so the guard must accept it even if `values` forgot it.
        f.values = tuple(dict.fromkeys((*f.values, *numbers_in_text(f.text))))
        self.facts.append(f)

    def by_id(self) -> dict[str, Fact]:
        return {f.id: f for f in self.facts}

    def select(self, topics: set[str]) -> list[Fact]:
        return [f for f in self.facts if f.topic in topics]


_NUM = re.compile(r"\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?")


def numbers_in_text(text: str) -> tuple[float, ...]:
    return tuple(float(m.replace(",", "")) for m in _NUM.findall(text))


def peso(x: float | None) -> str:
    return "walang data" if x is None else f"₱{x:,.0f}"


def kwh(x: float) -> str:
    return f"{x:.1f} kWh"


def power(watts: float) -> str:
    return f"{watts / 1000:.1f} kW" if abs(watts) >= 1000 else f"{watts:g} W"


def and_list(items: list[str]) -> str:
    """'7PM, 8PM at 9PM'"""
    return items[0] if len(items) == 1 else ", ".join(items[:-1]) + " at " + items[-1]


def hour_label(h: int) -> str:
    suffix = "AM" if h < 12 else "PM"
    return f"{h % 12 or 12}{suffix}"


def peak_hours(device_id: str, days: int = 7) -> list[int]:
    """Hours of the day (0-23) with the most grid import over the last `days` days."""
    start = energy.local_midnight(energy.today() - timedelta(days=days))
    edges = [start + h * 3600 for h in range(days * 24 + 1)]
    by_hour = [0.0] * 24
    for i, b in enumerate(energy.buckets(device_id, edges)):
        by_hour[i % 24] += b["grid_import_kwh"]
    ranked = sorted(range(24), key=lambda h: by_hour[h], reverse=True)
    return sorted(h for h in ranked[:3] if by_hour[h] > 0)


def gather(device_id: str, settings: dict) -> FactSet:
    fs = FactSet()
    rate = settings["rate_php_per_kwh"]
    live = energy.live(device_id, settings)
    t = live["telemetry"]

    # ---- now
    fs.add("now.status", "now", f"Kalagayan ngayon: {live['status_line']}", say=live["status_line"])
    fs.add("now.online", "now", "Online ang Solaris device." if live["device"]["online"] else "OFFLINE ang Solaris device; luma na ang live data.",
           say=None if live["device"]["online"] else "Offline ang Solaris device ngayon, kaya luma na ang live data na ito.")
    if t:
        pv = t["pv_w"]
        fs.add("now.solar_w", "now", f"Solar ngayon: {power(pv)}", (pv,), ("Solar now", power(pv)),
               say=f"{power(pv)} ang kuha ng solar panels mo ngayon." if pv > 0 else "Walang kuha ang solar panels mo ngayon.")
        fs.add("now.load_w", "now", f"Gamit ng bahay ngayon: {power(t['load_w'])}", (t["load_w"],), ("Home use", power(t['load_w'])),
               say=f"{power(t['load_w'])} ang gamit ng bahay mo ngayon.")
        g = t["grid_w"]
        gtxt = f"kumukuha ng {power(g)} mula sa grid" if g > 0 else (f"nagbabalik ng {power(-g)} sa grid" if g < 0 else "walang kinukuha sa grid")
        gsay = (f"Kumukuha ka ngayon ng {power(g)} mula sa grid." if g > 0 else
                f"Nagbabalik ka ngayon ng {power(-g)} sa grid." if g < 0 else "Wala kang kinukuha sa grid ngayon.")
        fs.add("now.grid_w", "now", f"Grid ngayon: {gtxt}", (abs(g),), say=gsay)
        fs.add("now.battery_pct", "battery", f"Battery: {t['batt_soc']}%", (t["batt_soc"],), ("Battery", f"{t['batt_soc']}%"),
               say=f"Nasa {t['batt_soc']}% ang battery mo ngayon.")
        b = t["batt_w"]
        btxt = f"nagcha-charge ng {power(-b)}" if b < 0 else (f"ginagamit, {power(b)}" if b > 0 else "hindi gumagalaw")
        bsay = (f"Nagcha-charge ang battery mo ngayon, {power(-b)} ang pumapasok." if b < 0 else
                f"Ginagamit ngayon ang battery mo, {power(b)} ang lumalabas." if b > 0 else "Nakapahinga ang battery mo ngayon.")
        fs.add("now.battery_w", "battery", f"Battery ngayon: {btxt}", (abs(b),), say=bsay)
        fs.add("now.battery_kwh", "battery", f"Laki ng battery: {settings['battery_kwh']:g} kWh", (settings["battery_kwh"],),
               say=f"{settings['battery_kwh']:g} kWh ang laki ng battery mo.")
        fs.add("now.temp_c", "fault", f"Temperatura ng inverter: {t['inv_temp_c']}°C", (t["inv_temp_c"],),
               say=f"{t['inv_temp_c']}°C ang init ng inverter ngayon.")

    # ---- today / yesterday
    for key, d, word, na in (("today", energy.today(), "Ngayong araw", " na"), ("yesterday", energy.today() - timedelta(days=1), "Kahapon", "")):
        tot = energy.day_totals(device_id, d)
        cost = tot["grid_import_kwh"] * rate
        saved = energy.saved_kwh(tot) * rate
        ss = energy.self_sufficiency(tot)
        fs.add(f"{key}.solar_kwh", key, f"{word}, solar: {kwh(tot['pv_kwh'])}", (tot["pv_kwh"],),
               say=f"{word}, {kwh(tot['pv_kwh'])}{na} ang nagawa ng solar mo.")
        fs.add(f"{key}.load_kwh", key, f"{word}, gamit ng bahay: {kwh(tot['load_kwh'])}", (tot["load_kwh"],),
               say=f"{word}, {kwh(tot['load_kwh'])}{na} ang nagamit ng bahay mo.")
        fs.add(f"{key}.grid_kwh", key, f"{word}, kinuha sa grid: {kwh(tot['grid_import_kwh'])}", (tot["grid_import_kwh"],),
               say=f"{word}, {kwh(tot['grid_import_kwh'])}{na} ang kinuha mo sa grid.")
        fs.add(f"{key}.cost_php", key, f"{word}, gastos sa grid: {peso(cost)}", (cost,), (f"Cost {key}", peso(cost)),
               say=f"{word}, {peso(cost)}{na} ang nagastos mo sa kuryente mula sa grid.")
        fs.add(f"{key}.saved_php", key, f"{word}, natipid dahil sa solar at battery: {peso(saved)}", (saved,), (f"Saved {key}", peso(saved)),
               say=f"{word}, {peso(saved)}{na} ang natipid mo dahil sa solar at battery.")
        fs.add(f"{key}.self_sufficiency_pct", key, f"{word}, {ss:.0f}% ng kuryente ay hindi galing sa grid", (ss,),
               say=f"{word}, {ss:.0f}% ng kuryenteng ginamit mo ay hindi galing sa grid.")

    # ---- bill
    bill = energy.bill(device_id, settings)
    fs.add("bill.rate", "bill", f"Rate ng kuryente: ₱{rate:.2f} kada kWh", (rate,), say=f"₱{rate:.2f} kada kWh ang rate ng kuryente mo.")
    fs.add("bill.month_to_date_php", "bill", f"Bill ngayong buwan hanggang ngayon (nagastos na, hindi forecast): {peso(bill['month_to_date_php'])} ({kwh(bill['month_to_date_kwh'])} mula sa grid)",
           (bill["month_to_date_php"], bill["month_to_date_kwh"]), ("Bill this month", peso(bill["month_to_date_php"])),
           say=f"Sa ngayon, {peso(bill['month_to_date_php'])} na ang nagastos mo sa kuryente ngayong buwan "
               f"({kwh(bill['month_to_date_kwh'])} mula sa grid).")
    fs.add("bill.forecast_php", "bill", f"Forecast ng bill sa katapusan ng buwan: mga {peso(bill['forecast_php'])} "
           f"(mula {peso(bill['forecast_low_php'])} hanggang {peso(bill['forecast_high_php'])})",
           (bill["forecast_php"], bill["forecast_low_php"], bill["forecast_high_php"]), ("Forecast", peso(bill["forecast_php"])),
           say=f"Mga {peso(bill['forecast_php'])} ang inaasahang bill mo sa katapusan ng buwan"
               + ("." if peso(bill["forecast_low_php"]) == peso(bill["forecast_high_php"])
                  else f" (puwedeng {peso(bill['forecast_low_php'])} hanggang {peso(bill['forecast_high_php'])})."))
    lo, hi = bill["forecast_bracket_kwh"]
    level = f"lampas {lo:.0f} kWh" if hi is None else f"{lo + 1 if lo else 0:.0f} hanggang {hi:.0f} kWh"
    fs.add("bill.forecast_kwh", "bill", f"Forecast na kuha sa grid ngayong buwan: mga {kwh(bill['forecast_kwh'])}, "
           f"kaya nasa {level} na antas ng Meralco, mga ₱{bill['forecast_rate_php_per_kwh']:.2f} kada kWh",
           (bill["forecast_kwh"], bill["forecast_rate_php_per_kwh"]))
    how = ("SARIMA model ng araw-araw na kuha sa grid, natuto sa lingguhang pattern ng bahay mo" if bill["forecast_method"] == "sarima"
           else "average ng weekdays at weekends sa huling 28 araw")
    fs.add("bill.forecast_method", "bill", f"Paano ginawa ang forecast: {how}, inayos ayon sa panahon ng taon")
    days_left = bill["days_in_month"] - bill["days_elapsed"]
    fs.add("bill.days_left", "bill", f"Ika-{bill['days_elapsed']} araw na ng buwan; {days_left} araw pa ang natitira bago ito matapos",
           (bill["days_elapsed"], days_left), say=f"{days_left} araw pa bago matapos ang buwan.")
    if bill["last_month_php"] is not None:
        fs.add("bill.last_month_php", "bill", f"Bill noong nakaraang buwan: {peso(bill['last_month_php'])}", (bill["last_month_php"],), ("Last month", peso(bill["last_month_php"])),
               say=f"{peso(bill['last_month_php'])} ang bill mo noong nakaraang buwan.")
        p = bill["vs_last_month_pct"]
        fs.add("bill.vs_last_month_pct", "bill", f"Ang forecast ay {abs(p):.0f}% {'mas mababa' if p < 0 else 'mas mataas'} kaysa noong nakaraang buwan", (abs(p),),
               say=f"{abs(p):.0f}% {'mas mababa' if p < 0 else 'mas mataas'} ang inaasahang bill mo kaysa noong nakaraang buwan.")
    else:
        fs.add("bill.last_month_php", "bill", "Walang data para sa nakaraang buwan.", say="Wala pa akong data para sa nakaraang buwan.")
    fs.add("bill.savings_month_php", "savings", f"Natipid ngayong buwan dahil sa solar at battery: {peso(bill['savings_month_php'])}",
           (bill["savings_month_php"],), ("Saved this month", peso(bill["savings_month_php"])),
           say=f"Ngayong buwan, {peso(bill['savings_month_php'])} na ang natipid mo dahil sa solar at battery.")

    # ---- usage pattern
    peaks = peak_hours(device_id)
    if peaks:
        vals = tuple(float(x) for h in peaks for x in (h, h % 12 or 12))
        labels = [hour_label(h) for h in peaks]
        fs.add("usage.peak_hours", "usage", "Oras na pinakamaraming kinukuha sa grid (huling 7 araw): " + ", ".join(labels), vals,
               say=f"Sa huling 7 araw, pinakamarami kang kinukuha sa grid tuwing {and_list(labels)}.")
    week = energy.energy(device_id, "week")
    fs.add("week.grid_kwh", "usage", f"Huling 7 araw, kinuha sa grid: {kwh(week['totals']['grid_import_kwh'])}", (week["totals"]["grid_import_kwh"],),
           say=f"Sa huling 7 araw, {kwh(week['totals']['grid_import_kwh'])} ang kinuha mo sa grid.")
    fs.add("week.solar_kwh", "usage", f"Huling 7 araw, solar: {kwh(week['totals']['pv_kwh'])}", (week["totals"]["pv_kwh"],),
           say=f"Sa huling 7 araw, {kwh(week['totals']['pv_kwh'])} ang nagawa ng solar mo.")
    fs.add("week.self_sufficiency_pct", "usage", f"Huling 7 araw, {week['self_sufficiency_pct']:.0f}% ng kuryente ay hindi galing sa grid", (week["self_sufficiency_pct"],),
           say=f"Sa huling 7 araw, {week['self_sufficiency_pct']:.0f}% ng kuryenteng ginamit mo ay hindi galing sa grid.")

    # ---- brownout (always included when active: see router)
    bo = energy.brownout(device_id, settings)
    if bo["active"]:
        fs.add("brownout.active", "brownout", f"MAY BROWNOUT NGAYON, {bo['duration_min']} minuto na.", (bo["duration_min"],), ("Brownout", f"{bo['duration_min']} min"),
               say=f"May brownout ngayon, {bo['duration_min']} minuto na.")
        if bo["runtime_h"] is not None:
            fs.add("brownout.runtime_h", "brownout", f"Sa kasalukuyang gamit, aabot pa ng mga {bo['runtime_h']:g} oras ang battery", (bo["runtime_h"],), ("Battery runtime", f"{bo['runtime_h']:g} h"))
        fs.add("brownout.advice", "brownout", f"Payo sa brownout: {bo['advice']}", tuple(float(x) for x in (bo["load_w"] or 0, bo["batt_soc"] or 0, bo["runtime_h"] or 0)),
               say=bo["advice"])
    else:
        fs.add("brownout.active", "brownout", "Walang brownout ngayon.")
    n = bo["outages_this_month"]
    fs.add("brownout.count_month", "brownout", f"Bilang ng brownout ngayong buwan: {n}", (n,),
           say="Wala pang brownout ngayong buwan." if not n else "Isang beses pa lang nag-brownout ngayong buwan." if n == 1
           else f"{n} beses nang nag-brownout ngayong buwan.")

    # ---- solar + battery outlook (weather forecast; see app/outlook.py)
    o = outlook.outlook(device_id, settings)
    ob, obo = o["battery"], o["brownout"]
    src = "weather forecast" if o["source"] == "weather" else "nakaraang 14 araw (walang weather forecast ngayon)"
    typ = f" (karaniwan: {kwh(o['solar_typical_kwh'])})" if o["solar_typical_kwh"] else ""
    fs.add("outlook.solar_tomorrow_kwh", "outlook", f"Forecast ng solar bukas: mga {kwh(o['solar_tomorrow_kwh'])}{typ}, batay sa {src}",
           (o["solar_tomorrow_kwh"],), ("Solar tomorrow", kwh(o["solar_tomorrow_kwh"])))
    fs.add("outlook.solar_today_kwh", "outlook", f"Inaasahang kabuuang solar ngayong araw (kasama na ang nakuha na): mga {kwh(o['solar_today_kwh'])}",
           (o["solar_today_kwh"],))
    if ob["soc_pct"] is not None:
        if ob["reserve_ts"] is not None:
            fs.add("outlook.battery_reserve", "outlook", f"Sa forecast, aabot sa {ob['reserve_pct']}% ang battery {when(ob['reserve_ts'])}; grid na ang gagamitin pagkatapos")
        else:
            fs.add("outlook.battery_reserve", "outlook", f"Sa forecast, hindi bababa sa {ob['reserve_pct']}% ang battery sa susunod na 48 oras")
        if ob["full_ts"] is not None:
            fs.add("outlook.battery_full", "outlook", f"Sa forecast, mapupuno ang battery {when(ob['full_ts'])}")
        elif ob["tomorrow_max_soc_pct"] is not None:
            fs.add("outlook.battery_full", "outlook", f"Sa forecast, hindi mapupuno ang battery sa susunod na 48 oras; pinakamataas bukas: {ob['tomorrow_max_soc_pct']:.0f}%")
    if obo:
        # During a brownout this is the real projection, so it goes with the always-included brownout facts.
        topic = "brownout" if obo["active"] else "outlook"
        lead = "Sa brownout na ito" if obo["active"] else "Kung mag-brownout ngayon"
        if obo["lasts_until_ts"] is None:
            fs.add("outlook.brownout_until", topic, f"{lead}, kasama ang forecast na araw at karaniwang gamit, kakayanin ng battery ang susunod na 48 oras")
        else:
            fs.add("outlook.brownout_until", topic, f"{lead}, kasama ang forecast na araw at karaniwang gamit, mauubos ang battery {when(obo['lasts_until_ts'])} "
                   f"(mga {obo['hours']:g} oras mula ngayon)", (obo["hours"],), ("Battery lasts", f"{obo['hours']:g} h"))
    fs.add("outlook.advice", "outlook", f"Payo tungkol sa araw at battery: {o['advice']}", say=o["advice"])

    # ---- fault
    if t and t["fault_code"]:
        f = explain_fault(t["fault_code"])
        fs.add("fault.active", "fault", f"MAY FAULT ang inverter, code {t['fault_code']}: {f['title']}. {f['message']}", (t["fault_code"],), ("Fault", str(t["fault_code"])),
               say=f"May problema ang inverter mo (fault code {t['fault_code']}): {f['title'].lower()}. {f['message']}")
    else:
        fs.add("fault.active", "fault", "Walang fault ang inverter ngayon.", say="Walang problema ang inverter mo ngayon.")

    # ---- alerts
    unread = db.list_alerts(unread_only=True, limit=5)
    if unread:
        titles = "; ".join(a["title"] for a in unread[:3])
        fs.add("alerts.unread", "alerts", f"May {db.unread_count()} hindi pa nababasang alert. Pinakabago: " + titles, (db.unread_count(),),
               say=f"May {db.unread_count()} alert kang hindi pa nababasa. Pinakabago: {titles}.")
    else:
        fs.add("alerts.unread", "alerts", "Walang bagong alert.", say="Wala kang bagong alert.")

    fs.add("user.name", "now", f"Pangalan ng user: {settings['user_name']}")
    return fs
