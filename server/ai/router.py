"""Picks which fact topics go into the prompt for a question.

Fewer facts = shorter prompt (faster on a laptop) and less for a small model to mix up.
Safety-critical facts (an active brownout or fault) are always included.
"""
import re

KEYWORDS: dict[str, tuple[str, ...]] = {
    "bill": ("bill", "bayad", "babayaran", "singil", "rate", "meralco", "forecast", "buwan", "month"),
    "savings": ("tipid", "natipid", "savings", "save", "sulit", "balik"),
    "today": ("ngayong araw", "today", "kanina", "ngayon araw"),
    "yesterday": ("kahapon", "yesterday"),
    "usage": ("gamit", "konsumo", "usage", "peak", "oras", "linggo", "week", "pattern", "appliance", "aircon"),
    "battery": ("battery", "baterya", "charge", "soc", "tatagal", "runtime"),
    "brownout": ("brownout", "blackout", "walang kuryente", "nawalan", "outage", "power interruption"),
    "fault": ("fault", "error", "sira", "problema", "init", "mainit", "temperature", "overheat", "code"),
    "alerts": ("alert", "abiso", "notification", "babala"),
    "now": ("ngayon", "now", "solar", "araw", "panel", "grid", "live"),
}
# Cost words that mean "bill" only when nothing more specific was asked:
# "Bakit mahal?" is about the bill, "Magkano kinuha ko sa grid kahapon?" is about yesterday.
WEAK_BILL = ("magkano", "mahal", "mataas", "gastos", "presyo")
ALWAYS = {"now"}


def _hits(m: str, words: tuple[str, ...]) -> bool:
    return any(re.search(rf"\b{re.escape(w)}", m) for w in words)


def topics_for(message: str, active: set[str]) -> set[str]:
    """`active` = topics with something urgent going on (e.g. {"brownout"} during an outage)."""
    m = message.lower()
    found = {topic for topic, words in KEYWORDS.items() if _hits(m, words)}
    if _hits(m, WEAK_BILL) and not found - ALWAYS:
        found.add("bill")
    if not found:
        # Vague question ("kumusta?", "ano balita?"): give a broad overview.
        found = {"today", "bill", "savings"}
    if "bill" in found:
        found.add("usage")  # "why is my bill high" needs the usage pattern
    return found | ALWAYS | active
