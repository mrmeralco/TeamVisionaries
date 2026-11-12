# Sinag Flutter app

Owners: **Aldrin** (dev) + **Shane** (UI/UX). This folder is reserved for the Flutter project.
Run `flutter create --org ph.sinag --project-name sinag .` here (or move your existing project in).

## What the app talks to

Everything is in [docs/contracts/C-api.md](../docs/contracts/C-api.md). Sample responses for every
endpoint are in [docs/contracts/examples/](../docs/contracts/examples/).

Two ways to develop before the real backend is ready:

1. **Backend mock mode** (recommended): on any laptop with Python,
   ```bash
   cd server && pip install -r requirements.txt
   ```
   ```bash
   SINAG_MOCK=1 uvicorn app.main:app --host 0.0.0.0 --port 8000
   ```
   Then point the app at `http://<that-laptop-ip>:8000`. Every endpoint, including `/ws/live`
   (pushes a reading every 5 s), returns the example JSON.
2. **In-app `MockApiService`**: copy `docs/contracts/examples/*.json` into `assets/mock/` and load them.

## Plan notes (from the architecture doc)

- Bottom nav: Home, Energy, Bill, Ask Sinag, Alerts + Settings. Brownout Advisor screen from Home/Alerts.
- One `ApiService` wraps every Contract C call; `MockApiService` behind one flag.
- Packages: `http`, `web_socket_channel`, `provider` or `riverpod`, `fl_chart`.
- Home listens to `/ws/live`; Alerts badge updates on `{"type": "alert"}` messages.
- Server IP is entered in Settings (the laptop's IP on the hotspot). `GET /api/health` is a good "Test connection" button.
- Key states to design: offline (`state: "offline"`), brownout, fault, empty (`telemetry: null`).
