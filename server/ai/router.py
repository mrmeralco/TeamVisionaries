"""Picks which fact topics go into the prompt for a question.

Fewer facts = shorter prompt (faster on a laptop) and less for a small model to mix up.
Safety-critical facts (an active brownout or fault) are always included.
"""
import re

from .answers import direct_ids

KEYWORDS: dict[str, tuple[str, ...]] = {
    "bill": ("bill", "bayad", "babayaran", "singil", "rate", "meralco", "forecast", "buwan", "month"),
    "savings": ("tipid", "natipid", "savings", "save", "sulit", "balik"),
    "today": ("ngayong araw", "today", "kanina", "ngayon araw"),
    "yesterday": ("kahapon", "yesterday"),
    "usage": ("gamit", "konsumo", "kumokonsumo", "consumption", "usage", "peak", "oras", "linggo", "week", "pattern",
              "appliance", "aircon"),
    "battery": ("battery", "baterya", "charge", "soc", "tatagal", "runtime"),
    "brownout": ("brownout", "blackout", "walang kuryente", "nawalan", "outage", "power interruption"),
    "fault": ("fault", "error", "sira", "problema", "init", "mainit", "temperature", "overheat", "code"),
    "alerts": ("alert", "abiso", "notification", "babala"),
    "outlook": ("bukas", "tomorrow", "makalawa", "mamaya", "panahon", "weather", "ulap", "maulap", "ulan", "umuulan",
                "bagyo", "sisikat", "sikat", "mauubos", "maubos", "mapupuno", "mapuno", "aabot"),
    "now": ("ngayon", "now", "solar", "araw", "panel", "grid", "live"),
}
# Cost words that mean "bill" only when nothing more specific was asked:
# "Bakit mahal?" is about the bill, "Magkano kinuha ko sa grid kahapon?" is about yesterday.
WEAK_BILL = ("magkano", "mahal", "mataas", "gastos", "presyo")
ALWAYS = {"now"}


# Words that make "forecast" about money even when the sun or battery is mentioned too.
MONEY_WORDS = ("bill", "bayad", "babayaran", "singil", "magkano", "nagastos", "gastos", "spent", "meralco", "piso", "₱")
SUN_WORDS = KEYWORDS["outlook"] + ("solar", "araw", "battery", "baterya", "panel")


def solar_forecast(m: str) -> bool:
    """'forecast ng solar bukas' is the weather outlook, not the bill forecast."""
    return "forecast" in m and _hits(m, SUN_WORDS) and not _hits(m, MONEY_WORDS)


def bill_intent(message: str) -> str | None:
    m = message.lower()
    if not re.search(r"\b(bill|buwan|month|forecast|spent|nagastos)\b", m) or solar_forecast(m):
        return None
    current = any(re.search(rf"\b{re.escape(w)}\b", m) for w in ("magkano na", "hanggang ngayon", "so far", "month-to-date", "spent so far"))
    forecast = any(w in m for w in ("forecast", "katapusan", "end of", "projected"))
    if any(w in m for w in ("kaysa", "kumpara", "compared", "versus", " vs ")):
        return "comparison"
    if any(w in m for w in ("last month", "nakaraang buwan")):
        return "last_month"
    if current and forecast:
        return "both"
    if forecast:
        return "forecast"
    if current:
        return "current"
    return None


def select_facts(message, facts):
    intent = bill_intent(message)
    if intent in {"comparison", "last_month"}:
        keep = {"bill.last_month_php", "bill.forecast_php", "bill.vs_last_month_pct"} if intent == "comparison" else {"bill.last_month_php"}
        return [f for f in facts if f.id in keep or f.topic in {"now", "brownout", "fault"}]
    if intent not in {"current", "forecast"}:
        if any(f.topic == "bill" for f in facts) and "bakit" in message.lower():
            return [f for f in facts if f.topic != "usage" or f.id == "usage.peak_hours"]
        return facts
    keep = {"bill.month_to_date_php" if intent == "current" else "bill.forecast_php", "now.online", "now.status"}
    return [f for f in facts if f.id in keep or f.topic in {"brownout", "fault"}]


def _hits(m: str, words: tuple[str, ...]) -> bool:
    return any(re.search(rf"\b{re.escape(w)}", m) for w in words)


def topics_for(message: str, active: set[str]) -> set[str]:
    """`active` = topics with something urgent going on (e.g. {"brownout"} during an outage)."""
    m = message.lower()
    found = {topic for topic, words in KEYWORDS.items() if _hits(m, words)}
    if solar_forecast(m):
        found.discard("bill")
        found.add("outlook")
    if "today.saved_php" in direct_ids(message):
        found.add("today")
    if _hits(m, WEAK_BILL) and not found - ALWAYS:
        found.add("bill")
    if not found:
        # Vague question ("kumusta?", "ano balita?"): give a broad overview.
        found = {"today", "bill", "savings"}
    if bill_intent(message):
        found.add("bill")
    if "bill" in found:
        found.add("usage")  # "why is my bill high" needs the usage pattern
    if "battery" in found or "brownout" in found:
        found.add("outlook")  # "will my battery last?" depends on tomorrow's sun
    return found | ALWAYS | active
