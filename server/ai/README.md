# Sinag AI: implementation guide

**Owner: Andy.** This folder is the "Ask Sinag" chat (`POST /api/chat`) and the daily recap
(`GET /api/summary/daily`). It runs **Qwen 3.5 locally on Ollama**, so it works with no internet.

The pipeline already works end to end. Your job is to get Qwen 3.5 running on the server laptop, tune it,
and add facts for the questions the demo needs.

---

## 1. The one rule: the model never knows anything on its own

A small model **will** make up numbers if you let it ("₱3,500 ang bill mo!"). So it never gets the chance:

```
 question ──► router.py ──► facts.py ──► Qwen 3.5 ──► guard.py ──► reply to app
             pick topics    compute       rephrase      check every       │
                            from SQLite   + cite ids    number & id       │
                                                           │ fail         │
                                                           ▼              │
                                                    retry once with   ────┤
                                                    the complaint         │
                                                           │ fail again   │
                                                           ▼              │
                                                    rule-based answer ────┘
                                                    (fact sentences)
```

| Layer | File | What it does against hallucination |
|---|---|---|
| **Facts from the DB** | `facts.py` | Every number is computed by the backend from SQLite (`app/energy.py`) and written as a ready sentence: `[bill.forecast_php] Forecast ...: mga ₱1,995`. The model copies; it never calculates. |
| **Only relevant facts** | `router.py` | A bill question gets bill + usage facts, not 40 lines. Small models mix things up less with a short prompt. An active **brownout or fault is always included**. |
| **Strict prompt** | `prompts.py` | "Only FACTS. Every number must come from FACTS. Not in FACTS → `answerable: false`." The user's text sits inside `<tanong>` and can't override the rules. |
| **Structured output** | `llm.py` | Ollama's `format` = JSON schema forces `{"answerable", "reply", "fact_ids"}`. The model must **cite** the fact ids it used. |
| **Deterministic** | `llm.py` | `temperature 0`, fixed `seed`, `think: false`. Same data + same question = same answer. |
| **Guard** | `guard.py` | Pulls every number out of the reply and checks it against the values of the facts it was given (rounding allowed: "mga ₱2,000" for ₱1,994.60 passes; "₱3,500" fails). Rejects unknown fact ids and replies that cite nothing. |
| **Retry, then fallback** | `service.py` | One retry tells the model exactly which number was wrong. If it fails again, the app gets a rule-based answer built from the same facts. **An unchecked LLM reply never reaches the app.** |
| **Out of scope** | `service.py` | `answerable: false` → fixed reply: "Pasensya na, hindi ko pa alam iyan ...". |
| **Audit log** | `logs/ai.jsonl` | Every question, the facts given, the raw model output, guard verdicts, latency. Use it to debug. |

Data chips in the app (`chips[]`) come from the **facts the model cited**, never from the model's text.
Brownout advice and fault explanations are rule-based on purpose (`prompts.brownout_advice`, `faults.py`):
safety text must be correct, not creative.

**What the guard can't catch:** a wrong claim with no number in it ("naka-on ang aircon mo"). The strict
prompt, the short fact list and temperature 0 keep this rare. Read `logs/ai.jsonl` during testing and
tighten the prompt if you see one.

---

## 2. Setup on the server laptop (do this first)

Pick the size by the laptop's RAM:

| RAM | Model | Download | Notes |
|---|---|---|---|
| 8 GB | `qwen3.5:4b` (default) | 3.3 GB | Good Taglish, ~5–10 s per answer on Apple Silicon |
| 16 GB+ | `qwen3.5:9b` | 6.6 GB | Better at following the rules. Use it if answers stay under 10 s |
| very slow laptop | `qwen3.5:2b` | 1.9 GB | Weaker; expect more fallbacks |

```bash
ollama pull qwen3.5:4b
```

```bash
cd server && cp .env.example .env     # set LLM_MODEL if you picked another size
```

```bash
source .venv/bin/activate && pip install -r requirements.txt -r requirements-dev.txt
```

```bash
python tools/seed_history.py          # fake history so there are facts to talk about
```

```bash
uvicorn app.main:app --host 0.0.0.0 --port 8000
```

Check `http://localhost:8000/api/health`: `"llm_reachable": true` means Ollama is up **and** the model is pulled.
The server loads the model into RAM at startup (`warmup`), so the first question isn't the slow one.

**Pull the model before the event.** Venue Wi-Fi won't handle a 3 GB download.

---

## 3. Test it

```bash
python -m pytest -q                   # guard + pipeline tests with a fake model (no Ollama needed)
```

```bash
python tools/eval_ai.py               # 15 real questions against Qwen 3.5, incl. trap questions
```

```bash
python tools/eval_ai.py --show-prompt -q "Bakit mataas ang bill ko?"
```

`eval_ai.py` prints PASS/FAIL, `llm`/`fallback`, latency and the cited facts for each question.
**Done when** every row is PASS and under ~10 s (plan: "Bakit mataas ang bill ko?" in under 10 s using live data).

Try it through the API, as the app does:

```bash
curl -s localhost:8000/api/chat -H 'content-type: application/json' -d '{"message":"Bakit mataas ang bill ko?"}'
```

A `"source": "fallback"` answer is still correct (it's built from facts) but means the model failed the
guard twice. Open `logs/ai.jsonl`, look at `attempts`, and fix the cause (see section 5).

---

## 4. How to add something Sinag can answer

Example: "Magkano ang pinakamataas na solar ko this week?"

1. **Compute it in the backend** (`app/energy.py` or directly in `facts.py`). Never ask the model to compute it.
2. **Add a Fact** in `facts.gather()`:
   ```python
   fs.add("week.peak_solar_kw", "usage",                       # id, topic
          f"Pinakamataas na solar ngayong linggo: {peak:.1f} kW", # sentence the model sees
          (peak,),                                              # numbers it may quote
          ("Peak solar", f"{peak:.1f} kW"))                     # optional chip for the app
   ```
3. **Route to it**: make sure the question's words map to the topic in `router.KEYWORDS`
   (add `"pinakamataas"` to `"usage"` if needed).
4. **Add a case** to `CASES` in `tools/eval_ai.py` and run it.

Rules for facts: one idea per fact, the number already formatted the way you want it said,
Taglish sentence, and put **every** number from the sentence in `values` (or the guard will reject the
model for quoting it).

---

## 5. Tuning when something's off

| Symptom (in `logs/ai.jsonl` or eval) | Fix |
|---|---|
| Guard: `numbers not in FACTS` | The model computed something (e.g. added two facts). Add that number as its own fact, or reword the fact so it doesn't invite math. |
| Guard: `cites no facts` | Make the rule in `prompts.SYSTEM` louder, or try `qwen3.5:9b`. |
| Correct fact exists but the model didn't get it | Router missed the topic: add the keyword in `router.KEYWORDS`. Check with `--show-prompt`. |
| Answers > 10 s | Smaller model; fewer facts per topic; lower `num_predict` in `llm.py`; check `LLM_KEEP_ALIVE` keeps it loaded. Make sure `think` is `false`. |
| Answers in pure English / pure Tagalog | Tweak the style lines in `prompts.SYSTEM` (keep the numbered rules). |
| Real question gets "hindi ko pa alam" | The fact isn't there. Add it (section 4). |
| Laptop just can't run it | Cloud fallback: in `.env` set `LLM_PROVIDER=openai`, `LLM_BASE_URL`, `LLM_MODEL`, `LLM_API_KEY` (any OpenAI-compatible API). Same prompts, schema and guard. Needs internet. |

Don't loosen `guard.py` to make a test pass. If the guard rejects a reply, the reply was wrong for the user too.

---

## 6. Files

| File | You'll edit it when ... |
|---|---|
| `facts.py` | adding or rewording what Sinag knows |
| `router.py` | a question isn't getting the right facts |
| `prompts.py` | changing tone, Taglish style, recap format |
| `guard.py` | rarely; e.g. allowing a new number format |
| `service.py` | changing the flow (retry count, fallback text, chips) |
| `llm.py` | switching provider or Ollama options |
| `faults.py` | a new inverter fault code (also update `docs/contracts/A-inverter-register-map.md`) |

Wired into the API in `app/main.py`: `POST /api/chat` → `service.chat()`, `GET /api/summary/daily` →
`service.daily_summary()` (pre-generated every 10 min in the background and cached per date;
`?refresh=true` regenerates it). Response shapes: `docs/contracts/C-api.md`.

## 7. Demo checklist

- [ ] `ollama pull` done on the server laptop, `/api/health` shows `llm_reachable: true`
- [ ] `python tools/eval_ai.py` all PASS, all under 10 s
- [ ] Turn the Sun knob, ask "Kumusta ang solar ko?": the answer uses the new live numbers
- [ ] Press Brownout on the simulator, ask anything: the answer mentions the brownout first
- [ ] Press Fault, ask "May problema ba?": it explains fault 21 in plain Taglish
- [ ] Ask an off-topic question: polite "hindi ko pa alam"
- [ ] Stop Ollama mid-demo: chat still answers (`fallback`), nothing crashes
