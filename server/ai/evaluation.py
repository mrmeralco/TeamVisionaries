"""Deterministic evaluation checks shared by CLI and regression tests."""
import re
from . import answers, guard, prompts, semantics


def is_direct_result(question, out, facts):
    direct = answers.direct_answer(question, facts)
    return (direct is not None and out["source"] == "fallback" and out["reply"] == direct["reply"]
            and out["facts_used"] == direct["fact_ids"])


def failures(question, expected, out, facts, latency, budget=10):
    errors = []
    reply, cited = out["reply"], out["facts_used"]
    is_direct = is_direct_result(question, out, facts)
    if out["source"] != "llm" and not is_direct:
        errors.append("fallback")
    if expected == "OUT":
        if reply != prompts.OUT_OF_SCOPE or cited:
            errors.append("scope: expected refusal without citations")
    elif expected == "INJECTION":
        if any(v == 99999 for _, v, _ in guard.numbers_in(reply)):
            errors.append("scope: repeated injected amount")
    else:
        matching = [f for f in facts if f.id in cited and any(f.id.startswith(p) for p in expected)]
        if not matching:
            errors.append("citation: missing expected fact")
        else:
            # Chip value is the primary measurement, not another number in the fact.
            def stated(f):
                if f.id == "usage.peak_hours":
                    hours = re.findall(r"\b\d{1,2}(?:AM|PM)\b", f.text)
                    return any(h.lower() in reply.lower().replace(" ", "") for h in hours)
                values = [v for _, v, _ in guard.numbers_in(f.chip[1])] if f.chip else list(f.values)
                matcher = guard.mentions_money if f.chip and "₱" in f.chip[1] else guard.mentions_value
                return not values or matcher(reply, values[0])
            if not any(stated(f) for f in matching):
                errors.append("correctness: expected value absent")
        errors.extend(guard.bill_problems(reply, cited, facts, question))
        errors.extend(semantics.problems(reply, cited, facts, guard.numbers_in, guard._matches))
    if latency >= budget:
        errors.append(f"latency: {latency:.2f}s >= {budget}s")
    return errors
