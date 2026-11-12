"""Hourly solar radiation and cloud cover from Open-Meteo (free, no API key).

refresh() runs in the background every 30 min (main._background), never on a request path, so a slow
or missing internet connection can't stall the app. Readers get the last good forecast, or None when
there is none or it is older than STALE_S. Only SITE_LAT/SITE_LON are sent.

One call returns the past 7 days too: outlook.py uses those to calibrate this house's panels.
"""
import logging
import time

import httpx

from . import config

log = logging.getLogger("solaris.weather")

STALE_S = 6 * 3600

# {"fetched": unix s, "hours": {hour start ts: {"rad_wm2": float, "cloud_pct": int | None}}}
_cache: dict | None = None


def parse(hourly: dict) -> dict[int, dict]:
    """Open-Meteo's radiation at time T is the mean over the hour BEFORE T, so key it by T - 1 h."""
    out = {}
    for ts, rad, cc in zip(hourly["time"], hourly["shortwave_radiation"], hourly["cloud_cover"]):
        if rad is not None:
            out[int(ts) - 3600] = {"rad_wm2": float(rad), "cloud_pct": int(cc) if cc is not None else None}
    return out


def set_hours(hours: dict[int, dict], fetched: float | None = None) -> None:
    global _cache
    _cache = {"fetched": fetched if fetched is not None else time.time(), "hours": hours}


def hours() -> dict[int, dict] | None:
    if _cache is None or time.time() - _cache["fetched"] > STALE_S:
        return None
    return _cache["hours"]


def fetched_at() -> float | None:
    return _cache["fetched"] if _cache else None


def refresh() -> bool:
    if not config.WEATHER_ENABLED:
        return False
    params = {"latitude": config.SITE_LAT, "longitude": config.SITE_LON, "hourly": "shortwave_radiation,cloud_cover",
              "past_days": 7, "forecast_days": 3, "timezone": "UTC", "timeformat": "unixtime"}
    try:
        r = httpx.get(config.WEATHER_URL, params=params, timeout=10)
        r.raise_for_status()
        parsed = parse(r.json()["hourly"])
    except (httpx.HTTPError, KeyError, TypeError, ValueError) as e:
        log.warning("weather refresh failed, keeping the last forecast: %s", e)
        return False
    set_hours(parsed)
    return True
