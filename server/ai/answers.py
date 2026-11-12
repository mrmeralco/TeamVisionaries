"""Conservative direct lookups. Explanations and unmatched requests still use the LLM."""
import re

from .facts import Fact


LOOKUPS = (
    (r"magkano (?:ang )?forecast(?: ng bill ko)?", ("bill.forecast_php",)),
    (r"(?:magkano na (?:ang )?bill ko(?: ngayong buwan)?|how much have i spent so far|bill so far)", ("bill.month_to_date_php",)),
    (r"(?:ilang (?:porsyento|percent)(?: na)? (?:ang )?(?:battery|baterya) ko|battery percentage)", ("now.battery_pct",)),
    (r"(?:ilang watts (?:ang )?solar(?: ngayon)?|solar power now)", ("now.solar_w",)),
    (r"(?:nagcha-charge ba (?:ang )?battery ko|is my battery charging)", ("now.battery_w",)),
    (r"(?:kumukuha ba ako (?:ng kuryente )?sa grid|am i importing or exporting power)", ("now.grid_w",)),
    (r"magkano (?:ang )?natipid ko(?: dahil sa solar)?", ("today.saved_php", "bill.savings_month_php")),
    (r"magkano (?:ang )?natipid ko (?:ngayon|ngayong araw)", ("today.saved_php",)),
    (r"magkano (?:ang )?natipid ko ngayong buwan", ("bill.savings_month_php",)),
)


TIME_OPENERS = ("Kahapon, ", "Ngayong araw, ", "Ngayong buwan, ", "Sa huling 7 araw, ")


def join_spoken(sentences: list[str]) -> str:
    """Join fact sentences into one reply, dropping a time opener the previous sentence already set:
    "Kahapon, 17.6 kWh ... ₱46 ang nagastos mo ..." instead of "Kahapon, ... Kahapon, ...". """
    out, prev = [], None
    for raw in sentences:
        line = raw.strip().rstrip(".")
        opener = next((o for o in TIME_OPENERS if line.startswith(o)), None)
        if opener and opener == prev:
            rest = line[len(opener):]
            line = rest[:1].upper() + rest[1:]
        prev = opener
        out.append(line + ".")
    return " ".join(out)


def direct_ids(question: str) -> tuple[str, ...]:
    normalized = re.sub(r"\s+", " ", question.lower()).strip().rstrip("?.!").strip()
    for pattern, ids in LOOKUPS:
        if re.fullmatch(pattern, normalized):
            return ids
    return ()


def direct_answer(question: str, facts: list[Fact]) -> dict | None:
    targets = direct_ids(question)
    if not targets:
        return None
    by = {f.id: f for f in facts}
    ids = [i for i in ("fault.active", "brownout.active") if i in by and by[i].text.startswith("MAY ")]
    live = any(i.startswith("now.") for i in targets)
    if not all(i in by for i in targets):
        # A device without telemetry has no live measurement to quote.
        if not live or "now.status" not in by:
            return None
        ids.append("now.status")
    else:
        ids.extend(targets)
    if live and "now.online" in by and by["now.online"].text.startswith("OFFLINE"):
        ids.append("now.online")  # after the reading: "Nasa 78% ang battery mo. Offline ..., kaya luma na ..."
    reply = join_spoken([by[i].spoken for i in ids])
    return {"reply": reply, "fact_ids": ids, "source": "fallback", "answerable": True,
            "attempts": [], "latency_s": 0.0, "strategy": "direct"}
