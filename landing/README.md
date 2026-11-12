# Solaris landing page

One static page (`index.html`) for Solaris, started with [taste-skill](https://github.com/leonxlnx/taste-skill) 2.5.1
and then redesigned to the team's brief: fluted glass, the app's orange, a business look, little empty space, light
and dark themes. No build step: serve it over http.

```bash
cd landing && python -m http.server 8080   # then http://localhost:8080
```

`?theme=light` or `?theme=dark` on the URL forces a theme (handy for sharing a screenshot). Without it the page
follows the visitor's choice (the sun/moon button, remembered) or else opens in light mode.

## What is on it

| Section | Shows |
|---|---|
| Hero | Fluted glass over a blurred sunset behind a house; glass cards with the app's live and bill figures, the headline, Book a demo, a five-item feature strip |
| `#features` | Eight feature cards, one per feature slide of the presentation (`SOLARIS_PRESENTATION.md`, slides 5 to 12) |
| `#app` | Ask Mira: the real conversation ("Bakit mataas ang bill ko?") and its sources, in front of the real Home screen |
| `#bill` | The bill forecast in the app's deep orange, beside the real Bill & Savings screen |
| `#forecast` | The app screen by screen: real Energy, Solar tips, Your household, System check, Brownout Advisor and Alerts screens |
| `#meter` | Smart meter mode and the three setups, with the real meter-only Home and its rate-level warning |
| `#meralco` | How Solaris helps Meralco serve its customers (slide 13): what works today, what needs a partnership, privacy |
| `#questions` | Eight questions in two columns |
| `#setup` | Inverter or meter, Solaris device, app, alerts, Mira (diagram) |
| Footer | Book a demo; Team Visionaries, who built what, GitHub and email |

**The phone screens are real.** `assets/app/*-day.jpg` and `*-night.jpg` are screenshots of the Flutter app
(`app/`) built for the web and run against the server in mock mode (`SOLARIS_MOCK=1`), so every number on them
is the server's example data (`docs/contracts/examples/`). The day set shows in the light theme, the night set in
the dark one. To capture them again after the app changes: `flutter build web`, serve `app/build/web`, run the
server with `SOLARIS_MOCK=1`, open each route at 393x852 with `flutter.onboarded` and `flutter.appearance` set in
localStorage, and save each screen as a 590x1278 JPEG under the same names. `tips` and `household` are Home
scrolled to those cards, `check` is Bill scrolled to the system check, and `meter` / `metersave` are Home with the
mock server switched to the meter-only setup (`PUT /api/settings {"setup": "meter_only"}`, then back to `solar`).

- **Colours and type** are the app's own (`app/lib/core/theme/app_theme.dart`): cream and orange by day, its navy at
  night, DM Sans.
- **The glass** is `assets/solaris-glass.js`: a small WebGL shader that renders once into each `[data-glass]`
  section's background (scenes `sunset` and `band`), redrawn on resize. Without WebGL the CSS background stays.
- **Every number in the copy** comes from the repo: readings every 5 s (`docs/contracts/B-mqtt.md`), Meralco's published
  ₱15.0615/kWh rate (October 2026 billing, fetched by `server/app/meralco.py`; ₱15.06 default in `server/app/config.py`), the 48-hour Open-Meteo outlook and its 7- and 14-day fallbacks, Qwen 3.5 on
  Ollama (`server/ai/README.md`). The bill and live figures in the copy and the hero cards (₱857, ₱2,310, ₱2,123–₱2,497,
  3.1 kW, 78%) match the app screens, so the page never shows two different numbers for one thing.

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
