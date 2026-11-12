"""Checks for known meaning reversals, not a general natural-language proof."""
import re


MONEY = re.compile(r"(?:₱|PHP|pesos?)\s*[\d,.]+|[\d,.]+\s*pesos?", re.I)
ROLES = {
    "saved": r"\b(?:natipid|savings|saved)\b",
    "cost": r"\b(?:nagastos|ginastos|gastos|spent|cost)\b",
    "forecast": r"\b(?:forecast|inaasahang|projected)\b",
}


def money_role(fact_id):
    if "saved_php" in fact_id or "savings" in fact_id:
        return "saved"
    if fact_id == "bill.forecast_php":
        return "forecast"
    if fact_id.endswith("cost_php") or fact_id in {"bill.month_to_date_php", "bill.last_month_php"}:
        return "cost"
    return None


def problems(reply, fact_ids, facts, numbers_in, matches):
    by = {f.id: f for f in facts}
    cited = [by[i] for i in fact_ids if i in by]
    errors = []
    clauses = re.split(r"[.!?;]\s+|,\s+|\s+(?:at|pero|habang|ngunit|and|but)\s+", reply.lower())
    for clause in clauses:
        # "Nagastos na, hindi forecast" correctly distinguishes the periods.
        positive = re.sub(r"\b(?:hindi|not)\s+(?:a\s+)?forecast\b", "", clause)
        roles = {role for role, pattern in ROLES.items() if re.search(pattern, positive)}
        amounts = [n for m in MONEY.finditer(clause) for n in numbers_in(m.group())]
        if not amounts or not roles:
            continue
        for role in roles:
            allowed = [v for f in cited if money_role(f.id) == role
                       for v in (f.values[:3] if role == "forecast" else f.values[:1])]
            # System-check facts hold both: savings at values[0], installed cost at values[1].
            upgrades = [f for f in cited if f.id.startswith("upgrade.") and len(f.values) >= 2]
            allowed += [f.values[0] for f in upgrades if role == "saved"] + [f.values[1] for f in upgrades if role == "cost"]
            if any(not matches(v, decimals, allowed) for _, v, decimals in amounts):
                errors.append(f"money meaning mismatch ({role}): {clause}")
    # Direction is carried by the backend fact text; sign never comes from the model.
    directions = {
        "now.battery_w": (
            (r"nagcha-charge|\bcharging\b", r"ginagamit|\bdischarging\b|nagdi-discharge"),
            (r"ginagamit|\bdischarging\b|nagdi-discharge", r"nagcha-charge|\bcharging\b")),
        "now.grid_w": (
            (r"kumukuha", r"nagbabalik|exporting|nag-e-export"),
            (r"nagbabalik", r"kumukuha|importing|nag-i-import")),
    }
    for fact_id, rules in directions.items():
        fact = by.get(fact_id)
        if not fact:
            continue
        subject = r"battery|baterya" if "battery" in fact_id else r"grid"
        for clause in clauses:
            if not re.search(subject, clause):
                continue
            for expected, opposite in rules:
                if re.search(expected, fact.text.lower()) and re.search(opposite, clause):
                    errors.append(f"flow direction contradicts {fact_id}: {clause}")
            zero = "hindi gumagalaw" if "battery" in fact_id else "walang kinukuha"
            if zero in fact.text.lower() and re.search(r"nagcha-charge|discharging|nagbabalik|importing|exporting", clause):
                errors.append(f"nonzero flow claimed for {fact_id}: {clause}")
    return errors
