"""Household profile: what the home's own electricity use says about the people in it, and what changed.

Only whole-home load (load_w) is used, averaged into 15-minute slots. A slot is "active" (someone is up and
using things) when its average is clearly above the always-on baseload, or when power jumped around a lot
inside it (appliances switching). From the last 28 days:

  baseload   always-on use (ref, standby, router): the 10th percentile of slot averages
  routine    weekdays and weekends apart: how often the house is active at each hour (home_pct), when it
             usually goes quiet for the night (sleep_hour) and wakes up (wake_hour), and the longest quiet
             stretch in the day (away: probably nobody home)
  archetype  away on weekday daytimes / home all day / mixed, plus a few traits
  now        the last 30 minutes against that routine: active | asleep | away | quiet | unknown, whether
             someone is likely home, and whether activity right now is unusual for this hour

New appliance ("new_loads"): the last few days compared with the 4 weeks before them. Two kinds:
  always_on  the baseload rose (a new ref, freezer, aquarium, server: on day and night)
  scheduled  the same hours got heavier on most recent days (a new aircon at night, a water heater in the
             morning), compared with the same hours on the same kind of day (weekday / weekend)
Each comes with when it started, the added watts, kWh a day and an upper-bound ₱ a month.

Occupancy is personal data: it never leaves the laptop (no cloud), like everything else in Solaris.
Every number is computed here; the app and Mira only show it.
"""
import statistics
import time
from datetime import date, timedelta

from . import db, energy

SLOT_S = 900                # 15-minute slots
SLOTS_DAY = 24 * 3600 // SLOT_S
PROFILE_DAYS = 28           # routine and baseload window
BASELINE_DAYS = 28          # "before" window for new-appliance detection
RECENT_MAX, RECENT_MIN = 7, 3   # a new load must show on most of the last 3..7 days
NOW_S = 1800                # "right now" = the last 30 minutes
MIN_DAYS = 3                # fewer days with data -> no routine yet

ACTIVE_MIN_W = 150          # active = baseload + at least this much ...
ACTIVE_REL = 0.5            # ... or + half the baseload, whichever is more
SPIKE_W = 400               # ... or power swung this much inside the slot
HOME_P = 0.5                # an hour is "usually active" when half its slots are
AWAY_P = 0.25               # an hour is "usually quiet" below this
AWAY_MIN_H = 3              # shortest daytime quiet stretch that counts as "away"
UNUSUAL_P = 0.2             # activity at an hour that is active less often than this is unusual

ALWAYS_ON_MIN_W = 60        # baseload rise worth flagging ...
ALWAYS_ON_REL = 0.2         # ... and at least 20 % of the old baseload
BLOCK_W = 300               # a scheduled new load adds at least this much in each of its hours
SD_K = 1.0                  # ... and more than the hour's usual day-to-day spread
HIT_SHARE = 0.6             # ... on at least 60 % of the recent days
MIN_KWH_DAY = 0.5           # smaller new loads aren't worth telling
MAX_NEW = 2

Slot = tuple[float, float, float]   # (average W, min W, max W)

ARCHETYPES = {
    "away_daytime": "Wala sa bahay tuwing weekday",
    "home_daytime": "May tao sa bahay buong araw",
    "mixed": "Iba-iba ang oras sa bahay",
    "unknown": "Inaaral pa ang routine ninyo",
}


def _clock(h: int) -> str:
    h %= 24
    return f"{h % 12 or 12}{'AM' if h < 12 else 'PM'}"


def _kw(w: float) -> str:
    return f"{w / 1000:.1f} kW" if abs(w) >= 1000 else f"{w:.0f} W"


def _pct(xs: list[float], q: float) -> float:
    s = sorted(xs)
    return s[min(len(s) - 1, int(q * len(s)))]


def threshold(base: float) -> float:
    """Slot average above this = someone is using things."""
    return base + max(ACTIVE_MIN_W, ACTIVE_REL * base)


def active(s: Slot, thr: float) -> bool:
    return s[0] > thr or s[2] - s[1] > SPIKE_W


# ------------------------------------------------------------------- data --
def _slots(device_id: str, start: int, end: int) -> dict[int, Slot]:
    rows = db.query("SELECT ts / ? AS s, AVG(load_w) AS a, MIN(load_w) AS lo, MAX(load_w) AS hi FROM telemetry "
                    "WHERE device_id=? AND ts>=? AND ts<? GROUP BY s", (SLOT_S, device_id, start, end))
    return {r["s"] * SLOT_S: (r["a"], r["lo"], r["hi"]) for r in rows}


def history(device_id: str, today: date, n: int) -> dict[date, list[Slot | None]]:
    """The n finished days before `today`: 96 slots each (None = no data). Days with no data are left out."""
    first = today - timedelta(days=n)
    start = energy.local_midnight(first)
    slots = _slots(device_id, start, energy.local_midnight(today))
    out = {}
    for i in range(n):
        d = first + timedelta(days=i)
        m = energy.local_midnight(d)
        day = [slots.get(m + k * SLOT_S) for k in range(SLOTS_DAY)]
        if any(s is not None for s in day):
            out[d] = day
    return out


_cache: dict[tuple[str, date], dict] = {}


def _history_cached(device_id: str, today: date) -> dict[date, list[Slot | None]]:
    key = (device_id, today)
    if key not in _cache:
        if len(_cache) > 16:
            _cache.clear()
        _cache[key] = history(device_id, today, BASELINE_DAYS + RECENT_MAX)
    return _cache[key]


def _hourly(day: list[Slot | None]) -> list[float | None]:
    """Mean W per hour (None when fewer than 2 of its 4 slots have data)."""
    out = []
    for h in range(24):
        xs = [s[0] for s in day[h * 4:(h + 1) * 4] if s is not None]
        out.append(sum(xs) / len(xs) if len(xs) >= 2 else None)
    return out


def _day_base(day: list[Slot | None]) -> float | None:
    xs = [s[0] for s in day if s is not None]
    return _pct(xs, 0.1) if len(xs) >= SLOTS_DAY // 2 else None


# ---------------------------------------------------------------- routine --
def _run_around(p: list[float], h: int, quiet) -> tuple[int, int] | None:
    """The circular run of hours around h where quiet(p[x]): (start, end exclusive), None if h isn't quiet
    or the whole day is."""
    if not quiet(p[h]):
        return None
    a, b, n = h, h, 0
    while quiet(p[(a - 1) % 24]) and n < 24:
        a, n = a - 1, n + 1
    while quiet(p[(b + 1) % 24]) and n < 24:
        b, n = b + 1, n + 1
    if n >= 23:
        return None
    return a % 24, (b + 1) % 24


def day_profile(days: list[list[Slot | None]], thr: float) -> dict | None:
    """Routine for one kind of day (weekday or weekend). None if some hour has no data."""
    acts: list[list[bool]] = [[] for _ in range(24)]
    watts: list[list[float]] = [[] for _ in range(24)]
    for day in days:
        for i, s in enumerate(day):
            if s is not None:
                acts[i // 4].append(active(s, thr))
                watts[i // 4].append(s[0])
    if any(not a for a in acts):
        return None
    p = [sum(a) / len(a) for a in acts]
    w = [sum(x) / len(x) for x in watts]

    sleep = wake = None
    night = _run_around(p, 3, lambda v: v < HOME_P)        # the quiet stretch that covers 3 AM
    if night:
        if night[0] >= 18 or night[0] <= 4:
            sleep = night[0]
        if 3 <= night[1] <= 12:
            wake = night[1]

    lo = wake if wake is not None else 6
    hi = sleep if sleep is not None and sleep >= 18 else 22
    away, best, run = None, 0, None
    for h in range(lo, hi + 1):
        if h < hi and p[h] < AWAY_P:
            run = run if run is not None else h
        elif run is not None:
            if h - run > best:
                best, away = h - run, {"start_hour": run, "end_hour": h}
            run = None
    if best < AWAY_MIN_H:
        away = None
    return {"wake_hour": wake, "sleep_hour": sleep, "away": away,
            "peak_hour": max(range(24), key=lambda h: w[h]),
            "home_pct": [round(x * 100) for x in p], "avg_w": [round(x) for x in w]}


def _asleep_at(prof: dict | None, h: int) -> bool:
    if not prof or prof["sleep_hour"] is None or prof["wake_hour"] is None:
        return False
    s, e = prof["sleep_hour"], prof["wake_hour"]
    return (s <= h < e) if s < e else (h >= s or h < e)


def archetype(weekday: dict | None, weekend: dict | None) -> dict:
    if weekday is None:
        aid, desc = "unknown", "Kailangan pa ng ilang araw ng readings bago makita ang routine ng bahay."
    elif weekday["away"] and weekday["away"]["end_hour"] - weekday["away"]["start_hour"] >= 6:
        a = weekday["away"]
        aid = "away_daytime"
        desc = (f"Tuwing weekday, karaniwang tahimik ang bahay mula {_clock(a['start_hour'])} hanggang "
                f"{_clock(a['end_hour'])}: mukhang nasa trabaho o eskwela kayo.")
    elif sum(weekday["home_pct"][9:17]) / 8 >= HOME_P * 100:
        aid = "home_daytime"
        desc = "Halos buong araw may gumagamit ng kuryente: mukhang may naiiwan sa bahay tuwing weekday."
    else:
        aid = "mixed"
        desc = "Walang iisang oras ng pag-alis at pag-uwi: iba-iba ang routine sa bawat araw."
    return {"id": aid, "label": ARCHETYPES[aid], "description": desc}


def traits(weekday: dict | None, weekend: dict | None, arch: str, base_w: float | None) -> list[dict]:
    out = []
    p = weekday or weekend
    if p:
        if p["wake_hour"] is not None and p["wake_hour"] <= 5:
            out.append(("early_riser", f"Maagang gumigising (mga {_clock(p['wake_hour'])})"))
        if p["sleep_hour"] is not None and p["sleep_hour"] <= 4:
            out.append(("night_owl", f"Gising pa lampas hatinggabi (hanggang mga {_clock(p['sleep_hour'])})"))
        if p["sleep_hour"] is None and p["home_pct"][2] >= HOME_P * 100:
            out.append(("night_load", "Malakas ang gamit buong gabi (hal. aircon habang tulog)"))
        if 17 <= p["peak_hour"] <= 22:
            out.append(("evening_peak", f"Pinakamalakas ang gamit mga {_clock(p['peak_hour'])}"))
    if arch == "away_daytime" and weekend and sum(weekend["home_pct"][9:17]) / 8 >= HOME_P * 100:
        out.append(("weekend_home", "Nasa bahay tuwing weekend"))
    if base_w is not None and base_w >= 250:
        out.append(("high_baseload", f"Mataas ang laging-nakabukas na gamit ({_kw(base_w)})"))
    return [{"id": i, "label": label} for i, label in out]


# -------------------------------------------------------------------- now --
def now_status(recent: Slot | None, online: bool, now: float, profiles: dict, thr: float | None) -> dict:
    """The last 30 minutes against the routine. `recent` = (avg, min, max) W over NOW_S, None if no data.
    `profiles` = {"weekday": ..., "weekend": ...}."""
    def prof_at(ts: float) -> dict | None:
        wk = "weekend" if energy.to_local(int(ts)).weekday() >= 5 else "weekday"
        return profiles[wk] or profiles["weekend" if wk == "weekday" else "weekday"]

    base = {"state": "unknown", "likely_home": None, "load_w": None, "usual_home_pct": None,
            "unusual": False, "next_active_ts": None}
    if not online or recent is None or thr is None:
        return base | {"text": "Hindi alam ngayon: walang bagong reading mula sa device."}
    h = energy.to_local(int(now)).hour
    prof = prof_at(now)
    usual = prof["home_pct"][h] if prof else None
    load = round(recent[0])
    out = base | {"load_w": load, "usual_home_pct": usual}

    if active(recent, thr):
        unusual = usual is not None and usual < UNUSUAL_P * 100
        text = f"May gumagamit ng kuryente ngayon ({_kw(load)}): may tao sa bahay."
        if unusual:
            text += " Hindi ito karaniwan sa oras na ito."
        return out | {"state": "active", "likely_home": True, "unusual": unusual, "text": text}

    # Quiet: only the always-on load. When is the house usually busy again?
    nxt = None
    start = int(now // 3600 * 3600) + 3600
    for k in range(24):
        ts = start + k * 3600
        p = prof_at(ts)
        if p and p["home_pct"][energy.to_local(ts).hour] >= HOME_P * 100:
            nxt = ts
            break
    out["next_active_ts"] = nxt
    back = f" Karaniwang may gumagamit ulit mga {_clock(energy.to_local(nxt).hour)}." if nxt else ""
    if _asleep_at(prof, h):
        return out | {"state": "asleep", "likely_home": True,
                      "text": f"Tahimik ang bahay ({_kw(load)}), oras ng tulog ninyo: malamang tulog na kayo."}
    if prof is None or usual is None:
        return out | {"state": "quiet", "likely_home": None,
                      "text": f"Tahimik ang bahay ngayon ({_kw(load)}). Inaaral pa ang routine ninyo."}
    if usual < HOME_P * 100:
        return out | {"state": "away", "likely_home": False,
                      "text": f"Laging-nakabukas na gamit lang ({_kw(load)}): mukhang walang tao sa bahay ngayon.{back}"}
    return out | {"state": "quiet", "likely_home": False,
                  "text": f"Mas tahimik kaysa karaniwan sa oras na ito ({_kw(load)}): baka umalis kayo.{back}"}


def recent_slot(device_id: str, now: float) -> Slot | None:
    r = db.one("SELECT AVG(load_w) AS a, MIN(load_w) AS lo, MAX(load_w) AS hi, COUNT(*) AS n FROM telemetry "
               "WHERE device_id=? AND ts>=? AND ts<=?", (device_id, int(now) - NOW_S, int(now)))
    return (r["a"], r["lo"], r["hi"]) if r and r["n"] else None


# --------------------------------------------------------- new appliances --
def _guess(kind: str, w: float, hours: list[int] | None) -> str:
    if kind == "always_on":
        return "ref, freezer o chiller" if w < 250 else "laging nakabukas na appliance (freezer, water dispenser o server)"
    night = sum(1 for h in hours if h >= 18 or h < 6) > len(hours) / 2
    if w >= 2500:
        return "water heater, induction cooker o EV/e-bike charger"
    if night and w >= 500:
        return "aircon"
    if w < 500:
        return "electric fan, TV o computer"
    return "malaking appliance (aircon, plantsa o water pump)"


def _since(series: list[tuple[date, float | None]], effect: float) -> tuple[date | None, int]:
    """Walk back from the latest day while the excess is at least half the effect (one miss allowed).
    Returns (first day it showed, days it showed)."""
    first, seen, misses = None, 0, 0
    for d, e in reversed(series):
        if e is not None and e >= effect / 2:
            first, seen, misses = d, seen + 1, 0
        else:
            misses += 1
            if misses > 1:
                break
    return first, seen


def _detect(days: dict[date, list[Slot | None]], recent: list[date], baseline: list[date]) -> list[dict]:
    recent = [d for d in recent if d in days]
    baseline = [d for d in baseline if d in days]
    if len(recent) < RECENT_MIN or len(baseline) < 10:
        return []
    hourly = {d: _hourly(days[d]) for d in recent + baseline}
    dbase = {d: _day_base(days[d]) for d in recent + baseline}
    out = []

    b0s = [dbase[d] for d in baseline if dbase[d] is not None]
    b1s = [dbase[d] for d in recent if dbase[d] is not None]
    shift = 0.0
    if len(b0s) >= 7 and len(b1s) >= RECENT_MIN:
        b0, b1 = statistics.median(b0s), statistics.median(b1s)
        if b1 - b0 >= max(ALWAYS_ON_MIN_W, ALWAYS_ON_REL * b0):
            shift = b1 - b0
            out.append({"kind": "always_on", "hours": None, "added_w": shift,
                        "excess": lambda d, b0=b0: None if dbase[d] is None else dbase[d] - b0})

    wk = lambda d: d.weekday() >= 5  # noqa: E731
    ref: dict[tuple[bool, int], tuple[float, float]] = {}
    for kind in (False, True):
        for h in range(24):
            xs = [hourly[d][h] for d in baseline if wk(d) == kind and hourly[d][h] is not None]
            if len(xs) >= 3:
                ref[(kind, h)] = (statistics.fmean(xs), statistics.pstdev(xs))

    def mean_sd(d: date, h: int) -> tuple[float, float] | None:
        return ref.get((wk(d), h)) or ref.get((not wk(d), h))

    med: dict[int, float] = {}
    for h in range(24):
        ex, sds = [], []
        for d in recent:
            m = mean_sd(d, h)
            if hourly[d][h] is not None and m:
                ex.append(hourly[d][h] - m[0] - shift)
                sds.append(m[1])
        if len(ex) < RECENT_MIN:
            continue
        mid = statistics.median(ex)
        hits = sum(e >= BLOCK_W / 2 for e in ex)
        if mid >= max(BLOCK_W, SD_K * max(sds)) and hits >= HIT_SHARE * len(ex):
            med[h] = mid

    # Contiguous flagged hours (wrapping midnight) = one new load each.
    runs, seen = [], set()
    for h in sorted(med):
        if h in seen:
            continue
        a = h
        while (a - 1) % 24 in med and (a - 1) % 24 != h:
            a = (a - 1) % 24
        run = [a]
        while (run[-1] + 1) % 24 in med and (run[-1] + 1) % 24 != a:
            run.append((run[-1] + 1) % 24)
        seen |= set(run)
        runs.append(run)
    for run in runs:
        kwh = sum(med[h] for h in run) / 1000
        if kwh < MIN_KWH_DAY:
            continue

        def excess(d: date, run=run) -> float | None:
            xs = [hourly[d][h] - mean_sd(d, h)[0] - shift for h in run if hourly[d][h] is not None and mean_sd(d, h)]
            return sum(xs) if len(xs) >= len(run) / 2 else None
        out.append({"kind": "scheduled", "hours": run, "added_w": kwh * 1000 / len(run), "excess": excess,
                    "kwh_day": kwh})
    for o in out:
        o.setdefault("kwh_day", o["added_w"] * 24 / 1000)
        o["series"] = [(d, o["excess"](d)) for d in sorted(baseline + recent)]
        o["effect"] = o["added_w"] if o["kind"] == "always_on" else o["kwh_day"] * 1000
    return out


def new_loads(days: dict[date, list[Slot | None]], today: date, rate: float) -> list[dict]:
    """Loads that appeared in the last RECENT_MIN..RECENT_MAX days, biggest first."""
    found: list[dict] = []
    for n in range(RECENT_MAX, RECENT_MIN - 1, -1):           # longest evidence first
        recent = [today - timedelta(days=i) for i in range(n, 0, -1)]
        baseline = [today - timedelta(days=n + i) for i in range(BASELINE_DAYS, 0, -1)]
        for o in _detect(days, recent, baseline):
            same = [f for f in found if f["kind"] == o["kind"] and
                    (o["kind"] == "always_on" or set(f["hours"]) & set(o["hours"]))]
            if not same:
                found.append(o)
            elif o["kwh_day"] > 1.2 * max(f["kwh_day"] for f in same):
                # A shorter window caught more of it (e.g. the hours after midnight only began 5 days ago).
                found = [f for f in found if f not in same] + [o]

    out = []
    for o in found:
        since, seen = _since(o["series"], o["effect"])
        if since is None or seen < RECENT_MIN:
            continue
        w, kwh = round(o["added_w"], -1), round(o["kwh_day"], 1)
        php = round(kwh * 30 * rate)
        guess = _guess(o["kind"], w, o["hours"])
        when = f"{since:%b} {since.day}"
        if o["kind"] == "always_on":
            sh = eh = None
            text = (f"Mula noong {when}, tumaas ng mga {_kw(w)} ang laging-nakabukas na gamit, araw at gabi "
                    f"(mga {kwh:.1f} kWh kada araw, hanggang ₱{php:,} kada buwan). Baka may bagong {guess}?")
        else:
            sh, eh = o["hours"][0], (o["hours"][-1] + 1) % 24
            text = (f"Mula noong {when}, mga {_kw(w)} ang dagdag na gamit tuwing {_clock(sh)}–{_clock(eh)} "
                    f"(mga {kwh:.1f} kWh kada araw, hanggang ₱{php:,} kada buwan). Baka may bagong {guess}?")
        out.append({"id": "always_on" if sh is None else f"block_{sh:02d}_{eh:02d}", "kind": o["kind"],
                    "start_hour": sh, "end_hour": eh, "added_w": int(w), "kwh_day": kwh, "php_month": php,
                    "since_ts": energy.local_midnight(since), "days_seen": seen, "guess": guess, "text": text})
    out.sort(key=lambda x: -x["kwh_day"])
    return out[:MAX_NEW]


# ------------------------------------------------------------------- main --
def profile(days: dict[date, list[Slot | None]], today: date, rate: float) -> dict:
    """Everything but `now`, from finished days (pure: no DB)."""
    window = [today - timedelta(days=i) for i in range(PROFILE_DAYS, 0, -1)]
    used = [d for d in window if d in days]
    avgs = [s[0] for d in used for s in days[d] if s is not None]
    conf = ("none" if len(used) < MIN_DAYS else "low" if len(used) < 7 else "medium" if len(used) < 21 else "high")
    empty = {"days_used": len(used), "confidence": "none", "baseload": None, "daylight_use_pct": None,
             "routine": {"weekday": None, "weekend": None}, "archetype": archetype(None, None), "traits": [],
             "threshold_w": None}
    if conf == "none" or len(avgs) < SLOTS_DAY:
        return empty | {"new_loads": new_loads(days, today, rate)}

    base = _pct(avgs, 0.1)
    thr = threshold(base)
    wd = [days[d] for d in used if d.weekday() < 5]
    we = [days[d] for d in used if d.weekday() >= 5]
    weekday = day_profile(wd, thr) if len(wd) >= MIN_DAYS else None
    weekend = day_profile(we, thr) if len(we) >= 2 else None
    arch = archetype(weekday, weekend)

    day_w = sum(s[0] for d in used for i, s in enumerate(days[d]) if s is not None and 24 <= i < 72)
    daily_kwh = sum(avgs) * SLOT_S / 3.6e6 / len(used)
    base_kwh_day = base * 24 / 1000
    return {
        "days_used": len(used), "confidence": conf, "threshold_w": thr,
        "baseload": {"watts": int(round(base, -1)), "kwh_month": round(base_kwh_day * 30, 1),
                     "php_month": round(base_kwh_day * 30 * rate),
                     "share_pct": round(min(100.0, base_kwh_day / daily_kwh * 100), 1) if daily_kwh > 0 else 0.0},
        "daylight_use_pct": round(day_w / sum(avgs) * 100, 1) if sum(avgs) > 0 else None,
        "routine": {"weekday": weekday, "weekend": weekend},
        "archetype": arch,
        "traits": traits(weekday, weekend, arch["id"], round(base, -1)),
        "new_loads": new_loads(days, today, rate),
    }


def household(device_id: str, settings: dict, now: float | None = None) -> dict:
    """The /api/household response."""
    now = now or time.time()
    today = energy.to_local(int(now)).date()
    p = profile(_history_cached(device_id, today), today, settings["rate_php_per_kwh"])
    latest = db.latest_telemetry(device_id)
    online = energy.device_info(device_id, latest)["online"]
    thr = p.pop("threshold_w")
    return {"generated_ts": int(now),
            "now": now_status(recent_slot(device_id, now), online, now, p["routine"], thr), **p}
