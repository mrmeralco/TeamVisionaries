"""Small, safe wording fixes for habits the 4B model keeps despite the prompt.

Only removes or swaps words; never adds, removes or changes a number. Runs before the guard, so the
guard still checks the exact text the user sees.
"""
import re

AMOUNT = r"(?:₱\s?[\d,]+(?:\.\d+)?|\d+(?:\.\d+)?\s?(?:kWh|kW|W|%))"
FIXES = (
    # "₱1,280 lang ang natipid mo" belittles good news; without "lang" it is neutral either way.
    (re.compile(rf"({AMOUNT})\s+lang\b"), r"\1"),
    # Devices aren't people: "si Solaris device" -> "ang Solaris device", "si Solar" -> "ang solar".
    (re.compile(r"\b([Ss])i Solaris\b"), lambda m: ("A" if m.group(1) == "S" else "a") + "ng Solaris"),
    (re.compile(r"\b([Ss])i Solar\b"), lambda m: ("A" if m.group(1) == "S" else "a") + "ng solar"),
    # Common grammar slip: "Hindi may brownout" -> "Walang brownout".
    (re.compile(r"\b([Hh])indi may\b"), lambda m: ("W" if m.group(1) == "H" else "w") + "alang"),
)


def user_name(facts) -> str | None:
    f = next((f for f in facts if f.id == "user.name"), None)
    return f.text.split(":", 1)[1].strip() if f and ":" in f.text else None


def polish(reply: str, name: str | None = None) -> str:
    text = reply.strip()
    if name:
        # The prompt says to use the name rarely; the model still opens most replies with "Juan, ".
        text = re.sub(rf"^{re.escape(name)}\s*[,!]\s*", "", text)
    for pattern, repl in FIXES:
        text = pattern.sub(repl, text)
    text = re.sub(r"\s{2,}", " ", text)
    return text[:1].upper() + text[1:]
