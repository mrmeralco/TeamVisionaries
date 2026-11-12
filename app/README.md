# Solaris Flutter app

Owners: **Aldrin** (dev) + **Shane** (UI/UX). Flutter 3.44, targets **web + Android**
(`ph.solaris.solaris`). Screens follow the Figma "MOBILE" frames (HTML export with colours, spacing, DM Sans
and the images/icons in `assets/images/`), on top of the server connection below.

## Run

```bash
flutter pub get
```

```bash
flutter run -d chrome
```

```bash
flutter run -d <android-device> --dart-define=SOLARIS_SERVER=http://192.168.43.100:8000
```

```bash
flutter run -d chrome --dart-define=SOLARIS_MOCK=true
```

Default server: `SOLARIS_SERVER` if given, else on web the page's host on port 8000, else on Android
`http://10.0.2.2:8000` (emulator → your machine). On a real phone, type the laptop IP in
Settings (gear icon); it's saved on the device. Settings also has **Test connection** (`/api/health`)
and a **mock data** toggle (no server needed). Android allows plain `http://` (hotspot LAN).

## Layout

```
lib/
  main.dart                       ProviderScope + MaterialApp.router
  core/config/server_config.dart  default URL, URL normalising ("192.168.43.100" → http://…:8000)
  core/router.dart                go_router: 5-tab shell + /settings, /brownout
  core/theme/app_theme.dart       Figma tokens (C.*), ts() text styles, DM Sans
  core/utils/format.dart          ₱, W/kW, kWh, Manila time from Unix seconds
  services/api_service.dart       every Contract C call (spec-tested)
  services/mock_api_service.dart  same API from assets/mock/*.json
  services/live_connection.dart   /ws/live with reconnect + backoff
  providers/                      Riverpod: server config, live state, per-tab data, alerts, chat
  features/<tab>/                 one folder per screen (Home, Energy, Bill, Ask, Alerts, Brownout, Settings)
  features/common/ui.dart         header (link dot + gear), cards, two-column grid, AsyncBody, bottom nav
  features/common/charts.dart     hand-drawn line chart (Energy) and bar chart (Bill)
```

Libraries: `http`, `web_socket_channel`, `flutter_riverpod` (state), `go_router` (navigation),
`fl_chart` (Energy/Bill charts), `shared_preferences` (saved server URL), `intl` (₱, dates),
`flutter_svg` (Figma icon exports). DM Sans is bundled in `assets/fonts/` (SIL OFL; the demo is offline,
so no runtime font downloads).

What the screens read: Home → `liveProvider` (updates on every `/ws/live` message, `link` says
connected / reconnecting); Energy → `energyProvider((period, back))` (`back` 1 = yesterday / last
week / last month); Bill → `billProvider` (+ `outlookProvider` for the tip); Brownout → `brownoutProvider`;
Alerts → `alertsProvider` (+ `unreadAlertsProvider` for the badge, live alerts merged in); Ask →
`chatProvider`; Settings → `serverConfigProvider`, `serverSettingsProvider`.

## Readability rules

From the Nov 2026 UI review; `flutter test` checks the layout parts at 320 px and at 2× system text.

- **Text size:** body text ≥ 11, labels ≥ 10. Nothing smaller.
- **Contrast:** text ≥ 4.5:1 on its background, big bold numbers ≥ 3:1. Use the tokens in
  `core/theme/app_theme.dart` (each notes its ratio): `C.label` / `C.muted` for grey text, `C.orangeText`
  for small orange text and links, `C.orangeDeep` for big orange numbers, `gradientDeep` behind white
  text. `C.orange` is for fills, lines and icons, not small text. No `Color(0x…)` in screens.
- **Tap targets:** ≥ 44 × 44 (`kMinTap`). Use `LinkButton` for "Do this →" links.
- **No fixed heights around text:** use `minHeight` constraints, `Wrap`, `Flexible`, so large system
  fonts grow the layout instead of clipping it. The app is centred at `kMaxAppWidth` (480) on wide screens.
- **Screen readers:** wrap label + value tiles in `Readout` so they read as one phrase; charts get a
  `Semantics` summary.
- **Server data:** read fields with `str` / `numOr` / `intOrNull` / `mapOf` / `listOfMaps`
  (`core/utils/format.dart`), not `as String`, so a missing field shows a fallback instead of an error
  screen. `ErrorBox` / `friendlyError` say whether the server is unreachable, failing, or sent bad data.

## Copy style (English and Taglish)

One rule, so screens don't mix languages at random:

- **English** for the interface itself: navigation, titles and headings, labels, units, buttons and chips
  ("Mark all read", "Try again", "Next 48 hours", "Duration"). These match the Figma.
- **Taglish** for sentences that explain or advise: Mira's answers, status lines, alert messages and
  their explanations, empty and error states ("Hindi maabot ang Solaris server.", "Walang alerts.").
- Suggested questions to Mira are in Taglish because they're what the user would say to her.

Strings live in the widgets for now; moving them to ARB files (and an English / Taglish toggle) is the
next step if the app needs full translations.

## Tests

```bash
flutter test
```

`test/spec/` is a copy of `test_spec/` (the contract spec, 30 tests); `test/connection_test.dart`
covers URL parsing and WebSocket reconnect; `test/widget_test.dart` drives every designed screen with the
contract examples: brownout / fault / offline / empty states, alerts read flow, chat, settings, and a
320 × 640 no-overflow check.

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
   SOLARIS_MOCK=1 uvicorn app.main:app --host 0.0.0.0 --port 8000
   ```
   Then point the app at `http://<that-laptop-ip>:8000`. Every endpoint, including `/ws/live`
   (pushes a reading every 5 s), returns the example JSON.
2. **In-app `MockApiService`**: copy `docs/contracts/examples/*.json` into `assets/mock/` and load them.

## Plan notes (from the architecture doc)

- Bottom nav: Home, Energy, Bill, Ask Mira, Alerts + Settings. Brownout Advisor screen from Home/Alerts.
- One `ApiService` wraps every Contract C call; `MockApiService` behind one flag.
- Packages: `http`, `web_socket_channel`, `provider` or `riverpod`, `fl_chart`.
- Home listens to `/ws/live`; Alerts badge updates on `{"type": "alert"}` messages.
- Server IP is entered in Settings (the laptop's IP on the hotspot). `GET /api/health` is a good "Test connection" button.
- Key states to design: offline (`state: "offline"`), brownout, fault, empty (`telemetry: null`).
