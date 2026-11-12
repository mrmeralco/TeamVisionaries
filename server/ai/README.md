# Sinag AI: implementation guide

**Owner: Andy.** This folder is the "Ask Sinag" chat (`POST /api/chat`) and the daily recap
(`GET /api/summary/daily`). It runs **Qwen 3.5 locally on Ollama**, so it works with no internet.

The hybrid pipeline already works end to end. Your job is to get Qwen 3.5 running on the server laptop, tune it,
and add facts for the questions the demo needs.

---

## 0. Status and what to build next (Andy, start here)

**Implementation update (2026-11-12):** bill questions select facts for spending so far,
forecast, previous month, or comparison. Explicit current/forecast answers must cite and state the
requested peso amount; otherwise the existing retry/fallback path applies. Brownout/fault must be
mentioned first, and current readings must disclose offline data. These checks reduce specific
mix-ups; they do not prove every qualitative statement or multi-number comparison is correct.

Power facts display W below 1,000 W and one-decimal kW above it. Displayed numbers are grounded in
facts. API response shapes and fact identifiers are unchanged.

### Validate on Andy's laptop (PowerShell, from `server`)

```powershell
.\.venv\Scripts\python.exe -m pytest -q
.\.venv\Scripts\python.exe tools/eval_ai.py --show-prompt
.\.venv\Scripts\python.exe tools/eval_live_ai.py --broker "C:/Program Files/mosquitto/mosquitto.exe"
```

The live check starts a temporary loopback broker and backend with an isolated seeded database.
It tests changing solar, brownout, fault 21, stale readings, unavailable-model fallback, and cached
recaps, then stops only its own processes. Add `--model qwen3.5:4b` to use real Ollama instead.
It does not operate a phone; run the section 7 checklist through the app before the demo.

### Compare 4B and 9B

Pull both models first, then run without other Ollama requests:

```powershell
ollama pull qwen3.5:9b
.\.venv\Scripts\python.exe tools/benchmark_ai.py --repeat 3
```

This uses one temporary seeded database for both models and writes reports to
`server/logs/benchmark/` (ignored by Git). It unloads benchmark models between runs without stopping
Ollama. `.env` and the demo database are unchanged. Reports include each reply, failure categories,
latency, warmup time, and Ollama's `size_vram`/`size` offloading information.

Normal cases require either a recognized direct answer or a validated model answer, expected
citations and values, and **under 10 seconds**. Unavailable history/appliance data must be refused;
injected amounts must not be repeated. An unexpected model fallback still fails evaluation.

### Direct readings and meaning checks

`answers.py` matches complete, simple lookup questions for forecast, spending so far, battery percent,
solar power, battery/grid direction, and savings. It returns backend fact sentences with citations and
chips. Broad savings questions show both today and month-to-date with explicit labels. Explanations,
compound requests, historical questions, and extra instructions do not match the direct rules.
Missing telemetry returns a no-data sentence, never an invented reading. Active alerts come before
the requested reading; offline live measurements carry a stale-data notice.

The existing API format is preserved: rule-based replies use `source: "fallback"`, including deliberate
direct answers. Logs additionally record `strategy: "direct"`; evaluator reports distinguish these from
unexpected fallbacks by checking the exact backend-built response and citations. No new source enum
or app change is required. Qwen remains responsible for explanations and recaps.

The guard now checks known money-role and flow reversals: spending versus savings, spending so far
versus forecast, battery charging/discharging, and grid import/export. These are conservative pattern
checks with regression tests, not a general semantic proof. Unrecognized wording and unsupported
causal explanations still need manual review. Simultaneous fault/brownout may occupy separate opening
sentences, but both must precede other information and neither can be denied while active.

### Latest 4B results (RTX 4050 Laptop GPU, 6 GB VRAM; 2026-11-12)

After adding direct answers and meaning checks: **45/45 PASS**, 15 questions repeated three times,
with **12 direct answers, 33 LLM answers, and zero unexpected fallbacks**. Median response 1.61 s,
slowest 3.09 s, including backend fact gathering and excluding warmup. Direct forecast questions no
longer depend on Qwen citations. These measurements are for the hybrid service, not 45 model calls.

Keep **qwen3.5:4b**, 4,096-token context, 220 output tokens, thinking off. The earlier all-model
comparison scored 4B at 43/45 (two forecast fallbacks) and 9B at 42/45 (three slow answers; median
5.19 s, maximum 12.53 s). Those historical scores predate direct lookups and are not a current
same-version comparison. 9B has not been re-benchmarked for this update.

Validation: **202 server tests pass**. The real-4B isolated MQTT/API smoke check passes with changing
solar, direct bill answers during brownout, simultaneous fault 21/brownout, stale readings, and cached
recaps. Reports are local ignored files under `logs/benchmark/`, `logs/direct-benchmark.txt`, and
`logs/direct-live-check.txt`. To reproduce only the selected model:

```powershell
.\.venv\Scripts\python.exe tools/benchmark_ai.py --models qwen3.5:4b --repeat 3
```

**Remaining release validation:** complete the phone/app checklist and manually review explanations.
This update does not change the demo database or switch models.

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

A `"source": "fallback"` answer uses backend facts. It can be an intentional direct answer or a model
failure; check the logged `strategy` and `attempts` to distinguish them. Open `logs/ai.jsonl`, look at `attempts`, and fix the cause (see section 5).

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

Rules for facts: one idea per fact, the number already formatted the way you want it said, Taglish
sentence. Numbers written in the sentence are allowed automatically (`FactSet.add` parses them); put the
**unrounded** value in `values` too (e.g. `1994.6` for "₱1,995") so the guard accepts "mga ₱2,000".

Routing rules (`router.py`): topics come from `KEYWORDS`. `"now"` facts are always included. Cost words in
`WEAK_BILL` ("magkano", "mahal", "mataas", ...) only mean the bill when no other topic matched, so
"Magkano kinuha ko sa grid kahapon?" goes to `yesterday`, not the bill. A bill question also gets `usage`
(peak hours). A question that matches nothing gets the overview (`today`, `bill`, `savings`). Every new
routing rule gets a row in `tests/test_router.py`.

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
