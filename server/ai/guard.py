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

    return GuardResult(ok=not problems, problems=problems, unknown_numbers=unknown)
