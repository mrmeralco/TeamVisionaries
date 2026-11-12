"""AI service: question -> facts from SQLite -> Qwen 3.5 -> hallucination guard -> reply.

    /api/chat            -> chat()
    /api/summary/daily   -> daily_summary()  (pre-generated, cached per date)

Pipeline (see server/ai/README.md):
  1. facts.gather()     compute every fact from the DB (the model never calculates)
  2. router.topics_for  keep only the facts this question needs (+ brownout/fault if active)
     answers.direct_answer returns recognized simple lookups without calling the model
  3. llm.complete_json  Qwen 3.5, thinking off, temperature 0, JSON schema output, must cite fact ids
  4. guard.check        reject replies with numbers/ids not in the facts given
  5. one retry with the guard's complaint, else a rule-based answer built from the same facts
Every exchange is logged to server/logs/ai.jsonl for QA.
"""
import json
import logging
import re
import time
from datetime import timedelta

from app import config, db, energy

from . import answers, guard, llm, prompts, router, sources, style
from .facts import METER_ONLY, Fact, FactSet, gather

log = logging.getLogger("solaris.ai")

MAX_CHIPS = 4


# --------------------------------------------------------------- pipeline --
def clean_id(raw) -> str:
    """The prompt shows facts as "[bill.forecast_php] ...", and Qwen often cites them with the brackets.
    Strip them so a correct citation isn't rejected; the guard still checks the id was actually given."""
    return str(raw).strip().strip("[]`'\"").strip()


def _active_topics(fs: FactSet) -> set[str]:
    by = fs.by_id()
    active = set()
    if by.get("brownout.active") and by["brownout.active"].values:
        active.add("brownout")
    if by.get("fault.active") and by["fault.active"].values:
        active.add("fault")
    return active


def _chips(cited: list[str], fs: FactSet) -> list[dict]:
    by = fs.by_id()
    # Only numbers the answer actually used. No default chips: under "hindi ko alam" or "hindi ko kaya lampas
    # 3 buwan", this month's bill and battery looked like the answer to the question.
    ids = [i for i in cited if i in by and by[i].chip]
    return [{"label": by[i].chip[0], "value": by[i].chip[1]} for i in ids[:MAX_CHIPS] if by[i].chip]


def _log(entry: dict) -> None:
    try:
        config.AI_LOG.parent.mkdir(parents=True, exist_ok=True)
        with config.AI_LOG.open("a", encoding="utf-8") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
    except OSError as e:
        log.warning("could not write AI log: %s", e)


async def ask(question: str, given: list[Fact], fallback_text: str, task: bool = False,
              fallback_ids: list[str] | None = None) -> dict:
    """Runs steps 3-5 for any task. Returns {reply, fact_ids, source, answerable, ...}.

    task=True: `question` is the app's own instruction (e.g. the daily recap), not user text. It is sent
    outside <tanong> so rule 8 doesn't make the model ignore it, and a refusal counts as a failure
    (retry, then fallback) instead of becoming the OUT_OF_SCOPE reply."""
    t0 = time.monotonic()
    template = prompts.TASK_USER if task else prompts.CHAT_USER
    messages = [{"role": "user", "content": template.format(facts=prompts.render_facts(given), message=question)}]
    attempts = []
    for attempt in range(2):
        if attempt and time.monotonic() - t0 > config.CHAT_BUDGET_S - config.LLM_TIMEOUT_S:
            break  # no time left for a retry
        try:
            out = await llm.complete_json(prompts.SYSTEM, messages, prompts.REPLY_SCHEMA)
        except llm.LLMUnavailable as e:
            attempts.append({"error": str(e)})
            break
        reply = style.polish(str(out.get("reply", "")), style.user_name(given))
        ids = [clean_id(i) for i in out.get("fact_ids") or []]
        answerable = bool(out.get("answerable", True))
        must_answer = task or (router.is_upgrade(question) and any(f.id.startswith("upgrade.") for f in given)) \
            or any(f.id in ("solar_plan.recommended", "solar_plan.not_ready") for f in given)
        if not answerable and must_answer:
            attempts.append({"raw": out, "guard": "refused an answerable question"})
            log.warning("model refused, but FACTS answer it: %s", reply[:160])
            messages += [{"role": "assistant", "content": json.dumps(out, ensure_ascii=False)},
                         {"role": "user", "content": prompts.TASK_RETRY_NOTE if task else prompts.ANSWER_RETRY_NOTE}]
            continue
        if not answerable:
            attempts.append({"raw": out, "guard": "out_of_scope"})
            refusal = prompts.OUT_OF_SCOPE_METER if any(f.id == METER_ONLY for f in given) else prompts.OUT_OF_SCOPE
            return {"reply": refusal, "fact_ids": [], "source": "llm", "answerable": False,
                    "attempts": attempts, "latency_s": round(time.monotonic() - t0, 2)}
        g = guard.check(reply, ids, answerable, given, question)
        attempts.append({"raw": out, "guard": "ok" if g.ok else g.problems})
        if g.ok:
            return {"reply": reply, "fact_ids": ids, "source": "llm", "answerable": True,
                    "attempts": attempts, "latency_s": round(time.monotonic() - t0, 2)}
        log.warning("guard rejected reply (%s): %s", "; ".join(g.problems), reply[:160])
        messages += [{"role": "assistant", "content": json.dumps(out, ensure_ascii=False)},
                     {"role": "user", "content": prompts.RETRY_NOTE.format(problems="; ".join(g.problems))}]
    return {"reply": fallback_text, "fact_ids": list(fallback_ids or []), "source": "fallback", "answerable": True,
            "attempts": attempts, "latency_s": round(time.monotonic() - t0, 2)}


# -------------------------------------------------------------------- chat --
# Rule-based answers: the facts' own sentences, picked by topic. Always grounded, never creative.
FALLBACK_IDS = {
    "fault": ("fault.active", "now.temp_c"),
    "brownout": ("brownout.active", "brownout.advice"),  # advice already states the runtime
    "bill": ("bill.month_to_date_php", "bill.forecast_php", "usage.peak_hours", "household.new_load"),
    "savings": ("today.saved_php", "bill.savings_month_php"),
    "yesterday": ("yesterday.solar_kwh", "yesterday.cost_php", "yesterday.saved_php"),
    "outlook": ("outlook.advice",),
    "battery": ("now.battery_pct", "now.battery_w"),
    "usage": ("household.new_load", "usage.peak_hours", "week.grid_kwh", "week.self_sufficiency_pct"),
    "household": ("household.now", "household.routine"),
    "alerts": ("alerts.unread",),
    "upgrade": ("upgrade.verdict", "upgrade.battery", "upgrade.solar", "upgrade.inverter", "upgrade.usage"),
    "projection": ("projection.m1", "projection.m2", "projection.m3", "projection.limits"),
    "today": ("today.solar_kwh", "today.cost_php", "today.saved_php"),
    "now": ("now.solar_w", "now.load_w", "now.grid_w"),
}
# A meter-only home has no solar or battery facts: these replace the topics that would otherwise use them.
FALLBACK_IDS_METER_ONLY = {
    "savings": ("meter.tier", "meter.base_load"),
    "yesterday": ("yesterday.load_kwh", "yesterday.cost_php"),
    "today": ("today.load_kwh", "today.cost_php"),
    "usage": ("usage.peak_hours", "week.grid_kwh", "meter.base_load"),
    "now": ("now.load_w", "now.voltage_v"),
}
FALLBACK_IDS["meter"] = ("meter.reading", "meter.voltage")
FALLBACK_IDS["solar_plan"] = ("solar_plan.not_ready", "solar_plan.recommended", "solar_plan.alternative", "solar_plan.limits")
# Topics that also get the meter facts (Meralco level, always-on use) when the home has a meter.
METER_TOPICS = {"bill", "savings", "usage", "household"}
# "now" is last: every question includes it, so it only answers when nothing more specific was asked.
FALLBACK_ORDER = ("fault", "brownout", "solar_plan", "upgrade", "bill", "savings", "yesterday", "outlook", "battery", "household", "usage", "meter", "alerts", "today", "now")


def fallback_reply(asked: set[str], active: set[str], fs: FactSet, message: str = "") -> tuple[str, list[str]]:
    """Urgent items first (one line each), then the facts for what was actually asked.
    Returns the reply and the ids of the facts it used (the answer's sources)."""
    by = fs.by_id()
    meter_only = METER_ONLY in by
    urgent = [f"{t}.active" for t in ("fault", "brownout") if t in active and t not in asked]
    lines = [by[i].spoken.split(". ")[0] for i in urgent]
    ids = list(urgent)
    for topic in FALLBACK_ORDER:
        if topic in asked:
            want = (FALLBACK_IDS_METER_ONLY.get(topic) if meter_only else None) or FALLBACK_IDS[topic]
            if topic == "meter" and re.search(r"volt|boltahe", message.lower()):
                want = ("meter.voltage", "now.power_factor")
            used = [i for i in want if i in by]
            if not used and (meter_only or topic == "solar_plan"):
                continue   # e.g. "battery" in a home without one: answer the next thing asked
            lines += [by[i].spoken for i in used]
            ids += used
            break
    if not lines:
        lines, ids = [by["now.status"].spoken], ["now.status"]
    return answers.join_spoken(lines), ids


async def chat(device_id: str, settings: dict, message: str) -> dict:
    started = time.monotonic()
    fs = gather(device_id, settings)
    active = _active_topics(fs)
    asked = router.topics_for(message, set())
    if asked & METER_TOPICS and any(f.topic == "meter" for f in fs.facts):
        asked.add("meter")
    topics = asked | active
    # The meter-only marker always goes in: it is how the model (and the guard) know there is no solar.
    # (Not for a question about getting solar: the plan facts already say there is none yet, and beside the
    # marker the small model refused, "Smart meter lang ang binabasa natin".)
    plan_q = router.is_solar_plan(message) and any(f.topic == "solar_plan" for f in fs.facts)
    extra = ("user.name",) if plan_q else ("user.name", METER_ONLY)
    given = router.select_facts(message, fs.select(topics)) + [f for f in fs.facts if f.id in extra]
    given = list({f.id: f for f in given}.values())
    fallback, fallback_ids = fallback_reply(asked, active, fs, message)
    intent = router.bill_intent(message)
    if intent in {"current", "forecast", "last_month", "comparison", "both"}:
        targets = {"current": ["bill.month_to_date_php"], "forecast": ["bill.forecast_php"],
                   "last_month": ["bill.last_month_php"], "comparison": ["bill.last_month_php", "bill.forecast_php", "bill.vs_last_month_pct"],
                   "both": ["bill.month_to_date_php", "bill.forecast_php"]}[intent]
        fallback_ids = [f"{t}.active" for t in ("fault", "brownout") if t in active]
        fallback_ids += [target for target in targets if target in fs.by_id()]
        fallback = answers.join_spoken([fs.by_id()[i].spoken for i in fallback_ids])
    if "now" in asked and not router.is_upgrade(message) and not router.is_solar_plan(message) and any(
            w in message.lower() for w in ("solar", "battery", "baterya", "grid", "ngayon", "now")):
        offline = fs.by_id().get("now.online")
        if offline and offline.text.startswith("OFFLINE"):
            fallback += " " + offline.spoken
            fallback_ids.append("now.online")
    if router.is_projection(message) and "projection.limits" in fs.by_id():
        # Rule-based answer for a later month: that month's projection + the caveat, or past the limit,
        # why it can't be projected + the furthest month that can.
        by = fs.by_id()
        k = router.months_ahead(message)
        if k is not None and f"projection.m{k}" in by:
            fallback_ids = [f"projection.m{k}", "projection.limits"]
        elif k is not None:
            furthest = max((i for i in by if i.startswith("projection.m")), default=None)
            fallback_ids = ["projection.limits"] + ([furthest] if furthest else [])
        else:
            fallback_ids = [i for i in ("projection.m1", "projection.m2", "projection.m3", "projection.limits") if i in by]
        urgent = [f"{t}.active" for t in ("fault", "brownout") if t in active]
        fallback_ids = urgent + fallback_ids
        fallback = answers.join_spoken([by[i].spoken for i in fallback_ids])
    r = answers.direct_answer(message, given)
    if r is None:
        r = await ask(message, given, fallback, fallback_ids=fallback_ids)
    else:
        r["latency_s"] = round(time.monotonic() - started, 3)
    _log({"ts": int(time.time()), "task": "chat", "question": message, "topics": sorted(topics),
          "facts": [f.id for f in given], "strategy": r.get("strategy", "model"),
          **{k: r[k] for k in ("reply", "source", "fact_ids", "attempts", "latency_s")}})
    # The fallback may use facts the router didn't put in the prompt, so look them up in the full set.
    return {"reply": r["reply"], "chips": _chips(r["fact_ids"], fs), "source": r["source"], "facts_used": r["fact_ids"],
            "sources": sources.build(r["fact_ids"], fs.by_id(), fs.measured_ts, int(time.time()))}


# ------------------------------------------------------------ daily summary --
async def daily_summary(device_id: str, settings: dict, force: bool = False, upgrade: bool = False) -> dict:
    """Cached per date. A cached fallback is served as-is (the app must never wait on a down LLM);
    only the background task passes upgrade=True to retry the LLM and replace it."""
    d = energy.today() - timedelta(days=1)
    solar = energy.has_solar(settings)
    key = f"summary:{device_id}:{d.isoformat()}" + ("" if solar else ":meter_only")
    cached = db.get_kv(key)
    if cached and cached.pop("_rate_php_per_kwh", None) != settings["rate_php_per_kwh"]:
        cached = None  # A newly published rate changes the recap's cost and savings.
    if cached and cached["summary"] == prompts.OUT_OF_SCOPE:
        cached = None  # cached by an older version that let the model refuse the recap; regenerate it
    if cached and not force and (cached["source"] == "llm" or not upgrade or not config.LLM_ENABLED):
        return cached

    fs = gather(device_id, settings)
    given = fs.select({"yesterday"}) + [f for f in fs.facts if f.id in ("user.name", METER_ONLY)]
    by = fs.by_id()
    if solar:
        fallback = prompts.summary_fallback(by["yesterday.self_sufficiency_pct"].values[0],
                                            by["yesterday.cost_php"].chip[1], by["yesterday.saved_php"].chip[1])
    else:
        fallback = prompts.summary_fallback_meter(f"{by['yesterday.load_kwh'].values[0]:.1f} kWh", by["yesterday.cost_php"].chip[1])
    r = await ask(prompts.SUMMARY_TASK if solar else prompts.SUMMARY_TASK_METER, given, fallback, task=True)
    _log({"ts": int(time.time()), "task": "summary", "date": d.isoformat(), "facts": [f.id for f in given],
          **{k: r[k] for k in ("reply", "source", "fact_ids", "attempts", "latency_s")}})

    tot = energy.day_totals(device_id, d, energy.flow_source(settings))
    rate = settings["rate_php_per_kwh"]
    out = {
        "date": d.isoformat(), "summary": r["reply"], "source": r["source"],
        "totals": {"pv_kwh": round(tot["pv_kwh"], 2), "load_kwh": round(tot["load_kwh"], 2),
                   "grid_import_kwh": round(tot["grid_import_kwh"], 2),
                   "cost_php": round(tot["grid_import_kwh"] * rate, 2),
                   "savings_php": round(energy.saved_kwh(tot) * rate, 2),
                   "self_sufficiency_pct": energy.self_sufficiency(tot)},
    }
    db.put_kv(key, out | {"_rate_php_per_kwh": settings["rate_php_per_kwh"]})
    return out
