# Testing: what each of us builds until it's green

The tests are the to-do list. Each one is written from the plan and the contracts, so **a passing test
means that piece is done** and a failing test tells you exactly what's missing.

All tests share one machine-readable contract: [`docs/contracts/schema.json`](docs/contracts/schema.json)
(the `.md` contracts in code form). Change it only together with the `.md` files and the group chat.

## Who runs what

| Who | Tests | Where | When green |
|---|---|---|---|
| **Andy** (backend) | API contract, alert rules, energy/bill math, MQTT ingest: 82 tests | `server/tests/test_api_contract.py`, `test_alerts.py`, `test_energy.py`, `test_ingest.py` | Before every merge to `main` |
| **Andy** (AI) | Hallucination guard, AI pipeline, router: 31 tests, then the real-model eval (14/15 PASS on 2026-11-12, [next steps](server/ai/README.md#0-status-and-what-to-build-next-andy-start-here)) | `server/tests/test_guard.py`, `test_ai_pipeline.py`, `test_router.py`, `server/tools/eval_ai.py` | Guard always; eval before h14 |
| **Aldrin + Shane** (app) | ApiService / MockApiService spec: 30 tests | [`app/test_spec/`](app/test_spec/) | Before h10 (against mocks) |
| **Adrian + Stephen** (hardware) | Simulator over Modbus: register map, knob, brownout, fault | `tests/acceptance/test_hw_simulator_modbus.py` | Before h8 |
| **Adrian + Andy** | **Checkpoint h10**: device → MQTT → backend → DB | `tests/acceptance/test_h10_device_to_db.py` | Hour 10 |
| **Andy + Aldrin** | **Checkpoint h14**: backend → app, REST + WebSocket | `tests/acceptance/test_h14_backend_to_app.py` | Hour 14 |
| **Stephen** | **Demo flows**: brownout, fault, low battery, chat < 10 s, offline | `tests/acceptance/test_demo_flows.py` | 5 runs in a row after the h18 freeze |

## Setup (once)

```bash
cd server && python3 -m venv .venv && source .venv/bin/activate
```

```bash
pip install -r requirements.txt -r requirements-dev.txt
```

## 1. Unit / spec tests (no hardware, no broker, no LLM)

```bash
cd server && python -m pytest -q
```

Runs against a throwaway DB with seeded history. Takes ~1 s. Never touches the real server's data.
These must stay green whenever anyone changes `server/`.

## 2. Flutter spec tests

See [app/test_spec/README.md](app/test_spec/README.md). Short version, from `app/`:

```bash
flutter test test/spec
```

## 3. Acceptance tests (against the running system)

They hit the real server over HTTP/WebSocket and the real MQTT broker. Two modes:

| `SOLARIS_SOURCE` | Who makes things happen |
|---|---|
| `fake` (default) | The test plays the Solaris device: it publishes readings, brownouts and faults on MQTT itself. Use it before the hardware is ready. **It writes test readings into the server's DB**, so don't run it on the demo DB; reseed after. |
| `real` | The real device and simulator are running. The test prints `>>> OPERATOR: Hold the button 1-3 s ...` and waits up to `SOLARIS_WAIT_S` (60 s) for it to happen. |

Start the system (server laptop): broker, server, then (fake mode) nothing else, (real mode) the boards.

```bash
mosquitto -c server/mosquitto.conf
```

```bash
cd server && python tools/seed_history.py && uvicorn app.main:app --host 0.0.0.0 --port 8000
```

Then, from the repo root:

```bash
python -m pytest tests/acceptance -m h10 -v
```

```bash
python -m pytest tests/acceptance -m h14 -v
```

```bash
SOLARIS_SOURCE=real python -m pytest tests/acceptance -m demo -v
```

```bash
SOLARIS_SERIAL=/dev/cu.usbserial-XXXX python -m pytest tests/acceptance -m hardware -v
```

Pointing at another laptop: `SOLARIS_API=http://192.168.43.100:8000 MQTT_HOST=192.168.43.100`.
Hardware tests also need `pip install pymodbus pyserial`.

Tests marked **real_only** (device publish interval, NTP time, retained status, energy balance)
skip in fake mode: they check Adrian's firmware, which a fake can't.

## Checkpoints (from the plan's timeline)

| Hour | Checkpoint | Green means |
|---|---|---|
| 0–2 | Contracts written | `server/tests/test_api_contract.py::test_example_files_match_contract` passes; app team has `docs/contracts/examples/` |
| 2–8 | Each piece works alone | `server/tests` all green · `flutter test test/spec` green · hardware tests green |
| 8–10 | **Integration 1** | `-m h10` green with `SOLARIS_SOURCE=real` (knob turn appears in DB) |
| 10–14 | **Integration 2** | `-m h14` green with `SOLARIS_SOURCE=real` **and** the phone updates when the knob turns |
| 14–18 | MVP features | `-m demo` green in fake mode · `tools/eval_ai.py` all PASS |
| 18 | **Feature freeze** | No new features. Only make failing tests pass |
| 18–22 | Demo runs end-to-end | `SOLARIS_SOURCE=real -m demo` green **5 times in a row**, plus the by-eye checklist below |

## Flutter screens by eye

Tests can't see the screen. Shane + Stephen, tick these on the demo phone. Trigger states with
`python server/tools/fake_device.py` (type `b` + Enter for brownout, `f` for fault, `s`/`S` sun) or the
simulator box.

- [ ] **Home** shows the status line, solar/home/grid/battery, saved today; updates within 5 s of a knob turn
- [ ] **Home, offline**: stop the device or fake_device → within ~30 s the app shows offline (`state: "offline"`), no crash
- [ ] **Home, empty**: brand-new DB (`telemetry: null`) → friendly empty state, not a red error
- [ ] **Brownout**: alert pops/badge increments; Home turns brownout; Brownout Advisor shows runtime hours + advice
- [ ] **Fault**: critical alert with the Taglish explanation; Home shows the fault
- [ ] **Energy**: day / week / month charts switch, labels readable, no overflow
- [ ] **Bill**: month-to-date, forecast with range, vs last month, weekly bars
- [ ] **Ask Mira**: answer + chips appear; spinner while waiting (up to ~10 s); off-topic question gets the polite refusal
- [ ] **Alerts**: list, tap marks read, badge count goes down; "mark all read"
- [ ] **Settings**: change server IP → reconnects; "Test connection" uses `/api/health`; rate change updates the Bill tab
- [ ] **Server restarts** mid-demo → app reconnects the WebSocket on its own
- [ ] ₱ sign and Taglish text render correctly everywhere
