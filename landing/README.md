# Solaris landing page

One static page (`index.html`) for Solaris, started with [taste-skill](https://github.com/leonxlnx/taste-skill) 2.5.1
and then redesigned to the team's brief: fluted glass, the app's orange, a business look, little empty space, light
and dark themes. No build step: serve it over http.

```bash
cd landing && python -m http.server 8080   # then http://localhost:8080
```

`?theme=light` or `?theme=dark` on the URL forces a theme (handy for sharing a screenshot). Without it the page
follows the visitor's choice (the sun/moon button, remembered) or else the system setting.

## What is on it

| Section | Shows |
|---|---|
| Hero | Fluted glass over a blurred sunset behind a house; glass cards (live readings, November bill), the headline, Book a demo, a five-item feature strip |
| `#app` | The Alerts list beside Mira answering in Taglish |
| `#bill` | "Know the bill before it arrives" on dark glass with a band of orange light |
| `#forecast` | Bill forecast, 48-hour solar outlook, the Brownout Advisor, the Alerts screen |
| `#questions` | Six questions in two columns |
| `#setup` | Inverter → Solaris device → app, alerts, Mira (diagram) |

- **Colours and type** are the app's own (`app/lib/core/theme/app_theme.dart`): cream and orange by day, its navy at
  night, DM Sans. The drawn app screens switch to the app's night colours in the dark theme.
- **The glass** is `assets/solaris-glass.js`: a small WebGL shader that renders once into each `[data-glass]`
  section's background (scenes `sunset` and `band`), redrawn on resize. Without WebGL the CSS background stays.
- **Every number in the copy** comes from the repo: readings every 5 s (`docs/contracts/B-mqtt.md`), the ₱15.06/kWh
  default rate (`server/app/config.py`), the 48-hour Open-Meteo outlook and its 7- and 14-day fallbacks, Qwen 3.5 on
  Ollama (`server/ai/README.md`). Alert titles are the server's own Taglish (`server/app/alerts.py`). The figures
  inside the drawn screens (3.42 kW, ₱1,114, 7.1 hours) are sample readings.

## Still to supply

- **Demo address.** Every "Book a demo" and "Email the team" link is a `mailto:` on `hello@solaris.example`, a
  stand-in. Search `solaris.example` and swap in the team's address.
- **Domain.** The `<link rel="canonical">` stays a comment until there is one.
- **A photograph of the real device** wired to the inverter would make a strong addition.

## Checks

copy-lint 0 FAIL / 0 WARN; perf 0 FAIL (300 KB, one font family); the kit's consistency checker at 1440, 820 and 390
in both themes shows no contrast, overlap or cut-text failures outside two known, accepted ones:

- the one-section-per-screen rule (`section-height`, `section-tile`, `one-section`): the brief asked for less empty
  space, so sections are as tall as their content;
- the last lines of Mira's chat at tablet width sit under the alerts window's bottom fade (the kit's app-frame recipe).

`assets/` holds only the kit files the page loads (MIT, `assets/LICENSE-taste-skill`), plus `solaris-glass.js`.
