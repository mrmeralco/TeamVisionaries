"""Hallucination guard: checks a model reply against the FACTS it was given.

Rejects the reply if:
  - it quotes a number that is not in any provided fact (or in the user's own question)
  - it cites a fact id that wasn't provided
  - it says it is answerable but cites no facts
  - it is empty or far too long

A rejected reply is never shown to the user: service.py retries once, then uses the rule-based answer.
"""
import re
from dataclasses import dataclass, field

from .facts import Fact
from .router import bill_intent
from . import semantics

MAX_WORDS = 110
# Small counting words are fine ("isang tip", "2 bagay"). Anything else must come from FACTS.
FREE_NUMBERS = {0.0, 1.0, 2.0, 3.0}

_NUM = re.compile(r"(?<![\w.])(\d{1,3}(?:,\d{3})+|\d+)(?:\.(\d+))?")


@dataclass
class GuardResult:
    ok: bool
    problems: list[str] = field(default_factory=list)
    unknown_numbers: list[str] = field(default_factory=list)


def numbers_in(text: str) -> list[tuple[str, float, int]]:
    """[(as written, value, decimals)]. '21:00' gives 21 and 0; '₱1,995' gives 1995."""
    out = []
    for m in _NUM.finditer(text):
        whole, frac = m.group(1), m.group(2)
        out.append((m.group(0), float(whole.replace(",", "") + ("." + frac if frac else "")), len(frac or "")))
    return out


def _matches(x: float, decimals: int, allowed: list[float]) -> bool:
    unit = 10 ** -decimals  # "62%" may stand for 62.4; "2.3" may stand for 2.34
    for v in allowed:
        tol = max(unit, 0.02 * abs(v)) if abs(v) >= 100 else unit  # "mga ₱2,000" for ₱1,994.60 is fine
        if abs(x - v) <= tol + 1e-9:
            return True
    return False


def mentions_value(reply: str, value: float) -> bool:
    return any(_matches(v, decimals, [value]) for _, v, decimals in numbers_in(reply))


def mentions_money(reply: str, value: float) -> bool:
    amounts = re.findall(r"(?:₱|PHP|peso[s]?)\s*[\d,.]+|[\d,.]+\s*peso[s]?", reply, flags=re.I)
    return any(mentions_value(amount, value) for amount in amounts)


def bill_problems(reply: str, fact_ids: list[str], given: list[Fact], question: str) -> list[str]:
    intent = bill_intent(question)
    targets = {"current": ["bill.month_to_date_php"], "forecast": ["bill.forecast_php"],
               "both": ["bill.month_to_date_php", "bill.forecast_php"]}.get(intent, [])
    problems = []
    by = {f.id: f for f in given}
    for target in targets:
        f = by.get(target)
        if f and f.chip:
            amounts = numbers_in(f.chip[1])
            if target not in fact_ids or (amounts and not mentions_money(reply, amounts[0][1])):
                problems.append(f"answer must cite and state {target}: {f.chip[1]}")
    comparison = by.get("bill.vs_last_month_pct")
    if comparison:
        lower = "mas mababa" in comparison.text
        opposite = r"mas mataas|higher|greater" if lower else r"mas mababa|lower|less than"
        if re.search(opposite, reply.lower()):
            problems.append(f"comparison direction contradicts FACTS: {comparison.text}")
    return problems


def check(reply: str, fact_ids: list[str], answerable: bool, given: list[Fact], question: str) -> GuardResult:
    problems: list[str] = []
    ids = {f.id for f in given}

    if not reply.strip():
        problems.append("empty reply")
    if len(reply.split()) > MAX_WORDS:
        problems.append(f"too long ({len(reply.split())} words)")

    bad_ids = [i for i in fact_ids if i not in ids]
    if bad_ids:
        problems.append(f"cites unknown fact ids {bad_ids}")
    if answerable and not fact_ids:
        problems.append("answerable but cites no facts")

    allowed = [v for f in given for v in f.values] + [v for _, v, _ in numbers_in(question)]
    unknown = [raw for raw, v, d in numbers_in(reply) if v not in FREE_NUMBERS and not _matches(v, d, allowed)]
    if unknown:
        problems.append(f"numbers not in FACTS: {unknown}")

    problems.extend(bill_problems(reply, fact_ids, given, question))
    problems.extend(semantics.problems(reply, fact_ids, given, numbers_in, _matches))
    urgent = {"brownout" if f.id.startswith("brownout") else "fault" for f in given
              if f.id in {"brownout.active", "fault.active"} and f.text.startswith("MAY ")}
    remaining = set(urgent)
    for sentence in re.split(r"[.!?]\s+", reply.lower()):
        if not remaining:
            break
        mentioned = {word for word in remaining if word in sentence}
        if not mentioned:
            break
        remaining -= mentioned
    for keyword in sorted(remaining):
        problems.append(f"mention active {keyword} before other information")
    for keyword in urgent:
        if re.search(rf"\b(?:walang|no)\s+(?:active\s+)?{keyword}\b", reply.lower()):
            problems.append(f"denies active {keyword}")
    m = question.lower()
    live_question = any(w in m for w in ("solar", "battery", "baterya", "grid")) and not any(
        w in m for w in ("kahapon", "yesterday", "oras", "peak", "week", "linggo", "natipid", "savings"))
    offline = any(f.id == "now.online" and f.text.startswith("OFFLINE") for f in given)
    if live_question and offline and not any(w in reply.lower() for w in ("offline", "luma", "huling data")):
        problems.append("live readings are stale: mention offline or old data")

    return GuardResult(ok=not problems, problems=problems, unknown_numbers=unknown)
