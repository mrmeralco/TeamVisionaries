# Solaris server (FastAPI + MQTT ingest + local AI)

Owners: **Andy** (`app/` and `ai/`; AI guide: [ai/README.md](ai/README.md)). Implements Contract C
([docs/contracts/C-api.md](../docs/contracts/C-api.md)) on top of Contract B MQTT.

```
server/
├── app/            FastAPI app (Andy)
│   ├── main.py     routes: /api/* + /ws/live
│   ├── schemas.py  Contract C as Pydantic models (response_model on every route)
│   ├── ingest.py   MQTT subscriber -> validate -> SQLite -> alerts -> WebSocket
│   ├── alerts.py   fault, brownout (outage log), low battery, high temp, device offline
│   ├── energy.py   live status line, kWh series, bill + forecast, brownout runtime
│   ├── db.py       SQLite tables: telemetry, meter, device_status, alerts, outages, settings
│   ├── hub.py      WebSocket fan-out
│   ├── mock.py     SOLARIS_MOCK=1 serves docs/contracts/examples/*.json
│   └── config.py   env vars (see .env.example)
├── ai/             local AI, Qwen 3.5 on Ollama (Andy). Read ai/README.md
│   ├── facts.py    every number the AI may say, computed from SQLite
│   ├── router.py   question -> which facts go in the prompt
│   ├── prompts.py  Taglish system prompt + JSON reply format
│   ├── llm.py      Ollama client (thinking off, JSON schema, temp 0) + cloud fallback
│   ├── guard.py    hallucination guard: rejects numbers/ids not in the facts
│   ├── service.py  pipeline: facts -> LLM -> guard -> retry -> rule-based fallback
│   └── faults.py   fault-code table -> plain Taglish
├── tools/
│   ├── fake_device.py    publishes Contract B every 5 s (keys: b brownout, f fault, s/S sun, l/L load)
│   ├── seed_history.py   45 days of fake history so charts and forecast have data
│   └── eval_ai.py        runs 15 real questions (incl. traps) against the model
├── tests/          pytest: Contract C (test_contract.py), guard, AI pipeline with a fake model
└── mosquitto.conf
```

## Setup (server laptop)

**Easiest:** use the one-click scripts in [host/](host/README.md) (Windows `setup-windows.bat` / `start-windows.bat`, macOS `setup-mac.sh` / `start-mac.sh`). Manual steps below.

```bash
cd server
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
```

```bash
brew install mosquitto        # Windows: mosquitto.org/download
ollama pull qwen3.5:4b        # 3.3 GB, do it before the event
```

## Run

Fastest start for the app team (no broker, no DB, no LLM):

```bash
SOLARIS_MOCK=1 uvicorn app.main:app --host 0.0.0.0 --port 8000
```

Real mode, 3 terminals:

```bash
mosquitto -c mosquitto.conf -v
```

```bash
python tools/seed_history.py && uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
```

```bash
python tools/fake_device.py          # or the real Solaris device pointed at this laptop's IP
```

Open `http://localhost:8000/docs` to try every endpoint. `GET /api/health` shows whether the LLM is reachable
and the model is pulled.

## How the numbers work

- **kWh**: each 5 s power sample is counted until the next one (gaps over 15 min are not counted).
- **Bill** = grid import kWh priced with Meralco's residential schedule ([app/tariff.py](app/tariff.py),
  October 2026 billing): the rate setting is Meralco's monthly "overall rate" for a 200 kWh household
  (₱15.06 in Oct 2026; update it each month). The whole month pays the distribution charge of its
  consumption level (up to 200, 201-300, 301-400, over 400 kWh), plus ₱23.95 fixed charges and energy
  tax above 650 kWh. **Savings** = home use not taken from the grid × rate setting.
- **Forecast** = month-to-date kWh + expected kWh for each day left, priced with the tariff. Each day comes
  from a **SARIMA** model with a weekly cycle ([app/sarima.py](app/sarima.py)), fitted on log(1 + kWh) of
  the last 8 weeks after dividing out the annual season index. The range is the 16th-84th percentile of
  500 simulated months, using resampled model errors. Fewer than 4 weeks of history, no statsmodels, or
  `FORECAST_METHOD=average` → weekday/weekend averages of the last 28 days, ± daily std dev × √days left.
  Fitted once per day (≈1-2 s), then cached. Compare both on your own data:
  `python tools/backtest_forecast.py`. The season index and Meralco tables are in `tariff.py`.
- **Brownout runtime** = `batt_soc% × battery_kWh ÷ load_w` (no sun). During a brownout the advice also
  gives the time the battery runs out with the forecast sun counted.
- **Outlook** (`/api/outlook`, [app/outlook.py](app/outlook.py)): Open-Meteo radiation forecast × this
  house's kWh per kWh/m² (fitted on the last 7 days; `PV_KWP` × 0.8 until then) = solar per hour. Typical
  load per hour of day. The battery is simulated hour by hour for 48 h: when it hits `BATT_RESERVE_PCT`
  (grid on) or `BATT_CUTOFF_PCT` (brownout), whether tomorrow's sun refills it. Weather refreshes every
  30 min in the background; offline or `WEATHER_ENABLED=0` falls back to the last 14 days' solar.
  Only `SITE_LAT`/`SITE_LON` (default: Metro Manila) are sent to Open-Meteo.
- **AI**: the backend computes every number; the model only phrases cited facts in Taglish, and a guard
  rejects any reply with a number that isn't in the facts. If the LLM is off, slow or fails the guard twice,
  a rule-based answer is returned (`"source": "fallback"`). Full guide: [ai/README.md](ai/README.md).
