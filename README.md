# Solaris ☀️

**Team Visionaries · IDOL Hackathon 2026 · Pamantasan ng Lungsod ng Valenzuela**

Pure-solar home energy assistant. A small device reads the hybrid inverter over RS485/Modbus, a laptop
server stores the data and explains it in Taglish with a local LLM, and a Flutter app shows it live.
100 % local and offline, even the AI.

```
simulator / real inverter ─RS485 Modbus─▶ Solaris device (ESP32) ─MQTT─▶ backend (FastAPI) ─▶ SQLite
                                                                          │   └─▶ Ollama (local LLM)
                                                                          └─REST + WebSocket─▶ Flutter app
```

## Repo

| Folder | What | Owner |
|---|---|---|
| [`firmware/solaris-device/`](firmware/) | ESP32 #1: Modbus master, publishes MQTT | Adrian |
| [`firmware/inverter-sim/`](firmware/) | ESP32 #2: inverter / smart meter / Meralco meter simulator | Adrian + Stephen |
| [`server/app/`](server/) | FastAPI: ingest, alerts, bill, forecast, REST + WS | Andy |
| [`server/ai/`](server/ai/) | Grounded Taglish AI, Qwen 3.5 on Ollama ([guide](server/ai/README.md)) | Andy |
| [`server/tools/`](server/tools/) | `fake_device.py`, `seed_history.py` | Andy |
| [`app/`](app/) | Flutter app | Aldrin + Shane |
| [`docs/contracts/`](docs/contracts/) | **The 3 contracts**: Modbus map, MQTT schema, API spec | Aldrin approves changes |

## Working in parallel

- Build against [`docs/contracts/`](docs/contracts/) with fake data until the real piece is ready.
  **Changing a contract? Post in the group chat first.**
- One branch per workstream (`iot`, `backend`, `ai`, `app`); merge to `main` only at integration checkpoints.
- Checkpoints: **h2** contracts · **h8** each piece works alone · **h10** knob turn appears in DB ·
  **h14** knob turn updates the app · **h18 feature freeze** · h18–22 bug fixes + 5 demo runs · h22–24 pitch.

## Tests

[TESTING.md](TESTING.md) says which tests each member builds against and when they must be green
(checkpoints h10, h14, the hour-18 freeze).

```bash
cd server && python -m pytest -q
```

## Quick start

```bash
cd server && python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt
```

```bash
SOLARIS_MOCK=1 uvicorn app.main:app --host 0.0.0.0 --port 8000
```

API docs at `http://<laptop-ip>:8000/docs`. Real mode, firmware and app setup: see each folder's README.

Server laptop IP + hotspot password go on a sticky note.
