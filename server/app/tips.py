"""Solar tips: when and how to run the house on the sun instead of the grid, from this home's own data.

  now      live reading: the sun has more than the house and a full battery can take, or the grid is
           running the house while a sunny stretch is coming
  today    the next sunniest 3 hours (outlook: forecast solar minus typical use), a cloudy day tomorrow
  habit    the last 30 days (upgrade.stats): solar sent to the grid while the nights run on it, grid bought
           while the sun is up, evenings much heavier than midday
  general  one evergreen tip a day, so the list is never empty
Plus this month's impact: kWh made by the panels and the CO₂ the grid would have emitted for it.
Every number is computed here; the app and Mira only show it.
"""
import time
from datetime import timedelta

from . import config, db, energy, outlook, upgrade

SURPLUS_W = 800            # sun beyond what the house uses, worth telling the user to use it now
FULL_SOC = 90              # battery this full can't take much of the surplus any more
GRID_NOW_W = 300           # the house is clearly running on the grid
WINDOW_H = 3               # length of the "best time for heavy appliances" window
WINDOW_MIN_KWH = 1.0       # less surplus than this in the best window = not worth a tip
HABIT_MIN_KWH = 1.0        # daily kWh before a habit is worth a tip
EVENING = range(18, 22)    # 6-10 PM
MIDDAY = range(11, 15)     # 11 AM-3 PM
TREE_KG_CO2_YEAR = 22.0    # CO₂ one grown tree takes up in a year (common rule of thumb)
MAX_TIPS = 6

GENERAL = [
    ("Linisin ang solar panels",
     "Ang alikabok, dahon at dumi ng ibon sa panels ay nagpapababa ng solar mo. Banlawan ng tubig tuwing ilang "
     "buwan, sa umaga o hapon, hindi sa tanghaling tapat."),
    ("Gamitin ang timer",
     "Lagyan ng timer o smart plug ang water pump at washing machine para tumakbo sila sa tanghali kahit wala ka "
     "sa bahay. Araw ang gagamitin nila, hindi grid."),
    ("Piliin ang inverter type",
     "Kapag bibili ng bagong aircon o ref, piliin ang inverter type. Mas mahina ang kuha nito, kaya mas maraming "
     "oras na kaya ng araw at battery."),
    ("I-charge sa tanghali",
     "I-charge ang e-bike, power bank, laptop at cellphone sa tanghali, hindi sa gabi. Diretso galing sa araw, "
     "at may natitira pang battery para sa gabi."),
    ("Magluto gamit ang araw",
     "Kapag tanghali at maaraw, gamitin ang rice cooker o induction stove sa halip na LPG. Libre ang kuryente "
     "galing sa araw, at mas kaunti ang usok."),
    ("Patayin ang naka-standby",
     "Bunutin o patayin ang TV, charger at iba pang naka-standby sa gabi. Bawat watt na natipid sa gabi ay "
     "dagdag na oras ng battery bago bumalik sa grid."),
]


def _clock(h: int) -> str:
    return f"{h % 12 or 12}{'AM' if h < 12 else 'PM'}"


def _kw(w: float) -> str:
    return f"{w / 1000:.1f} kW" if abs(w) >= 1000 else f"{w:.0f} W"


def _peso(x: float) -> str:
    return f"₱{x:,.0f}"


def _tip(id_: str, kind: str, title: str, body: str, evidence=(), savings=None) -> dict:
    return {"id": id_, "kind": kind, "title": title, "body": body,
            "evidence": [{"label": k, "value": v} for k, v in evidence],
            "savings_php_month": round(savings) if savings else None}


# ----------------------------------------------------------------- inputs --
def best_window(hours: list[dict], now: float) -> dict | None:
    """The WINDOW_H hours with the most solar left over after typical use, today if there's still one worth
    using, else tomorrow. `hours` = /api/outlook hours (hourly kWh). None if no window has WINDOW_MIN_KWH."""
    today = energy.to_local(int(now)).date()
    for day, name in ((today, "today"), (today + timedelta(days=1), "tomorrow")):
        idx = [i for i, h in enumerate(hours) if energy.to_local(h["ts"]).date() == day]
        best = None
        for j in range(len(idx) - WINDOW_H + 1):
            run = idx[j:j + WINDOW_H]
            if run[-1] - run[0] != WINDOW_H - 1:
                continue
            surplus = sum(max(0.0, hours[i]["pv_kwh"] - hours[i]["load_kwh"]) for i in run)
            if best is None or surplus > best[0] + 1e-9:
                best = (surplus, run)
        if best and best[0] >= WINDOW_MIN_KWH:
            s, run = best
            return {"start_ts": hours[run[0]]["ts"], "end_ts": hours[run[-1]]["ts"] + 3600,
                    "surplus_kwh": round(s, 1), "day": name}
    return None


def load_shape(device_id: str) -> dict | None:
    """Average kWh per hour, weekdays, in the evening and at midday (outlook.profiles, last 28 days)."""
    lp = outlook.profiles(device_id)["load"]
    eve = [lp[(False, h)] for h in EVENING if (False, h) in lp]
    mid = [lp[(False, h)] for h in MIDDAY if (False, h) in lp]
    if len(eve) < len(EVENING) or len(mid) < len(MIDDAY):
        return None
    return {"evening_kwh_h": sum(eve) / len(eve), "midday_kwh_h": sum(mid) / len(mid)}


def impact(device_id: str) -> dict | None:
    """This month's solar and the CO₂ the grid would have emitted for it. None before any solar."""
    d = energy.today()
    t = energy.totals(device_id, energy.local_midnight(d.replace(day=1)), int(time.time()))
    if t["pv_kwh"] <= 0.05:
        return None
    co2 = t["pv_kwh"] * config.GRID_CO2_KG_PER_KWH
    return {"month": f"{d:%Y-%m}", "solar_kwh": round(t["pv_kwh"], 1),
            "clean_share_pct": energy.self_sufficiency(t), "co2_avoided_kg": round(co2, 1),
            "trees": round(co2 / TREE_KG_CO2_YEAR)}


# ------------------------------------------------------------------ rules --
def build(*, now: float, live: dict | None, window: dict | None, solar_tomorrow: float | None,
          solar_typical: float | None, usage: dict | None, shape: dict | None, rate: float) -> list[dict]:
    """All tips that apply, most urgent first, at most MAX_TIPS. Pure: every input is passed in."""
    from ai.prompts import CLOUDY_RATIO

    hour = energy.to_local(int(now)).hour
    out: list[dict] = []
    win_text = None
    if window:
        a, b = energy.to_local(window["start_ts"]).hour, energy.to_local(window["end_ts"]).hour
        when = "bukas" if window["day"] == "tomorrow" else ("ngayon" if window["start_ts"] <= now else "mamaya")
        win_text = f"{when}, {_clock(a)} hanggang {_clock(b)}"

    # --- now: the live reading
    surplus_now = False
    if live and live["grid_on"] and not live["fault_code"]:
        spare = live["pv_w"] - live["load_w"]
        if spare >= SURPLUS_W and (live["batt_soc"] >= FULL_SOC or live["grid_w"] < -50):
            surplus_now = True
            where = (f"puno na ang battery ({live['batt_soc']}%)" if live["batt_soc"] >= FULL_SOC
                     else f"{_kw(-live['grid_w'])} ang napupunta lang sa grid")
            out.append(_tip(
                "surplus_now", "now", "Sobra ang araw ngayon: gamitin na",
                f"Gumagawa ang panels mo ng {_kw(live['pv_w'])} pero {_kw(live['load_w'])} lang ang gamit ng bahay, "
                f"at {where}. Ngayon na ang oras para sa laba, plantsa, pag-charge o pag-pump ng tubig: "
                "galing sa araw ang kuryente, hindi sa grid.",
                [("Solar now", _kw(live["pv_w"])), ("Home use now", _kw(live["load_w"])),
                 ("Battery", f"{live['batt_soc']}%")]))
        elif live["grid_w"] >= GRID_NOW_W and win_text and window["start_ts"] > now:
            out.append(_tip(
                "grid_now", "now", "Grid ang gamit mo ngayon",
                f"Kumukuha ang bahay ng {_kw(live['grid_w'])} mula sa grid ngayon. Kung kaya pang hintayin ang "
                f"laba, plantsa o pag-charge, gawin ito {win_text}, kapag araw na ang magpapagana.",
                [("From grid now", _kw(live["grid_w"])), ("Battery", f"{live['batt_soc']}%")]))

    # --- today: forecast
    if window and not (surplus_now and window["start_ts"] <= now):
        title = ("Pinakamaaraw ngayon" if window["start_ts"] <= now
                 else f"Pinakamaaraw {'bukas' if window['day'] == 'tomorrow' else 'mamaya'}")
        out.append(_tip(
            "best_window", "today", f"{title}: {_clock(energy.to_local(window['start_ts']).hour)}"
            f"–{_clock(energy.to_local(window['end_ts']).hour)}",
            f"Mga {window['surplus_kwh']:.1f} kWh na sobrang solar ang inaasahan {win_text}. Doon ilagay ang "
            "washing machine, plantsa, rice cooker at pag-charge para araw ang gamitin, hindi grid o battery.",
            [("Extra solar", f"{window['surplus_kwh']:.1f} kWh")]))
    if solar_typical and solar_tomorrow is not None and solar_tomorrow < CLOUDY_RATIO * solar_typical and 6 <= hour < 15:
        out.append(_tip(
            "cloudy_tomorrow", "today", "Maulap bukas: unahin na ngayon",
            f"Mga {solar_tomorrow:.0f} kWh lang ang solar bukas, kumpara sa karaniwang {solar_typical:.0f} kWh. "
            "Habang maaraw pa ngayon, gawin na ang laba, plantsa at iba pang mabibigat na gawain.",
            [("Solar tomorrow", f"{solar_tomorrow:.0f} kWh"), ("Typical day", f"{solar_typical:.0f} kWh")]))

    # --- habit: the last 30 days
    habits = []
    if usage:
        shift = min(usage["export_kwh_day"], usage["night_import_kwh_day"])
        if shift >= HABIT_MIN_KWH:
            habits.append(_tip(
                "shift_to_day", "habit", "Ilipat sa tanghali ang mabibigat na gawain",
                f"Araw-araw, mga {usage['export_kwh_day']:.1f} kWh ng solar mo ang napupunta lang sa grid, habang "
                f"{usage['night_import_kwh_day']:.1f} kWh ang binibili mo tuwing gabi. Ang laba, plantsa, pag-init "
                f"ng tubig at pag-charge na nailipat sa tanghali ay makakatipid ng hanggang {_peso(shift * rate * 30)} "
                "kada buwan.",
                [("Solar sent to grid", f"{usage['export_kwh_day']:.1f} kWh/day"),
                 ("Grid at night", f"{usage['night_import_kwh_day']:.1f} kWh/day")],
                savings=shift * rate * 30))
        if usage["day_import_kwh_day"] >= HABIT_MIN_KWH:
            habits.append(_tip(
                "spread_loads", "habit", "Huwag sabay-sabayin ang malalaking appliance",
                f"Kahit may araw, {usage['day_import_kwh_day']:.1f} kWh pa rin ang kinukuha mo sa grid kada araw. "
                "Kadalasan ito ay dahil sabay-sabay tumatakbo ang aircon, plantsa, rice cooker at water heater. "
                "Paghiwa-hiwalayin sila sa tanghali para kaya ng panels mo.",
                [("Grid while sunny", f"{usage['day_import_kwh_day']:.1f} kWh/day")],
                savings=None))
    if shape and usage and usage["export_kwh_day"] >= HABIT_MIN_KWH \
            and shape["evening_kwh_h"] >= 0.8 and shape["evening_kwh_h"] >= 1.5 * shape["midday_kwh_h"]:
        habits.append(_tip(
            "precool", "habit", "Palamigin ang bahay habang may araw",
            f"Pinakamalakas ang gamit mo mula 6PM hanggang 10PM (mga {shape['evening_kwh_h']:.1f} kWh kada oras), "
            f"pero {shape['midday_kwh_h']:.1f} kWh lang sa tanghali. Buksan ang aircon sa hapon (2PM hanggang 5PM) "
            "habang araw ang nagpapagana, isara ang kurtina, at mas mahina na ang kailangan sa gabi.",
            [("Evening use", f"{shape['evening_kwh_h']:.1f} kWh/h"), ("Midday use", f"{shape['midday_kwh_h']:.1f} kWh/h")]))
    habits.sort(key=lambda t: -(t["savings_php_month"] or 0))
    out += habits

    # --- general: one a day
    title, body = GENERAL[energy.to_local(int(now)).date().toordinal() % len(GENERAL)]
    out = out[:MAX_TIPS - 1]
    out.append(_tip("general", "general", title, body))
    for i, t in enumerate(out, 1):
        t["priority"] = i
    return out


def tips(device_id: str, settings: dict) -> dict:
    """The /api/tips response."""
    now = time.time()
    t = db.latest_telemetry(device_id)
    live = t if t is not None and energy.device_info(device_id, t)["online"] else None
    o = outlook.outlook(device_id, settings)
    window = best_window(o["hours"], now)
    up = upgrade.recommend(device_id, settings)
    return {
        "generated_ts": int(now),
        "best_window": window,
        "impact": impact(device_id),
        "tips": build(now=now, live=live, window=window, solar_tomorrow=o["solar_tomorrow_kwh"],
                      solar_typical=o["solar_typical_kwh"], usage=up["usage"], shape=load_shape(device_id),
                      rate=settings["rate_php_per_kwh"]),
    }
