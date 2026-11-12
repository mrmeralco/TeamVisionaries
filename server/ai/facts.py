"""FACTS: the only things the AI is allowed to say.

Facts come from SQLite history and, in mock mode, the app's simulated current readings. Each one has:
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

from app import config, db, energy, household, meter, mock, outlook, projection, solar_plan, upgrade

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
    measured_ts: int | None = None   # when the live reading behind the now.* facts was taken

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


METER_ONLY = "setup.meter_only"   # present = a home without solar or battery (guard.py and service.py check it)


def gather(device_id: str, settings: dict) -> FactSet:
    """Facts for this home. A meter-only home (settings `setup`) gets no solar, battery, inverter, outlook or
    system-check facts at all, so Mira has nothing about solar to say; meter facts take their place."""
    fs = FactSet()
    rate = settings["rate_php_per_kwh"]
    solar = energy.has_solar(settings)
    live = mock.load("live") if config.MOCK else energy.live(device_id, settings)
    t = live["telemetry"]
    mr = live["meter"]
    fs.measured_ts = t["ts"] if t else (mr["ts"] if mr else None)

    # ---- now
    if not solar:
        # Worded without "solar"/"battery": the model tends to repeat a fact's words, and guard.py rejects a
        # meter-only answer that brings them up when the user didn't.
        fs.add(METER_ONLY, "now", "Smart meter lang ang binabasa ng Solaris sa bahay na ito; lahat ng kuryente ay "
               "galing sa grid (Meralco).",
               say="Smart meter lang ang binabasa ko sa bahay mo, kaya lahat ng kuryente mo ay galing sa grid.")
    fs.add("now.status", "now", f"Kalagayan ngayon: {live['status_line']}", say=live["status_line"])
    fs.add("now.online", "now", "Online ang Solaris device." if live["device"]["online"] else "OFFLINE ang Solaris device; luma na ang live data.",
           say=None if live["device"]["online"] else "Offline ang Solaris device ngayon, kaya luma na ang live data na ito.")
    if not solar and mr:
        p = round(max(0.0, mr["power_w"]))
        fs.add("now.load_w", "now", f"Gamit ng bahay ngayon (lahat mula sa grid): {power(p)}", (p,),
               ("Home use", power(p)), say=f"{power(p)} ang gamit ng bahay mo ngayon, lahat mula sa grid.")
    if mr:
        v = round(mr["voltage_v"])
        fs.add("now.voltage_v", "meter", f"Boltahe ngayon ayon sa meter: {v} V", (v,), ("Voltage", f"{v} V"),
               say=f"{v} V ang boltahe ng kuryente mo ngayon.")
        if mr.get("pf") is not None:
            fs.add("now.power_factor", "meter", f"Power factor ngayon ayon sa meter: {mr['pf']:.2f}", (mr["pf"],),
                   say=f"{mr['pf']:.2f} ang power factor ngayon.")
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
        tot = energy.day_totals(device_id, d, energy.flow_source(settings))
        cost = tot["grid_import_kwh"] * rate
        saved = energy.saved_kwh(tot) * rate
        ss = energy.self_sufficiency(tot)
        if not solar:
            fs.add(f"{key}.load_kwh", key, f"{word}, gamit ng bahay (lahat mula sa grid): {kwh(tot['load_kwh'])}", (tot["load_kwh"],),
                   say=f"{word}, {kwh(tot['load_kwh'])}{na} ang nagamit ng bahay mo.")
            fs.add(f"{key}.cost_php", key, f"{word}, gastos sa kuryente: {peso(cost)}", (cost,), (f"Cost {key}", peso(cost)),
                   say=f"{word}, {peso(cost)}{na} ang nagastos mo sa kuryente.")
            continue
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
           (bill["forecast_php"], bill["forecast_low_php"], bill["forecast_high_php"]), ("Bill forecast", peso(bill["forecast_php"])),
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
    season = ("inayos ayon sa panahon (init at araw) gamit ang simulation ng solar at battery mo" if solar
              else "inayos ayon sa init ng panahon (mas maraming aircon sa tag-init)")
    src = ". Galing sa meter ang kWh, ang parehong sukat na sinisingil ng Meralco" if bill["grid_source"] == "meter" else ""
    fs.add("bill.forecast_method", "bill", f"Paano ginawa ang forecast: {how}, sa antas ng kuha mo sa grid sa huling "
           f"dalawang linggo, {season}{src}")
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
    if solar:
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
    if solar:
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

    # ---- smart meter (app/meter.py): Meralco level, always-on use, voltage, the meter's register
    if mr:
        _meter_facts(fs, mock.load("meter") if config.MOCK else meter.info(device_id, settings))
    if solar:   # a meter-only home has no sun, battery or inverter to talk about
        _outlook_facts(fs, device_id, settings)
        _fault_fact(fs, t)
    _alerts_fact(fs)
    _projection_facts(fs, device_id, settings, solar)
    if solar:
        _upgrade_facts(fs, device_id, settings)
    else:
        _solar_plan_facts(fs, device_id, settings)

    # ---- household profile: routine, is anyone home, new appliance-sized loads (app/household.py)
    try:
        hh = mock.load("household") if config.MOCK else household.household(device_id, settings)
    except Exception:                       # extra, like the system check; never let it break chat
        hh = None
    if hh:
        n = hh["now"]
        states = {"active": "May tao", "asleep": "Tulog", "away": "Walang tao", "quiet": "Tahimik", "unknown": "Hindi alam"}
        fs.add("household.now", "household", f"Sa bahay ngayon (huling 30 minuto ng gamit): {n['text']}",
               chip=("Sa bahay ngayon", states[n["state"]]), say=n["text"])
        r = hh["routine"]["weekday"] or hh["routine"]["weekend"]
        if r:
            parts = []
            if r["wake_hour"] is not None:
                parts.append(f"gumigising mga {hour_label(r['wake_hour'])}")
            if r["away"]:
                parts.append(f"walang tao mula {hour_label(r['away']['start_hour'])} hanggang "
                             f"{hour_label(r['away']['end_hour'] % 24)}")
            if r["sleep_hour"] is not None:
                parts.append(f"natutulog mga {hour_label(r['sleep_hour'])}")
            parts.append(f"pinakamalakas ang gamit mga {hour_label(r['peak_hour'])}")
            kind = "tuwing weekday" if hh["routine"]["weekday"] else "tuwing weekend"
            line = f"{hh['archetype']['label']}. Karaniwan {kind}: {and_list(parts)}"
            fs.add("household.routine", "household", f"Routine ng bahay (huling {hh['days_used']} araw, mula sa gamit "
                   f"ng kuryente): {line}", say=f"{line}.")
        if hh["baseload"]:
            b = hh["baseload"]
            fs.add("household.baseload", "household",
                   f"Laging-nakabukas na gamit (ref, standby, router): mga {b['watts']} W, {b['kwh_month']:.0f} kWh kada "
                   f"buwan ({b['share_pct']:.0f}% ng lahat ng gamit), hanggang {peso(b['php_month'])} kada buwan",
                   (b["watts"], b["php_month"]), ("Laging nakabukas", f"{b['watts']} W"),
                   say=f"Mga {b['watts']} W ang laging nakabukas sa bahay mo, araw at gabi: mga {b['kwh_month']:.0f} kWh "
                       f"kada buwan, hanggang {peso(b['php_month'])}.")
        for i, nl in enumerate(hh["new_loads"]):
            # topic "usage": "Bakit tumaas ang bill?" gets it too (router adds usage to bill questions).
            fs.add("household.new_load" + ("" if i == 0 else str(i + 1)), "usage",
                   f"Posibleng bagong appliance: {nl['text']}", (nl["added_w"], nl["kwh_day"], nl["php_month"]),
                   ("Bagong gamit?", power(nl["added_w"])), say=nl["text"])

    fs.add("user.name", "now", f"Pangalan ng user: {settings['user_name']}")
    return fs


def _outlook_facts(fs: FactSet, device_id: str, settings: dict) -> None:
    # ---- solar + battery outlook (weather forecast; see app/outlook.py)
    o = mock.load("outlook") if config.MOCK else outlook.outlook(device_id, settings)
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


def _fault_fact(fs: FactSet, t: dict | None) -> None:
    # ---- fault
    if t and t["fault_code"]:
        f = explain_fault(t["fault_code"])
        fs.add("fault.active", "fault", f"MAY FAULT ang inverter, code {t['fault_code']}: {f['title']}. {f['message']}", (t["fault_code"],), ("Fault", str(t["fault_code"])),
               say=f"May problema ang inverter mo (fault code {t['fault_code']}): {f['title'].lower()}. {f['message']}")
    else:
        fs.add("fault.active", "fault", "Walang fault ang inverter ngayon.", say="Walang problema ang inverter mo ngayon.")


def _alerts_fact(fs: FactSet) -> None:
    # ---- alerts
    unread = db.list_alerts(unread_only=True, limit=5)
    if unread:
        titles = "; ".join(a["title"] for a in unread[:3])
        fs.add("alerts.unread", "alerts", f"May {db.unread_count()} hindi pa nababasang alert. Pinakabago: " + titles, (db.unread_count(),),
               say=f"May {db.unread_count()} alert kang hindi pa nababasa. Pinakabago: {titles}.")
    else:
        fs.add("alerts.unread", "alerts", "Walang bagong alert.", say="Wala kang bagong alert.")


def _projection_facts(fs: FactSet, device_id: str, settings: dict, solar: bool) -> None:
    # ---- bill in the next months (app/projection.py, cached per day). Only this month is a forecast.
    try:
        proj = projection.project(device_id, settings)
    except Exception:                       # extra; never let it break chat
        proj = None
    if proj:
        months = [m for m in proj["months"] if m["kind"] == "projection"]
        last = months[-1]["label"] if months else None
        reach = (f"hanggang {last} lang ({projection.MAX_MONTHS} buwan pagkatapos ng buwang ito)" if last
                 else f"wala pa (kailangan ng {projection.MIN_DAYS} araw ng data)")
        why = (("nagbabago ang panahon (araw at ulan)" if solar else "nagbabago ang init ng panahon")
               + ", ang gamit sa bahay at ang rate ng Meralco bawat buwan, kaya lumalapad ang range bawat buwan")
        fs.add("projection.limits", "projection",
               f"Limitasyon ng projection: ang buwang ito lang ang forecast. Ang mga susunod na buwan ay projection "
               f"lang (tantiya), hindi kasing-maaasahan ng forecast, dahil {why}. Kaya ng Solaris: {reach}. Lampas doon, "
               "masyadong malapad na ang range kaya hindi na ito ibinibigay.",
               say=f"Ang buwang ito lang ang forecast; ang mga susunod na buwan ay tantiya lang at hindi gaanong maaasahan, "
                   f"dahil nagbabago ang panahon, gamit at rate ng Meralco. Kaya kong i-project {reach}; lampas doon, "
                   "masyadong malapad na ang range.")
        for m in months:
            k = m["months_ahead"]
            fs.add(f"projection.m{k}", "projection",
                   f"Projection (tantiya lang, hindi sigurado) ng bill sa {m['label']}: mga {peso(m['bill_php'])} "
                   f"(puwedeng {peso(m['low_php'])} hanggang {peso(m['high_php'])}, ±{m['range_pct']}%), kung pareho ang "
                   f"gamit mo nitong huling {proj['basis_days']} araw; mga "
                   + (f"{m['solar_kwh']:.0f} kWh na solar at " if solar else "")
                   + f"{m['load_kwh']:.0f} kWh na gamit sa buwang iyon, sa rate ngayon",
                   (m["bill_php"], m["low_php"], m["high_php"]), (m["label"], peso(m["bill_php"])),
                   say=f"Tantiya lang: mga {peso(m['bill_php'])} ang bill sa {m['label']} (puwedeng {peso(m['low_php'])} "
                       f"hanggang {peso(m['high_php'])}), kung pareho ang gamit mo at ang rate ngayon.")


SOLAR_PLAN_TOPIC = "solar_plan"   # only asked-for: never in a vague question's prompt (router.py)


def _solar_plan_facts(fs: FactSet, device_id: str, settings: dict) -> None:
    """A home without solar: how big a setup its use needs (app/solar_plan.py). The only solar facts a
    meter-only home gets, and only for questions about getting solar. Sponsors are never facts."""
    try:
        # Mock mode: the same plan the app's "Go solar" card shows (examples/solar_plan_meter_only.json).
        p = mock.load("solar_plan") if config.MOCK else solar_plan.plan(device_id, settings)
    except Exception:                       # extra, like the system check; never let it break chat
        return
    if p["has_solar"]:
        return
    if not p["options"]:
        fs.add("solar_plan.not_ready", SOLAR_PLAN_TOPIC, p["headline"], say=p["headline"])
        return
    u = p["usage"]
    for o in p["options"]:
        fid = "solar_plan.recommended" if o["recommended"] else "solar_plan.alternative"
        batt = f", {o['battery_kwh']:g} kWh na battery" if o["battery_kwh"] else ", walang battery"
        backup = f" Kaya nitong buhayin ang bahay nang mga {o['backup_hours']:g} oras sa brownout." if o["backup_hours"] else ""
        pay = f"mga {o['payback_years']:g} taon" if o["payback_years"] else "hindi matantiya"
        intro = ("Mungkahing solar para sa bahay na ito" if o["recommended"] else "Ibang opsyon")
        fs.add(fid, SOLAR_PLAN_TOPIC,
               f"{intro} (tantiya lang; wala pang solar ang bahay; mula sa gamit nitong huling {p['days']} araw, mga "
               f"{u['kwh_day']:g} kWh kada araw, {u['night_share_pct']}% sa gabi): {o['title']}: {o['pv_kwp']:g} kWp "
               f"({o['panels']} panels na {o['panel_w']} W, mga {o['roof_m2']} m² ng bubong), {o['inverter_kw']:g} kW na "
               f"inverter{batt}. Sasagutin nito ang mga {o['covers_pct']}% ng gamit. Tantiyang tipid: "
               f"{peso(o['savings_php_month'])} kada buwan (bill mula {peso(o['bill_before_php_month'])} pababa sa "
               f"{peso(o['bill_after_php_month'])}); tantiyang gastos: {peso(o['cost_php'])}; balik-puhunan: {pay}."
               f"{backup} {o['why']}",
               # values[0] = monthly savings, [1] = installed cost: semantics.py checks "tipid" vs "gastos".
               (o["savings_php_month"], o["cost_php"], o["payback_years"] or 0),
               ("Suggested solar" if o["recommended"] else "Other option", f"{o['pv_kwp']:g} kWp"),
               say=f"{'Para sa gamit mo' if o['recommended'] else 'Puwede rin'}: {o['title'].lower()}, "
                   f"{o['pv_kwp']:g} kWp ({o['panels']} panels){batt}. Tantiyang tipid {peso(o['savings_php_month'])} "
                   f"kada buwan, gastos mga {peso(o['cost_php'])}, balik-puhunan {pay}.{backup}")
    fs.add("solar_plan.limits", SOLAR_PLAN_TOPIC,
           f"Paano tinantiya: karaniwang araw sa Pilipinas ({p['yield_kwh_per_kwp_day']:g} kWh kada kWp kada araw) at ang "
           "gamit ng bahay kada oras; presyo ay tantiya lang. Installer ang susukat ng bubong, lilim at wiring at "
           "magbibigay ng eksaktong quote.",
           say="Tantiya lang ito mula sa gamit mo at karaniwang araw sa Pilipinas; installer ang magbibigay ng eksaktong "
               "quote pagkatapos sukatin ang bubong.")


def _upgrade_facts(fs: FactSet, device_id: str, settings: dict) -> None:
    # ---- system check: does the setup still fit this household? (app/upgrade.py, cached)
    try:
        up = upgrade.recommend(device_id, settings)
    except Exception:                       # the check is extra; never let it break chat
        up = None
    if up:
        sysd = up["system"]
        fs.add("upgrade.system", "upgrade", f"System mo ngayon: {sysd['pv_kwp']:g} kWp na solar, {sysd['battery_kwh']:g} kWh na battery, "
               f"{sysd['inverter_kw']:g} kW na inverter",
               say=f"Ang system mo ngayon: {sysd['pv_kwp']:g} kWp na solar, {sysd['battery_kwh']:g} kWh na battery at "
                   f"{sysd['inverter_kw']:g} kW na inverter.")
        days = (up["usage"] or {}).get("days")
        fs.add("upgrade.verdict", "upgrade",
               (f"System check (huling {days} araw): " if days else "System check: ") + up["headline"], say=up["headline"])
        for r in up["recommendations"]:
            money = ""
            if r["savings_php_month"]:
                money += f" Tantiyang tipid: {peso(r['savings_php_month'])} kada buwan."
            if r["cost_php"]:
                money += f" Tantiyang gastos: {peso(r['cost_php'])}."
            if r["payback_years"]:
                money += f" Balik-puhunan: mga {r['payback_years']:g} taon."
            # values[0] = monthly savings, [1] = installed cost (0 = none): semantics.py checks "tipid" vs "gastos".
            fs.add(f"upgrade.{r['id']}", "upgrade", f"Rekomendasyon: {r['title']} ({r['add']}). {r['reason']}{money}",
                   (r["savings_php_month"] or 0, r["cost_php"] or 0, r["payback_years"] or 0),
                   (r["title"], r["add"]),
                   say=f"{r['title']} ({r['add']}): {r['reason']}{money}")

        # What is NOT needed, so "Dapat ko bang dagdagan ang panels?" has a grounded answer too.
        if up["enough_data"]:
            names = {"battery": "dagdag na battery", "solar": "dagdag na solar panels", "inverter": "mas malaking inverter"}
            recommended = {r["id"] for r in up["recommendations"]}
            skip = [n for k, n in names.items() if k not in recommended]
            if skip:
                listed = ", ".join(skip[:-1]) + (" at " if len(skip) > 1 else "") + skip[-1]
                fs.add("upgrade.not_needed", "upgrade", f"Hindi kailangan ngayon ayon sa system check: {listed}",
                       say=f"Ayon sa system check, hindi pa kailangan ang {listed}.")


def _meter_facts(fs: FactSet, info: dict) -> None:
    """One fact per meter insight (its Taglish body already holds the exact numbers), topic "meter".
    service.py adds the meter topic to bill, savings and usage questions."""
    ids = {"tier": "meter.tier", "tier_drop": "meter.tier", "tier_near": "meter.tier", "base_load": "meter.base_load",
           "voltage": "meter.voltage", "power_factor": "meter.power_factor", "reading": "meter.reading"}
    chips = {"meter.tier": ("Forecast use", lambda: f"{info['tier']['forecast_kwh']:.0f} kWh"),
             "meter.base_load": ("Always on", lambda: f"{info['usage']['base_w']} W"),
             "meter.reading": ("Meter reading", lambda: f"{info['reading']['import_kwh']:,.1f} kWh")}
    for ins in info["insights"]:
        fid = ids.get(ins["id"])
        if fid is None or fid in fs.by_id():
            continue
        chip = (chips[fid][0], chips[fid][1]()) if fid in chips else None
        fs.add(fid, "meter", f"{ins['title']}. {ins['body']}", chip=chip, say=ins["body"])
