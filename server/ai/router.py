"""Picks which fact topics go into the prompt for a question.

Fewer facts = shorter prompt (faster on a laptop) and less for a small model to mix up.
Safety-critical facts (an active brownout or fault) are always included.
"""
import re

KEYWORDS: dict[str, tuple[str, ...]] = {
    "bill": ("bill", "bayad", "babayaran", "singil", "mahal", "mataas", "gastos", "magkano", "presyo", "rate", "meralco", "forecast", "buwan", "month"),
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
ALWAYS = {"now"}


def topics_for(message: str, active: set[str]) -> set[str]:
    """`active` = topics with something urgent going on (e.g. {"brownout"} during an outage)."""
    m = message.lower()
    found = {topic for topic, words in KEYWORDS.items() if any(re.search(rf"\b{re.escape(w)}", m) for w in words)}
    if not found - ALWAYS:
        # Vague question ("kumusta?", "ano balita?"): give a broad overview.
        found |= {"today", "bill", "savings"}
    if "bill" in found:
        found |= {"usage", "savings", "today"}  # "why is my bill high" needs the usage pattern
    return found | ALWAYS | active
