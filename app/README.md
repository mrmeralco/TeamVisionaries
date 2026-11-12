# Sinag Flutter app

Owners: **Aldrin** (dev) + **Shane** (UI/UX). Flutter 3.44, targets **web + Android**
(`ph.sinag.sinag`). The server connection is done; screens are placeholders that show the raw
server data until Shane's Figma design is implemented.

## Run

```bash
flutter pub get
```

```bash
flutter run -d chrome
```

```bash
flutter run -d <android-device> --dart-define=SINAG_SERVER=http://192.168.43.100:8000
```

```bash
flutter run -d chrome --dart-define=SINAG_MOCK=true
```

Default server: `SINAG_SERVER` if given, else on web the page's host on port 8000, else on Android
`http://10.0.2.2:8000` (emulator → your machine). On a real phone, type the laptop IP in
Settings (gear icon); it's saved on the device. Settings also has **Test connection** (`/api/health`)
and a **mock data** toggle (no server needed). Android allows plain `http://` (hotspot LAN).

## Layout

```
lib/
  main.dart                       ProviderScope + MaterialApp.router
  core/config/server_config.dart  default URL, URL normalising ("192.168.43.100" → http://…:8000)
  core/router.dart                go_router: 5-tab shell + /settings, /brownout
  core/theme/app_theme.dart       placeholder tokens → replace with Figma styles
  core/utils/format.dart          ₱, W/kW, kWh, Manila time from Unix seconds
  services/api_service.dart       every Contract C call (spec-tested)
  services/mock_api_service.dart  same API from assets/mock/*.json
  services/live_connection.dart   /ws/live with reconnect + backoff
  providers/                      Riverpod: server config, live state, per-tab data, alerts, chat
  features/<tab>/                 one folder per screen (placeholders now)
  features/common/placeholder.dart  temporary raw-JSON widgets; delete as screens get designed
```

Libraries: `http`, `web_socket_channel`, `flutter_riverpod` (state), `go_router` (navigation),
`fl_chart` (Energy/Bill charts), `shared_preferences` (saved server URL), `intl` (₱, dates),
`flutter_svg` (Figma icon exports). Fonts from Figma go in `assets/fonts/` (the demo is offline,
so no runtime font downloads).

What the screens read: Home → `liveProvider` (updates on every `/ws/live` message, `link` says
connected / reconnecting); Energy → `energyProvider('day'|'week'|'month')`; Bill → `billProvider`;
Brownout → `brownoutProvider`; Alerts → `alertsProvider` (+ `unreadAlertsProvider` for the badge,
live alerts merged in); Ask → `chatProvider`; Settings → `serverConfigProvider`, `serverSettingsProvider`.

## Tests

```bash
flutter test
```

`test/spec/` is a copy of `test_spec/` (the contract spec, 30 tests); `test/connection_test.dart`
covers URL parsing and WebSocket reconnect; `test/widget_test.dart` boots the app in mock mode.

## Tests to build against

[test_spec/](test_spec/): 30 spec tests for `ApiService` / `MockApiService`, plus a reference implementation that
passes them. Screen checklist: [TESTING.md](../TESTING.md#flutter-screens-by-eye).

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
