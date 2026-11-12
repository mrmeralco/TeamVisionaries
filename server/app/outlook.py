"""Solar + battery outlook for the next 48 h: will the sun refill the battery, and when does it run out?

  solar    forecast radiation (weather.py) x this house's own kWh of PV per kWh/m², fitted on the last
           7 days. Until there are ~2 sunny days of history to fit on: PV_KWP x 0.8 (typical losses).
           No weather forecast (offline, WEATHER_ENABLED=0): the last 14 days' average for that hour.
  load     average home use for that hour of the day, weekdays and weekends apart, last 28 days.
  battery  simulated hour by hour from the current SoC, 95% efficient each way, at most BATT_MAX_KW:
             grid on   -> sun surplus charges it; a shortfall drains it to BATT_RESERVE_PCT, then the grid
             brownout  -> the same, but down to BATT_CUTOFF_PCT, then the house goes dark
Every number is computed here; the AI only phrases it (ai/facts.py).
"""
import time
from datetime import timedelta

from . import config, db, energy, weather

HOURS = 48
ETA = 0.95               # charge and discharge efficiency, each way
DEFAULT_PR = 0.8         # kWh per kWp per kWh/m² before calibration (wiring, heat, inverter losses)
MIN_CAL_SUN = 8.0        # kWh/m² of daytime radiation needed before the fitted factor is trusted

_cache: dict[tuple, object] = {}


def _cached(key: tuple, build):
    if key not in _cache:
        if len(_cache) > 64:
            _cache.clear()
        _cache[key] = build()
    return _cache[key]


def _hourly(device_id: str, start_ts: int, n: int) -> list[dict]:
    return energy.buckets(device_id, [start_ts + i * 3600 for i in range(n + 1)])


# ---------------------------------------------------------------- history --
def profiles(device_id: str) -> dict:
    """Average kWh per hour of day from finished days: load by (weekend, hour), PV by hour (last 14 days).
    Days without any data are skipped. Cached per device per day."""
    d = energy.today()

    def build() -> dict:
        days = 28
        start = energy.local_midnight(d - timedelta(days=days))
        rows = _hourly(device_id, start, days * 24)
        load: dict[tuple[bool, int], list[float]] = {}
        pv: dict[int, list[float]] = {}
        for day in range(days):
            chunk = rows[day * 24:(day + 1) * 24]
            if sum(b["load_kwh"] for b in chunk) <= 0:
                continue  # device was off all day
            for i, b in enumerate(chunk):
                lt = energy.to_local(start + (day * 24 + i) * 3600)
                load.setdefault((lt.weekday() >= 5, lt.hour), []).append(b["load_kwh"])
                if day >= days - 14:
                    pv.setdefault(lt.hour, []).append(b["pv_kwh"])
        mean = lambda xs: sum(xs) / len(xs)  # noqa: E731
        return {"load": {k: mean(v) for k, v in load.items()}, "pv": {h: mean(v) for h, v in pv.items()}}

    return _cached((device_id, "profiles", d), build)


def _load_at(prof: dict, weekend: bool, hour: int, fallback: float) -> float:
    lp = prof["load"]
    return lp.get((weekend, hour), lp.get((not weekend, hour), fallback))


def calibrate(device_id: str, wx: dict[int, dict]) -> float | None:
    """kWh of PV per kWh/m² of radiation, fitted on the past hours the weather service also returned.
    Hours with little sun or no device data are skipped. None = not enough sunny history yet.
    (A battery that is full with export blocked curtails PV, which biases this low.)"""
    now = time.time()
    past = sorted(ts for ts in wx if now - 7 * 86400 <= ts <= now - 3600)
    if not past:
        return None

    def build() -> float | None:
        rows = _hourly(device_id, past[0], (past[-1] - past[0]) // 3600 + 1)
        pv = sun = 0.0
        for i, b in enumerate(rows):
            w = wx.get(past[0] + i * 3600)
            if w is None or w["rad_wm2"] < 100 or b["load_kwh"] <= 0:
                continue
            pv += b["pv_kwh"]
            sun += w["rad_wm2"] / 1000
        return pv / sun if sun >= MIN_CAL_SUN and pv > 0 else None

    return _cached((device_id, "cal", weather.fetched_at(), past[0]), build)


# --------------------------------------------------------------- battery --
def simulate(soc_pct: float, cap_kwh: float, floor_pct: float, slots: list[tuple[float, float, float, float]],
             max_kw: float | None = None) -> dict:
    """slots = [(start ts, hours, pv kWh, load kWh)]. Returns SoC % at the end of each slot, kWh the battery
    couldn't cover per slot, when it first hits `floor_pct` and when it first reaches 100 %."""
    max_kw = config.BATT_MAX_KW if max_kw is None else max_kw
    e, floor = cap_kwh * soc_pct / 100, cap_kwh * floor_pct / 100
    socs, short, floor_ts, full_ts = [], [], None, None
    if e >= cap_kwh - 1e-6 and slots:
        full_ts = int(slots[0][0])
    for ts, dur, pv, load in slots:
        net = pv - load
        unmet = 0.0
        if net >= 0:
            can = min(net * ETA, max_kw * dur * ETA)
            room = cap_kwh - e
            if full_ts is None and can > 0 and can >= room - 1e-9:  # this slot fills it
                full_ts = int(ts + dur * 3600 * room / can)
            e += min(can, room)
        else:
            need = -net
            out = min(need, max(0.0, (e - floor) * ETA), max_kw * dur)
            e -= out / ETA
            unmet = need - out
            if floor_ts is None and unmet > 1e-9 and e - floor <= 1e-6:
                floor_ts = int(ts + dur * 3600 * out / need)
        socs.append(e / cap_kwh * 100)
        short.append(unmet)
    return {"soc": socs, "short_kwh": short, "floor_ts": floor_ts, "full_ts": full_ts}


# --------------------------------------------------------------- outlook --
def outlook(device_id: str, settings: dict) -> dict:
    from ai.prompts import outlook_advice

    now = time.time()
    start = int(now // 3600 * 3600)
    d = energy.today()
    wx = weather.hours()
    prof = profiles(device_id)
    k = (calibrate(device_id, wx) if wx else None) or config.PV_KWP * DEFAULT_PR
    t = db.latest_telemetry(device_id)
    load_fallback = (t["load_w"] / 1000) if t else 0.5

    slots, hours, covered = [], [], 0
    for i in range(HOURS):
        hs = start + i * 3600
        dur = (hs + 3600 - now) / 3600 if i == 0 else 1.0
        lt = energy.to_local(hs)
        w = wx.get(hs) if wx else None
        if w is not None:
            pv = k * w["rad_wm2"] / 1000
            covered += i < 24
        else:
            pv = prof["pv"].get(lt.hour, 0.0)
        load = _load_at(prof, lt.weekday() >= 5, lt.hour, load_fallback)
        slots.append((now if i == 0 else hs, dur, pv * dur, load * dur))
        hours.append({"ts": hs, "pv_kwh": round(pv, 2), "load_kwh": round(load, 2),
                      "soc_pct": None, "cloud_pct": w["cloud_pct"] if w else None})

    def on(day) -> list[int]:
        return [i for i in range(HOURS) if energy.to_local(hours[i]["ts"]).date() == day]

    today_i, tomorrow_i = on(d), on(d + timedelta(days=1))
    solar_today = energy.day_totals(device_id, d)["pv_kwh"] + sum(slots[i][2] for i in today_i)
    solar_tomorrow = sum(slots[i][2] for i in tomorrow_i)
    typical = sum(prof["pv"].values()) if len(prof["pv"]) == 24 else None

    battery = {"soc_pct": None, "reserve_pct": config.BATT_RESERVE_PCT, "reserve_ts": None, "full_ts": None,
               "tomorrow_max_soc_pct": None, "grid_kwh_24h": round(sum(max(0.0, s[3] - s[2]) for s in slots[:24]), 2)}
    brownout = None
    grid_on = True
    if t is not None:
        grid_on = bool(t["grid_on"])
        cap = settings["battery_kwh"]
        g = simulate(t["batt_soc"], cap, config.BATT_RESERVE_PCT, slots)
        b = simulate(t["batt_soc"], cap, config.BATT_CUTOFF_PCT, slots)
        for h, soc in zip(hours, g["soc"]):
            h["soc_pct"] = round(soc, 1)
        battery.update(soc_pct=t["batt_soc"], reserve_ts=g["floor_ts"], full_ts=g["full_ts"],
                       tomorrow_max_soc_pct=round(max(g["soc"][i] for i in tomorrow_i), 1) if tomorrow_i else None,
                       grid_kwh_24h=round(sum(g["short_kwh"][:24]), 2))
        until = b["floor_ts"]
        brownout = {"active": not grid_on, "cutoff_pct": config.BATT_CUTOFF_PCT, "lasts_until_ts": until,
                    "hours": round((until - now) / 3600, 1) if until is not None else None}

    o = {
        "generated_ts": int(now),
        "source": "weather" if covered >= 24 else "history",
        "solar_today_kwh": round(solar_today, 1),
        "solar_tomorrow_kwh": round(solar_tomorrow, 1),
        "solar_typical_kwh": round(typical, 1) if typical is not None else None,
        "battery": battery,
        "brownout": brownout,
        "hours": hours,
    }
    o["advice"] = outlook_advice(o)
    return o
