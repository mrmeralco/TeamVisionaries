# Solaris landing page

One static page (`index.html`) for Solaris, built with [taste-skill](https://github.com/leonxlnx/taste-skill) 2.5.1.
No build step: open it over http.

```bash
cd landing && python -m http.server 8080   # then http://localhost:8080
```

Serve it over http: the kit's scripts load modules and icons by URL, and its checks never test `file://`.

## What is on it

| Section | Shows |
|---|---|
| Hero | The app's Home screen as live HTML (solar, home, battery, grid) and the November bill forecast card |
| `#app` | The Alerts list beside Mira answering in Taglish |
| `#bill` | Statement: "Know the bill before it arrives" (ripples under the pointer) |
| `#forecast` | Bill forecast, 48-hour solar outlook, brownout battery time, alert settings |
| `#questions` | Inverters, offline use, Mira's numbers, availability |
| `#setup` | Inverter → Solaris device → app, alerts, Mira (diagram) |

Colours are the app's own (`app/lib/core/theme/app_theme.dart`): orange `#C2500A` buttons on cream, ink `#292929`.
Every number in the copy comes from the repo: readings every 5 s (`docs/contracts/B-mqtt.md`), the
₱15.06/kWh default rate (`server/app/config.py`), the 48-hour Open-Meteo outlook, the 7-day and 14-day fallbacks
(`SOLARIS_PRESENTATION.md`) and Qwen 3.5 on Ollama (`server/ai/README.md`). The figures inside the drawn
app screens (3.42 kW, ₱1,114 and so on) are sample readings.

## Still to supply

- **Demo address.** Every "Book a demo" and "Email the team" link is a `mailto:` on `hello@solaris.example`,
  a stand-in. Swap it for the team's real address (search `solaris.example`).
- **Domain.** The `<link rel="canonical">` in the head stays a comment until there is one.
- **Photographs.** None are used. A photo of the real device wired to the inverter would make a strong
  second section or close.

## Checks it passed

`gate.mjs` → `GATE: PASS` (copy-lint, consistency at 1440 and 390, a 320px walk), `check.mjs` at 1440, 1024,
820, 768 and 390 with no findings, `perf.mjs` 0 FAIL. Two kit-side findings are waived in
`.taste-skill/waivers.json`, each with its reason.

`assets/` is the part of the taste-skill kit this page loads (1.5 MB); the rest of the kit was left out.
