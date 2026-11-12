"""Verified overall residential rate from Meralco's public rate card.

The published rate uses the 200-kWh reference household. No household data is sent.
Only a validated rate and billing month replace the persisted last good value.
"""
import calendar
from datetime import datetime
from decimal import Decimal, InvalidOperation
from html.parser import HTMLParser
import json
import logging
import re
import threading
import time

import httpx

from . import config, db

SOURCE_URL = "https://www.meralco.com.ph/"
CACHE_KEY = "meralco_rate"
REFRESH_S = 6 * 3600
MIN_CHECK_S = 60
MAX_BYTES = 2 * 1024 * 1024
_lock = threading.Lock()
log = logging.getLogger("solaris.meralco")
MONTHS = {name.lower(): i for i, name in enumerate(calendar.month_name) if name}


class RateCards(HTMLParser):
    def __init__(self):
        super().__init__()
        self.cards = []
        self.depth = 0
        self.text = []
        self.values = []

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        classes = attrs.get("class", "").split()
        if tag == "div":
            if self.depth:
                self.depth += 1
            elif "statistics-grid__item" in classes:
                self.depth = 1
                self.text, self.values = [], []
        if self.depth and tag == "data" and "statistics-grid__number" in classes:
            self.values.append(attrs.get("value", ""))

    def handle_data(self, data):
        if self.depth:
            self.text.append(data)

    def handle_endtag(self, tag):
        if tag == "div" and self.depth:
            self.depth -= 1
            if not self.depth:
                self.cards.append((" ".join(" ".join(self.text).split()), self.values))


def parse(html: str, today=None) -> dict:
    parser = RateCards()
    parser.feed(html)
    today = today or datetime.now(config.TZ).date()
    candidates = []
    for text, values in parser.cards:
        label = re.search(r"\b([A-Za-z]+) Residential Rate\b", text, re.I)
        period = re.search(r"Overall rate for a typical household this ([A-Za-z]+) (20\d{2})\b", text, re.I)
        if not label or not period or label[1].lower() != period[1].lower():
            continue
        month = MONTHS.get(period[1].lower())
        if not month or len(values) != 1 or not re.fullmatch(r"\d{1,2}\.\d{4}", values[0]):
            raise ValueError("Unrecognized residential rate card")
        rate = Decimal(values[0])
        billing_month = f"{period[2]}-{month:02d}"
        if not 0 < rate < 100 or billing_month > today.strftime("%Y-%m"):
            raise ValueError("Invalid residential rate or billing month")
        candidates.append({"rate_php_per_kwh": float(rate), "billing_month": billing_month})
    if len(candidates) != 1:
        raise ValueError("Expected exactly one overall residential rate card")
    return candidates[0]


def info(saved: dict | None = None) -> dict:
    saved = (db.get_kv(CACHE_KEY) or {}) if saved is None else saved
    good = saved.get("billing_month") is not None and saved.get("fetched_at") is not None
    cached = saved.get("refresh_failed", False) or time.time() - (saved.get("fetched_at") or 0) >= REFRESH_S
    return {
        "status": ("cached" if cached else "published") if good else "unavailable",
        "billing_month": saved.get("billing_month"),
        "source_url": SOURCE_URL,
        "reference_kwh": 200,
        "fetched_at": saved.get("fetched_at"),
        "checked_at": saved.get("checked_at"),
    }


def download() -> str:
    # A fixed HTTPS origin, no user-provided URLs or redirects; bound payload and I/O waits.
    with httpx.stream("GET", SOURCE_URL, timeout=8, follow_redirects=False,
                      headers={"Accept": "text/html", "User-Agent": "Solaris/1.0 residential-rate-check"}) as response:
        response.raise_for_status()
        if "text/html" not in response.headers.get("content-type", "").lower():
            raise ValueError("Meralco did not return an HTML page")
        body = bytearray()
        for chunk in response.iter_bytes():
            body.extend(chunk)
            if len(body) > MAX_BYTES:
                raise ValueError("Rate page exceeds size limit")
        return body.decode("utf-8")


def refresh(force: bool = False) -> dict:
    if not config.MERALCO_RATE_ENABLED or not _lock.acquire(blocking=False):
        return info()
    try:
        saved = db.get_kv(CACHE_KEY) or {}
        now = int(time.time())
        if now - (saved.get("checked_at") or 0) < (MIN_CHECK_S if force else REFRESH_S):
            return info()
        try:
            parsed = parse(download())
            if saved.get("billing_month") and parsed["billing_month"] < saved["billing_month"]:
                raise ValueError("Rate publication is older than the cached month")
        except (httpx.HTTPError, UnicodeError, ValueError, InvalidOperation) as error:
            log.warning("Rate check failed; retaining the last verified value: %s", type(error).__name__)
            db.put_kv(CACHE_KEY, saved | {"checked_at": now, "refresh_failed": True})
            return info()
        record = parsed | {"fetched_at": now, "checked_at": now, "refresh_failed": False}
        # One SQLite statement atomically updates the calculation rate and its provenance.
        db.execute("INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?), (?, ?)",
                   ("rate_php_per_kwh", json.dumps(parsed["rate_php_per_kwh"]), CACHE_KEY, json.dumps(record)))
        return info()
    finally:
        _lock.release()
