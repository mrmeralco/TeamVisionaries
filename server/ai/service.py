"""AI service: question -> facts from SQLite -> Qwen 3.5 -> hallucination guard -> reply.

    /api/chat            -> chat()
    /api/summary/daily   -> daily_summary()  (pre-generated, cached per date)

Pipeline (see server/ai/README.md):
  1. facts.gather()     compute every fact from the DB (the model never calculates)
  2. router.topics_for  keep only the facts this question needs (+ brownout/fault if active)
  3. llm.complete_json  Qwen 3.5, thinking off, temperature 0, JSON schema output, must cite fact ids
  4. guard.check        reject replies with numbers/ids not in the facts given
  5. one retry with the guard's complaint, else a rule-based answer built from the same facts
Every exchange is logged to server/logs/ai.jsonl for QA.
"""
import json
import logging
import time
from datetime import timedelta

from app import config, db, energy

from . import guard, llm, prompts, router
from .facts import Fact, FactSet, gather

log = logging.getLogger("sinag.ai")

DEFAULT_CHIPS = ("bill.month_to_date_php", "bill.forecast_php", "today.saved_php", "now.battery_pct")
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
    ids = [i for i in cited if i in by and by[i].chip] or [i for i in DEFAULT_CHIPS if i in by]
    return [{"label": by[i].chip[0], "value": by[i].chip[1]} for i in ids[:MAX_CHIPS] if by[i].chip]


def _log(entry: dict) -> None:
    try:
        config.AI_LOG.parent.mkdir(parents=True, exist_ok=True)
        with config.AI_LOG.open("a", encoding="utf-8") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
    except OSError as e:
        log.warning("could not write AI log: %s", e)


async def ask(question: str, given: list[Fact], fallback_text: str) -> dict:
    """Runs steps 3-5 for any task. Returns {reply, fact_ids, source, answerable, ...}."""
    t0 = time.monotonic()
    messages = [{"role": "user", "content": prompts.CHAT_USER.format(facts=prompts.render_facts(given), message=question)}]
    attempts = []
    for attempt in range(2):
        if attempt and time.monotonic() - t0 > config.CHAT_BUDGET_S - config.LLM_TIMEOUT_S:
            break  # no time left for a retry
        try:
            out = await llm.complete_json(prompts.SYSTEM, messages, prompts.REPLY_SCHEMA)
        except llm.LLMUnavailable as e:
            attempts.append({"error": str(e)})
            break
        reply = str(out.get("reply", "")).strip()
        ids = [clean_id(i) for i in out.get("fact_ids") or []]
        answerable = bool(out.get("answerable", True))
        if not answerable:
            attempts.append({"raw": out, "guard": "out_of_scope"})
            return {"reply": prompts.OUT_OF_SCOPE, "fact_ids": [], "source": "llm", "answerable": False,
                    "attempts": attempts, "latency_s": round(time.monotonic() - t0, 2)}
        g = guard.check(reply, ids, answerable, given, question)
        attempts.append({"raw": out, "guard": "ok" if g.ok else g.problems})
        if g.ok:
            return {"reply": reply, "fact_ids": ids, "source": "llm", "answerable": True,
                    "attempts": attempts, "latency_s": round(time.monotonic() - t0, 2)}
        log.warning("guard rejected reply (%s): %s", "; ".join(g.problems), reply[:160])
        messages += [{"role": "assistant", "content": json.dumps(out, ensure_ascii=False)},
                     {"role": "user", "content": prompts.RETRY_NOTE.format(problems="; ".join(g.problems))}]
    return {"reply": fallback_text, "fact_ids": [], "source": "fallback", "answerable": True,
            "attempts": attempts, "latency_s": round(time.monotonic() - t0, 2)}


# -------------------------------------------------------------------- chat --
# Rule-based answers: the facts' own sentences, picked by topic. Always grounded, never creative.
FALLBACK_IDS = {
    "fault": ("fault.active", "now.temp_c"),
    "brownout": ("brownout.active", "brownout.advice"),  # advice already states the runtime
    "bill": ("bill.month_to_date_php", "bill.forecast_php", "usage.peak_hours"),
    "savings": ("today.saved_php", "bill.savings_month_php"),
    "yesterday": ("yesterday.solar_kwh", "yesterday.cost_php", "yesterday.saved_php"),
    "outlook": ("outlook.advice",),
    "battery": ("now.battery_pct", "now.battery_w"),
    "usage": ("usage.peak_hours", "week.grid_kwh", "week.self_sufficiency_pct"),
    "alerts": ("alerts.unread",),
    "today": ("today.solar_kwh", "today.cost_php", "today.saved_php"),
    "now": ("now.solar_w", "now.load_w", "now.grid_w"),
}
# "now" is last: every question includes it, so it only answers when nothing more specific was asked.
FALLBACK_ORDER = ("fault", "brownout", "bill", "savings", "yesterday", "outlook", "battery", "usage", "alerts", "today", "now")


def fallback_reply(asked: set[str], active: set[str], fs: FactSet) -> str:
    """Urgent items first (one line each), then the facts for what was actually asked."""
    by = fs.by_id()
    lines = [by[f"{t}.active"].text.split(". ")[0] for t in ("fault", "brownout") if t in active and t not in asked]
    for topic in FALLBACK_ORDER:
        if topic in asked:
            lines += [by[i].text for i in FALLBACK_IDS[topic] if i in by]
            break
    if not lines:
        lines = [by["now.status"].text]
    return ". ".join(line.rstrip(".") for line in lines) + "."


async def chat(device_id: str, settings: dict, message: str) -> dict:
    fs = gather(device_id, settings)
    active = _active_topics(fs)
    asked = router.topics_for(message, set())
    topics = asked | active
    given = fs.select(topics) + [f for f in fs.facts if f.id == "user.name"]
    given = list({f.id: f for f in given}.values())
    r = await ask(message, given, fallback_reply(asked, active, fs))
    _log({"ts": int(time.time()), "task": "chat", "question": message, "topics": sorted(topics),
          "facts": [f.id for f in given], **{k: r[k] for k in ("reply", "source", "fact_ids", "attempts", "latency_s")}})
    return {"reply": r["reply"], "chips": _chips(r["fact_ids"], fs), "source": r["source"], "facts_used": r["fact_ids"]}


# ------------------------------------------------------------ daily summary --
async def daily_summary(device_id: str, settings: dict, force: bool = False, upgrade: bool = False) -> dict:
    """Cached per date. A cached fallback is served as-is (the app must never wait on a down LLM);
    only the background task passes upgrade=True to retry the LLM and replace it."""
    d = energy.today() - timedelta(days=1)
    key = f"summary:{device_id}:{d.isoformat()}"
    cached = db.get_kv(key)
    if cached and not force and (cached["source"] == "llm" or not upgrade or not config.LLM_ENABLED):
        return cached

    fs = gather(device_id, settings)
    given = fs.select({"yesterday"}) + [f for f in fs.facts if f.id == "user.name"]
    by = fs.by_id()
    fallback = (f"{by['yesterday.self_sufficiency_pct'].text}. {by['yesterday.cost_php'].text}. "
                f"{by['yesterday.saved_php'].text}. Tip: gamitin ang washing machine at plantsa habang maaraw.")
    r = await ask(prompts.SUMMARY_TASK, given, fallback)
    _log({"ts": int(time.time()), "task": "summary", "date": d.isoformat(), "facts": [f.id for f in given],
          **{k: r[k] for k in ("reply", "source", "fact_ids", "attempts", "latency_s")}})

    tot = energy.day_totals(device_id, d)
    rate = settings["rate_php_per_kwh"]
    out = {
        "date": d.isoformat(), "summary": r["reply"], "source": r["source"],
        "totals": {"pv_kwh": round(tot["pv_kwh"], 2), "load_kwh": round(tot["load_kwh"], 2),
                   "grid_import_kwh": round(tot["grid_import_kwh"], 2),
                   "cost_php": round(tot["grid_import_kwh"] * rate, 2),
                   "savings_php": round(energy.saved_kwh(tot) * rate, 2),
                   "self_sufficiency_pct": energy.self_sufficiency(tot)},
    }
    db.put_kv(key, out)
    return out
