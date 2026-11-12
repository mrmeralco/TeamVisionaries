"""Picks which fact topics go into the prompt for a question.

Fewer facts = shorter prompt (faster on a laptop) and less for a small model to mix up.
Safety-critical facts (an active brownout or fault) are always included.
"""
import re
from datetime import date

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
    # Specific phrases only: "mas malaki ang bill" or "sapat ba ang battery mamaya" are not upgrade questions.
    "upgrade": ("upgrade", "dagdag", "dagdagan", "palakihin", "mas malaking battery", "mas malaking inverter",
                "mas maraming panel", "system", "sukat ng", "bigger", "add more", "more panels", "more battery"),
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


# ---------------------------------------------------------------- months ahead --
# "Magkano ang bill ko sa Disyembre?" / "next month" / "sa 6 na buwan" / "next year": how far ahead is asked.
MONTH_NAMES = {
    1: ("enero", "january"), 2: ("pebrero", "febrero", "february"), 3: ("marso", "march"), 4: ("abril", "april"),
    5: ("mayo",), 6: ("hunyo", "june"), 7: ("hulyo", "july"), 8: ("agosto", "august"),
    9: ("setyembre", "septiyembre", "september", "sept"), 10: ("oktubre", "october"),
    11: ("nobyembre", "november"), 12: ("disyembre", "december", "pasko", "christmas"),
}
NUMBER_WORDS = {"isang": 1, "dalawang": 2, "tatlong": 3, "apat na": 4, "limang": 5, "anim na": 6, "pitong": 7,
                "walong": 8, "siyam na": 9, "sampung": 10, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
                "six": 6, "twelve": 12}


def months_ahead(message: str, today: date | None = None) -> int | None:
    """Calendar months after this one that the question asks about (0 = this month), None = no timeframe."""
    if today is None:
        from app import energy
        today = energy.today()
    m = message.lower()
    if re.search(r"\b(susunod na taon|next year|buong taon|isang taon|whole year|1 year|one year|12 buwan|12 months)\b", m):
        return 12
    num = re.search(r"\b(\d{1,2})\s*(?:na\s+)?(?:buwan|months?)\b", m)
    if num:
        return int(num.group(1))
    for word, n in NUMBER_WORDS.items():
        if re.search(rf"\b{word}\s+(?:buwan|months?)\b", m):
            return n
    if re.search(r"\b(susunod na buwan|next month|sa isang buwan|darating na buwan|coming month)\b", m):
        return 1
    for month, names in MONTH_NAMES.items():
        if any(re.search(rf"\b{n}\b", m) for n in names):
            year = re.search(r"\b(20\d\d)\b", m)
            y = int(year.group(1)) if year else (today.year if month >= today.month else today.year + 1)
            return (y - today.year) * 12 + month - today.month
    return None


def is_projection(message: str) -> bool:
    """A question about the bill in a later month (or "the next months"), answered from app/projection.py."""
    k = months_ahead(message)
    if k is not None and k >= 1:
        return True
    return bool(re.search(r"\b(susunod na mga buwan|mga susunod na buwan|next months|coming months|projection|"
                          r"ilang buwan|future bill)\b", message.lower()))


def bill_intent(message: str) -> str | None:
    m = message.lower()
    if is_projection(message):
        return None                     # a later month: the projection, not this month's bill rules
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


def is_upgrade(message: str) -> bool:
    """"Kailangan ko ba ng dagdag na battery?": answered from the system check (app/upgrade.py), not live readings."""
    return _hits(message.lower(), KEYWORDS["upgrade"])


def select_facts(message, facts):
    if is_projection(message):
        # Only the projection (+ its limits) and an active brownout/fault: the small model mixed this
        # month's bill into "next month" answers when it saw both.
        return [f for f in facts if f.topic == "projection" or f.id in {"brownout.active", "fault.active"}]
    if is_upgrade(message):
        # Only the system check (+ an active brownout/fault, which always comes first). Live readings and the
        # 48 h outlook made the small model talk about "offline ngayon" instead of the upgrade.
        return [f for f in facts if f.topic == "upgrade" or f.id in {"brownout.active", "fault.active"}]
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
    if is_projection(message):
        found.add("projection")
    if bill_intent(message):
        found.add("bill")
    if "bill" in found:
        found.add("usage")  # "why is my bill high" needs the usage pattern
    if "battery" in found or "brownout" in found:
        found.add("outlook")  # "will my battery last?" depends on tomorrow's sun
    return found | ALWAYS | active
