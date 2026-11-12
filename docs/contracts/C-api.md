# Contract C: REST + WebSocket API (backend → Flutter app)

Base URL: `http://<server-laptop-ip>:8000` (the IP is entered in the app's Settings).
Interactive docs: `http://<ip>:8000/docs` (FastAPI).
In code: [`server/app/schemas.py`](../../server/app/schemas.py) has one Pydantic model per shape below, and
`server/tests/test_contract.py` checks these docs' examples and the real backend against it.

Conventions:
- JSON everywhere. Field names are `snake_case`.
- **All timestamps are Unix seconds (UTC)** in a field named `ts` or ending in `_ts`. Day/week/month
  boundaries are computed in **Asia/Manila**.
- Money is pesos as a number (`_php`), energy is kWh (`_kwh`), power is W (`_w`).
- Every sample response below is a real file in [`examples/`](examples/). The backend's mock mode
  (`SOLARIS_MOCK=1`) serves exactly those files, so the app can be built against them first.

| Endpoint | Returns / does | Tab | Example |
|---|---|---|---|
| `GET /api/live` | Device status, latest telemetry, status line, saved today | Home | [live.json](examples/live.json) |
| `WS /ws/live` | Pushes each telemetry reading, new alerts, device status | Home, Alerts | [ws_messages.json](examples/ws_messages.json) |
| `GET /api/energy?period=day\|week\|month` | Time series + totals + self-sufficiency % | Energy | [energy_day.json](examples/energy_day.json) |
| `GET /api/bill` | Month-to-date ₱, forecast ₱ + range, vs last month, savings, weekly costs | Bill, Home | [bill.json](examples/bill.json) |
| `GET /api/brownout` | Status, start time, battery runtime estimate, advice | Brownout Advisor | [brownout.json](examples/brownout.json) |
| `GET /api/outlook` | Solar forecast (weather), battery projection 48 h, brownout runtime with sun, advice | Brownout Advisor, Home | [outlook.json](examples/outlook.json) |
| `GET /api/bill/projection` | This month's bill forecast + up to 3 projected months (rougher, widening range) | Bill & Savings, Ask Mira | [bill_projection.json](examples/bill_projection.json) |
| `GET /api/upgrade` | System check: does the solar/battery/inverter still fit the household's use? Recommendations + rough payback | Bill & Savings | [upgrade.json](examples/upgrade.json) |
| `GET /api/tips` | Solar tips: when and how to run the house on the sun (live, forecast, last 30 days) + this month's CO₂ avoided | Home | [tips.json](examples/tips.json) |
| `GET /api/solar-plan` | No solar yet: suggested solar size (grid-tie / hybrid) from the home's use, savings, payback; sponsored slots | Home (meter_only) | [solar_plan_meter_only.json](examples/solar_plan_meter_only.json) |
| `GET /api/household` | Household profile from home use alone: routine, is anyone likely home now, always-on load, new appliance-sized loads | Home, Ask Mira | [household.json](examples/household.json) |
| `GET /api/meter` | Smart meter mode: latest meter reading, voltage + power factor check, usage pattern, Meralco level this month, insights | Home, Energy, Bill | [meter.json](examples/meter.json) |
| `GET /api/alerts` | Alert list, unread count | Alerts | [alerts.json](examples/alerts.json) |
| `POST /api/alerts/{id}/read` | Marks one alert read, returns it | Alerts | — |
| `POST /api/alerts/read-all` | Marks all read, returns `{ "unread": 0 }` | Alerts | — |
| `POST /api/chat` | `{message}` → `{reply, chips[], source, sources[]}` Taglish answer + the data behind it | Ask Mira | [chat.json](examples/chat.json) |
| `GET /api/summary/daily` | AI-written recap of yesterday | Home | [summary_daily.json](examples/summary_daily.json) |
| `GET /api/settings` / `PUT /api/settings` | Rate ₱/kWh, battery kWh, user name, device id, household setup | Settings | [settings.json](examples/settings.json) |
| `GET /api/health` | `{ "ok": true, "mock": false, "llm": "qwen3.5:4b", "llm_provider": "ollama", "llm_reachable": true }` | Settings (connection test) | — |

`POST /api/alerts/{id}/read`, `POST /api/alerts/read-all` and `GET /api/health` are additions to the
plan's table, proposed for Aldrin's approval. `GET /api/outlook`, `GET /api/tips`, `GET /api/household`, `GET /api/meter` and `GET /api/solar-plan` are additions too.

## Household setup (smart meter mode)

`setup` in `/api/settings` says what the home has. It changes where the numbers come from, not the shapes:

| `setup` | Solar, battery, home use | Grid kWh for the bill | App shows |
|---|---|---|---|
| `solar` (default) | inverter telemetry | inverter | everything as before; `/api/meter` not used |
| `meter_only` | meter: pv = battery = 0, home use = grid import | meter | meter readings and insights; no solar, battery, brownout runtime, solar tips, outlook or system check |
| `solar_and_meter` | inverter telemetry | meter (the utility-side truth; inverter until the meter has reported) | both |

Meter readings are Contract B `solaris/{device_id}/meter` payloads (`sdm120` smart meter or `ansi-c12` Meralco
meter), stored by the backend. In `meter_only`: `/api/live` has `telemetry: null` and the `meter` reading,
`state` is `grid` | `brownout` | `offline`, savings are 0, `/api/brownout` has no battery fields, the bill
forecast follows the air-con season (no solar simulation), and Mira's facts never include solar or battery.
`/api/outlook`, `/api/tips` and `/api/upgrade` still answer, but are about solar and the app hides them.
Mock mode: `PUT /api/settings {"setup": "meter_only"}` switches the demo to `examples/<name>_meter_only.json`
(or `_solar_and_meter`) wherever such a file exists.

## Shapes

### `GET /api/live`

```jsonc
{
  "device": { "id": "solaris-001", "online": true, "rssi": -55, "fw": "0.3.0", "last_seen_ts": 1762912800 },
  "telemetry": {                    // Contract B fields; null if nothing received yet
    "ts": 1762912800, "pv_w": 3200, "load_w": 1800, "grid_w": 0, "batt_soc": 78,
    "batt_w": -1400, "grid_on": true, "inv_temp_c": 42, "fault_code": 0
  },
  "state": "solar",                 // solar | battery | grid | brownout | fault | offline
  "status_line": "Araw ang nagpapagana sa bahay mo ngayon, at nagcha-charge pa ang battery.",
  "saved_today_php": 84.2,
  "rate_php_per_kwh": 13.0,
  "setup": "solar",                 // solar | meter_only | solar_and_meter (settings)
  "meter": null                     // latest Contract B meter reading; null for setup solar (see live_meter_only.json)
}
```

`device.online` is false when the last will fired **or** no telemetry arrived for 30 s (in `meter_only`: no
meter reading for 30 s).

### `GET /api/energy?period=day|week|month`

`day` = today by hour (24 points), `week` = last 7 days by day, `month` = this month by day.

Optional `back=N` (default 0, max 366): the same period N steps earlier. `day&back=1` = yesterday,
`week&back=1` = the 7 days before the last 7, `month&back=1` = last calendar month. Mock mode ignores it.

```jsonc
{
  "period": "day", "bucket": "hour", "start_ts": 1762876800, "end_ts": 1762963200,
  "points": [
    { "ts": 1762876800, "label": "00:00", "pv_kwh": 0.0, "load_kwh": 0.42,
      "grid_import_kwh": 0.0, "grid_export_kwh": 0.0, "batt_charge_kwh": 0.0, "batt_discharge_kwh": 0.42 }
  ],
  "totals": { "pv_kwh": 18.4, "load_kwh": 14.1, "grid_import_kwh": 2.3, "grid_export_kwh": 1.1,
              "batt_charge_kwh": 5.2, "batt_discharge_kwh": 4.6 },
  "self_sufficiency_pct": 83.7      // (1 - grid_import / load) * 100
}
```

### `GET /api/bill`

```jsonc
{
  "month": "2026-11", "days_elapsed": 12, "days_in_month": 30, "rate_php_per_kwh": 13.0,
  "month_to_date_kwh": 41.2, "month_to_date_php": 535.6,
  "forecast_php": 1290.0, "forecast_low_php": 1150.0, "forecast_high_php": 1430.0,
  "last_month_php": 1510.0, "vs_last_month_pct": -14.6,     // forecast vs last month
  "savings_today_php": 84.2, "savings_month_php": 1180.5,   // solar + battery energy used at home x rate
  "weekly_costs": [ { "week_start_ts": 1761494400, "label": "Oct 27", "php": 310.4 } ],
  "grid_source": "inverter"         // inverter | meter: where the grid kWh come from (the meter whenever there is one)
}
```

Bill = grid import kWh priced with Meralco's residential schedule (pure solar household, no net-metering
credit; `server/app/tariff.py`). `rate_php_per_kwh` is the user's setting: Meralco's monthly overall rate
for a 200 kWh household. The whole month pays the distribution charge of its consumption level (up to 200,
201-300, 301-400, over 400 kWh), plus fixed supply and metering charges. Forecast = month-to-date kWh + expected kWh for each
day left, then priced. The days come from a weekly SARIMA model (last 8 weeks, adjusted by a monthly
season index), with the range taken from simulated months (≈ ± one std dev). With under 4 weeks of
history it uses weekday/weekend averages instead. `month_to_date_php` and `weekly_costs` use the ₱/kWh of the level the
forecast lands in. Savings stay at `rate_php_per_kwh`, matching `saved_today_php` in `/api/live`.
With a meter (`grid_source: "meter"`) the kWh are the meter's, which is what Meralco bills. A home without solar
has no savings (0) and its forecast level follows the air-con season directly.

### `GET /api/brownout`

```jsonc
{
  "active": true, "start_ts": 1762911000, "duration_min": 30,
  "batt_soc": 64, "load_w": 900, "runtime_h": 7.1,   // (soc% x battery_kwh) / load; null if load is 0
  "advice": "May brownout. Sa 900 W, aabot pa ng mga 7 oras ang battery mo. ...",
  "outages_this_month": 3
}
```

When `active` is false, `start_ts`/`duration_min` describe the **last** outage (or are null). During a brownout, `advice`
also says how long the battery lasts once the forecast sun is counted (from `/api/outlook`).

### `GET /api/outlook`

Next 48 hours, hour by hour: forecast solar, typical home use and projected battery %.

```jsonc
{
  "generated_ts": 1794456190, "source": "weather",       // "history" = no weather forecast, last 14 days used
  "solar_today_kwh": 10.7, "solar_tomorrow_kwh": 5.2, "solar_typical_kwh": 17.0,   // typical: null without 14 days
  "battery": {
    "soc_pct": 37, "reserve_pct": 20,
    "reserve_ts": 1794491696,          // battery reaches reserve_pct, grid takes over; null if not within 48 h
    "full_ts": null,                   // sun fills it to 100 %; null if not within 48 h
    "tomorrow_max_soc_pct": 38.5, "grid_kwh_24h": 5.22
  },
  "brownout": {                        // if the grid were out from now on; null if no telemetry yet
    "active": false, "cutoff_pct": 5,
    "lasts_until_ts": 1794494807, "hours": 10.7   // null = lasts past 48 h
  },
  "advice": "Maulap ang forecast bukas: mga 5 kWh lang ang solar, kumpara sa karaniwang 17 kWh. ...",
  "hours": [ { "ts": 1794456000, "pv_kwh": 1.89, "load_kwh": 0.3, "soc_pct": 51.3, "cloud_pct": 30 } ]  // 48 items
}
```

Solar = forecast radiation (Open-Meteo) × this house's kWh per kWh/m², fitted on the last 7 days. Load =
average for that hour of the day (weekday/weekend, last 28 days). The battery is simulated hour by hour:
with the grid on it drains to `reserve_pct`, in a brownout to `cutoff_pct`. `hours[0]` is the current hour.


### `GET /api/bill/projection`

This month's forecast (same numbers as `/api/bill`) plus up to **3** calendar months after it. Only this
month is a forecast; later months are **projections** ("if use stays like the last few weeks", adjusted for
the season) and their range widens each month. Nothing is projected beyond 3 months: the range would be
too wide to use. Cached per day.

```jsonc
{
  "generated_ts": 1762912800, "enough_data": true,   // false until 14 days of history: months = [this month]
  "basis_days": 28, "rate_php_per_kwh": 15.06,       // today's rate, assumed for every month
  "max_months": 3,
  "months": [
    { "month": "2026-11", "label": "Nobyembre 2026", "months_ahead": 0, "kind": "forecast",
      "grid_kwh": 157.9, "low_kwh": null, "high_kwh": null,
      "bill_php": 2382.52, "low_php": 2106.9, "high_php": 2657.1,
      "load_kwh": null, "solar_kwh": null, "range_pct": null },
    { "month": "2026-12", "label": "Disyembre 2026", "months_ahead": 1, "kind": "projection",
      "grid_kwh": 181.4, "low_kwh": 120.3, "high_kwh": 242.5,      // +-range_pct
      "bill_php": 2733.58, "low_php": 1821.4, "high_php": 3730.9,  // Meralco tiers at today's rate
      "load_kwh": 509.5, "solar_kwh": 450.9, "range_pct": 34 }
  ]
}
```

Projection: this home's typical hourly day, load scaled by an air-con season index and solar by Manila's
monthly sunshine (dry season sunny, rainy season and December less), simulated with the battery, then
corrected by the ratio of simulated to metered grid use over the last 14 days. Range (about +-1 std dev) =
1.5 x this home's weekly variation + 30 % per month ahead (max 120 %), and at least +-12 % of the month's home
use in kWh; low_kwh never goes below 0 and range_pct is capped at 100. This month's peso range also allows for
the household's level shifting, not only day-to-day noise. Both calibrated with server/tools/backtest_ranges.py.

### `GET /api/upgrade`

System check from the home's own last 30 days (`UPGRADE_DAYS`). Cached 10 min.

```jsonc
{
  "generated_ts": 1762912800,
  "enough_data": true,                 // false until 7 days of readings (then verdict "unknown", usage null)
  "verdict": "consider",               // ok = fits | consider = at least one hardware upgrade | unknown
  "headline": "Pwedeng i-upgrade: dagdag na battery (+5 kWh), mga ₱1,581 na tipid kada buwan.",
  "system": { "pv_kwp": 5.0, "battery_kwh": 10.0, "inverter_kw": 5.0 },
  "usage": {                           // daily averages
    "days": 30, "load_kwh_day": 16.7, "pv_kwh_day": 17.8, "grid_import_kwh_day": 3.9,
    "day_import_kwh_day": 0.4,         // grid 6 AM-6 PM
    "night_import_kwh_day": 3.5,       // grid 6 PM-6 AM
    "export_kwh_day": 4.9,             // solar sent to the grid unused
    "self_sufficiency_pct": 77, "battery_empty_days_pct": 100,   // days the battery hit its reserve
    "peak_load_w": 1944, "p95_load_w": 1780, "load_trend_pct": 1  // last 7 days vs before; null < 2 weeks
  },
  "recommendations": [                 // best payback first; "usage" notes last
    {
      "id": "battery",                 // battery | solar | inverter | usage
      "priority": 1, "title": "Dagdag na battery", "add": "+5 kWh",
      "reason": "Halos 4.9 kWh na solar kada araw ang napupunta lang sa grid, pero 3.5 kWh ...",
      "evidence": [ { "label": "Solar sent to grid", "value": "4.9 kWh/day" } ],
      "savings_php_month": 1581,       // rough; null if it doesn't save money directly
      "cost_php": 100000,              // rough installed price (UPGRADE_* in .env); null for usage notes
      "payback_years": 5.3
    }
  ]
}
```

Rules: **battery** when surplus solar is exported while the nights run on the grid and the battery runs out on
30 %+ of days (size = energy it could shift, in 2.5 kWh modules). **solar** when the home still buys 1.5+ kWh a
day while the sun is up, or the sun can't fill the battery (size from this roof's kWh per kWp). **inverter** when
the 95th-percentile load reaches 85 % of `INVERTER_KW` or the peak exceeds it. **usage** when use rose 15 %+ in
the last 7 days. Prices are rough PH figures from `.env`; the app labels them as estimates.

### `GET /api/tips`

Tips that get the household to use more of its own solar and less grid, each built from this home's numbers.
Not cached: the `now` tips follow the live reading, so the app refetches when the live `state` changes.

```jsonc
{
  "generated_ts": 1762912800,
  "best_window": {                     // the 3 hours with the most solar left after typical use; null if none
    "start_ts": 1762912800, "end_ts": 1762923600, "surplus_kwh": 5.9,
    "day": "today"                     // today | tomorrow (tomorrow once today has no window worth using)
  },
  "impact": {                          // this month so far; null before any solar this month
    "month": "2025-11", "solar_kwh": 212.7, "clean_share_pct": 76.5,   // = self-sufficiency
    "co2_avoided_kg": 151.0,           // solar_kwh x GRID_CO2_KG_PER_KWH (0.71, PH grid)
    "trees": 7                         // grown trees that take up that much CO₂ in a year (22 kg each)
  },
  "tips": [                            // most urgent first, at most 6, always ends with one "general" tip
    {
      "id": "best_window", "kind": "today",   // kind: now | today | habit | general
      "priority": 1, "title": "Pinakamaaraw ngayon: 10AM–1PM",
      "body": "Mga 5.9 kWh na sobrang solar ang inaasahan ngayon, 10AM hanggang 1PM. ...",
      "evidence": [ { "label": "Extra solar", "value": "5.9 kWh" } ],
      "savings_php_month": null        // rough upper bound; null when the tip isn't directly about money
    }
  ]
}
```

Rules (`server/app/tips.py`):

| `id` | `kind` | When |
|---|---|---|
| `surplus_now` | now | Grid on, solar exceeds home use by 800 W+, and the battery is 90 %+ or power is going to the grid |
| `grid_now` | now | The house draws 300 W+ from the grid and a `best_window` is still ahead |
| `best_window` | today | A 3-hour window with 1 kWh+ of surplus solar (outlook forecast minus typical use) |
| `cloudy_tomorrow` | today | Tomorrow's solar < 60 % of typical, asked between 6 AM and 3 PM |
| `shift_to_day` | habit | Last 30 days: 1 kWh+ a day both exported and bought at night; savings = the smaller × rate × 30 |
| `spread_loads` | habit | Last 30 days: 1 kWh+ a day bought from the grid 6 AM-6 PM |
| `precool` | habit | Weekday 6-10 PM use 1.5× midday and 0.8 kWh/h+, with surplus solar exported |
| `general` | general | One of six evergreen tips (clean panels, timers, inverter appliances, …), changes daily |

Habit tips are ordered by savings. Every number in `body` and `evidence` comes from the backend.

### `GET /api/solar-plan`

For a home **without solar** (`setup` meter_only): how big a solar setup its own use needs. Homes that have
solar get `has_solar: true`, no options and a pointer to `/api/upgrade` ([solar_plan.json](examples/solar_plan.json)).

```jsonc
{
  "generated_ts": 1762912800, "setup": "meter_only", "has_solar": false,
  "days": 30,                                   // days with data, last 30; options need 7+
  "headline": "Para sa 17.8 kWh kada araw mo, 4.64 kWp na solar (8 panels + 15 kWh na battery): ...",
  "usage": { "kwh_day": 17.8, "day_kwh_day": 6.2, "night_kwh_day": 11.6, "night_share_pct": 65,
             "peak_w": 2166, "bill_php_month": 8670 },               // null without enough data
  "options": [                                  // recommended first; [] when usage is null
    {
      "id": "hybrid", "recommended": true,      // grid_tie | hybrid
      "title": "Hybrid na may battery",
      "pv_kwp": 4.64, "panels": 8, "panel_w": 580, "roof_m2": 21, "inverter_kw": 5.0,
      "battery_kwh": 15.0,                      // null for grid_tie
      "solar_kwh_day": 16.7, "covers_pct": 88, "export_kwh_day": 0.0,
      "bill_before_php_month": 8670, "bill_after_php_month": 977, "savings_php_month": 7693,
      "cost_php": 532000, "payback_years": 5.8,
      "backup_hours": 14.0,                     // battery at the usual night load, in a brownout
      "co2_kg_year": 4063, "why": "65% ng gamit mo ay sa gabi, kaya may silbi ang battery: ..."
    }
  ],
  "yield_kwh_per_kwp_day": 3.6,
  "sponsors": [                                 // ad slots, shown apart from the plan and labelled "Sponsored"
    { "id": "slot_installer", "kind": "installer", "name": "Solar installer",
      "tagline": "Ad space for an accredited solar installer near you.", "url": null, "placeholder": true }
  ],
  "disclaimer": "Tantiya lang ito ... Ang mga ad ay hiwalay sa rekomendasyon."
}
```

How it's sized (`server/app/solar_plan.py`):

| Step | How |
|---|---|
| typical day | average kWh for each hour over the last 30 days (`flow_source`: the meter in a meter_only home) |
| sun | `SOLAR_YIELD_KWH_PER_KWP_DAY` (3.6, PH average) spread as a bell from 6 AM to 6 PM |
| `grid_tie` | panels for the 6 AM-6 PM use; inverter = panels ÷ 1.25, rounded up to a standard size; no battery |
| `hybrid` | panels for 90 % of the day's use; battery for the night's use ÷ 90 % usable, in 2.5 kWh modules (5-20 kWh); inverter also carries the 99th-percentile peak × 1.1 |
| recommended | `hybrid` when 40 %+ of use is at night, else `grid_tie` |
| savings | hour-by-hour simulation (95 % battery efficiency each way); bill before/after with Meralco tiers (`tariff.cost`), exports credited at `SOLAR_EXPORT_PHP_PER_KWH` (net metering) |
| cost | panels `UPGRADE_PV_PHP_PER_KWP` + inverter `SOLAR_*_INVERTER_PHP_PER_KW` + battery `UPGRADE_BATTERY_PHP_PER_KWH`, rounded to ₱1,000 |

Sponsors come from `SPONSORS_FILE` (default `server/sponsors.json`, a JSON list of `{id, kind, name, tagline,
url}`; `kind` installer | panel_brand | inverter_brand | battery_brand | financing). Without it the response has
three placeholder slots. The sizing never reads them, and Mira never mentions them.

### `GET /api/household`

What the home's own electricity use says about the people in it, and what changed lately. Only `load_w` is
used, averaged into 15-minute slots. Not cached past the day: `now` follows the last 30 minutes. Occupancy is
personal: it is computed on the laptop and never leaves it.

```jsonc
{
  "generated_ts": 1762912800,
  "now": {                              // the last 30 min against the routine
    "state": "away",                    // active | asleep | away | quiet | unknown (offline / no data)
    "likely_home": false,               // null = can't tell
    "load_w": 290, "usual_home_pct": 0, // how often this hour is active, on this kind of day
    "unusual": false,                   // active at an hour that is active < 20 % of the time
    "next_active_ts": 1762941600,       // when not active: next usually-busy hour
    "text": "Laging-nakabukas na gamit lang (290 W): mukhang walang tao sa bahay ngayon. ..."
  },
  "days_used": 28, "confidence": "high",            // none < 3 days, low < 7, medium < 21, high
  "baseload": { "watts": 280, "kwh_month": 201.1, "php_month": 3029, "share_pct": 37.8 },  // null until confident
  "daylight_use_pct": 36.6,                          // share of home use 6 AM-6 PM
  "routine": {
    "weekday": {                                     // null without 3 weekdays (weekend: 2 days) of data
      "wake_hour": 7, "sleep_hour": 23,              // ends/starts of the quiet stretch around 3 AM; null if none
      "away": { "start_hour": 9, "end_hour": 18 },   // longest daytime quiet stretch, 3 h+; null if none
      "peak_hour": 21,
      "home_pct": [ /* 24 ints, % of time active per hour */ ], "avg_w": [ /* 24 ints */ ]
    },
    "weekend": { ... }
  },
  "archetype": { "id": "away_daytime", "label": "Wala sa bahay tuwing weekday", "description": "..." },
  "traits": [ { "id": "evening_peak", "label": "Pinakamalakas ang gamit mga 9PM" } ],
  "new_loads": [                                     // at most 2, biggest first; [] = nothing new
    {
      "id": "block_21_02", "kind": "scheduled",      // scheduled | always_on
      "start_hour": 21, "end_hour": 2,               // null for always_on
      "added_w": 1100, "kwh_day": 5.5,
      "php_month": 2485,                             // upper bound: kwh_day x 30 x rate
      "since_ts": 1762444800, "days_seen": 5,        // local midnight of the first day it showed
      "guess": "aircon",
      "text": "Mula noong Nov 7, mga 1.1 kW ang dagdag na gamit tuwing 9PM–2AM (...). Baka may bagong aircon?"
    }
  ]
}
```

Rules (`server/app/household.py`):

| What | How |
|---|---|
| baseload | 10th percentile of the last 28 days' 15-minute averages |
| active slot | average > baseload + max(150 W, ½ baseload), or the power swung 400 W+ inside the slot |
| `home_pct` | share of active slots at that hour, weekdays and weekends apart |
| sleep / wake | the stretch around 3 AM where `home_pct` < 50 % |
| away | longest stretch between wake and sleep where `home_pct` < 25 %, at least 3 h |
| archetype | `away_daytime`: weekday away 6 h+ · `home_daytime`: weekday 9 AM-5 PM active 50 %+ · else `mixed` |
| `now.state` | active → home; quiet in the sleep window → `asleep`; quiet at a usually-quiet hour → `away`; quiet at a usually-busy hour → `quiet` |
| new `always_on` | median daily baseload of the last 3-7 days rose 60 W+ and 20 %+ over the 28 days before |
| new `scheduled` | consecutive hours whose median excess over the same hour on the same kind of day is 300 W+ (and above its usual spread) on 60 %+ of the last 3-7 days; 0.5 kWh/day+ |

`guess` is from watts and hours only (night 500 W-2.5 kW → aircon, 2.5 kW+ → water heater / induction /
EV charger, always-on < 250 W → ref / freezer). Demo: `python tools/seed_history.py --reset --new-load-days 5`.

### `GET /api/meter`

What the home's meter reads and what it means for the bill (`server/app/meter.py`). Not cached.

```jsonc
{
  "generated_ts": 1794489390, "setup": "meter_only", "online": true,
  "reading": {                         // Contract B meter payload; null until the first reading
    "ts": 1794489390, "meter_type": "sdm120", "voltage_v": 228.4, "current_a": 7.22, "power_w": 1452.0,
    "apparent_va": 1649.0, "reactive_var": 783.0, "pf": 0.88, "freq_hz": 60.01,
    "import_kwh": 2414.17, "export_kwh": 12.0, "grid_on": true
  },
  "quality": {                         // null without a reading
    "nominal_v": 230.0, "low_limit_v": 207.0, "high_limit_v": 253.0,   // GRID_NOMINAL_V ± GRID_V_TOLERANCE (10 %)
    "voltage_status": "normal",        // normal | low | high | off (brownout), now
    "min_v_24h": 212.4, "avg_v_24h": 228.7, "max_v_24h": 232.0, "out_of_range_pct_24h": 0.0,
    "pf_status": "fair"                // good >= 0.90 | fair >= 0.80 | poor | null
  },
  "usage": {                           // last 7 finished days; null until a full day of readings
    "days": 7, "import_kwh_day": 17.93, // grid import a day (= home use without solar)
    "base_w": 259,                     // always on: 10th percentile of the power drawn
    "peak_w": 2222, "peak_hours": [20, 21, 22], "night_share_pct": 64,   // 6 PM-6 AM
    "weekday_kwh_day": 16.33, "weekend_kwh_day": 21.92,
    "by_hour_kwh": [0.31, 0.29, ...]   // 24 values: the typical day, kWh per hour
  },
  "tier": {                            // Meralco level this month lands in; null when the bill isn't from the meter
    "month": "2026-11", "days_left": 19, "month_to_date_kwh": 208.37, "forecast_kwh": 532.2,
    "level_min_kwh": 400.0, "level_max_kwh": null,          // "over 400 kWh"
    "rate_php_per_kwh": 14.13,                              // that level's ₱/kWh (fixed charges not included)
    "kwh_above_lower_level": 132.2, "save_php_at_lower_level": 2096,   // null in the lowest level
    "kwh_to_next_level": null, "next_level_rate_php_per_kwh": null      // null in the top level
  },
  "insights": [                        // warnings first, then money, habits, the reading
    { "id": "tier_drop", "tone": "info", "title": "Kaya pang bumaba sa mas murang antas",
      "body": "Mga 532 kWh ang inaasahang gamit mo ngayong buwan, 132 kWh lampas sa 400 kWh. ...",
      "evidence": [ { "label": "Forecast use", "value": "532 kWh" } ] }
  ]
}
```

| `id` | `tone` | When |
|---|---|---|
| `voltage` | warning / good | Low or high now, or 5 %+ of the last 24 h out of range (warning); otherwise "normal" (good) |
| `power_factor` | warning | PF below 0.80 now (residential bills don't charge for it; a sign of a tired motor) |
| `tier_drop` | info | The forecast is within 25 % above a cheaper level and 3+ days are left: kWh a day to cut and ₱ saved |
| `tier_near` | warning | The forecast is within 10 % below a dearer level |
| `tier` | info | Otherwise: the level and its ₱/kWh |
| `peak_hours` | info | The 3 hours with the most use and the night share |
| `base_load` | info | Always-on use of 50 W+, as kWh and ₱ a month |
| `reading` | info | The meter's import register (for `ansi-c12`: the number Meralco reads) |

Every number in `body` and `evidence` comes from this response.

### `GET /api/alerts`

`?unread_only=true` is optional.

```jsonc
{
  "unread": 2,
  "alerts": [
    { "id": 12, "ts": 1762911000, "type": "brownout", "severity": "critical",
      "title": "Brownout", "message": "Nawalan ng kuryente mula sa grid. Battery na ang gamit mo.", "read": false }
  ]
}
```

`type`: `fault` · `brownout` · `grid_restored` · `low_battery` · `high_temp` · `device_offline` · `device_online`
`severity`: `info` · `warning` · `critical`. Newest first, max 100.

### `POST /api/chat`

Request `{ "message": "Bakit mataas ang bill ko?" }`

```jsonc
{
  "reply": "Mas mataas ang gamit mo mula 6 hanggang 10 PM ...",
  "chips": [ { "label": "Bill this month", "value": "₱536" } ],   // from the facts the AI cited
  "source": "llm",                  // llm | fallback (LLM down, too slow, or failed the fact check: rule-based answer)
  "facts_used": ["bill.month_to_date_php", "usage.peak_hours"],    // optional: ids of the facts behind the answer
  "sources": [                      // optional: the user's data behind the answer, one per fact
    {
      "id": "bill.month_to_date_php",
      "label": "Bill so far",       // short English name
      "value": "₱536",              // headline value, or null (e.g. peak hours)
      "detail": "Sa ngayon, ₱536 na ang nagastos mo sa kuryente ngayong buwan (35.6 kWh mula sa grid).",
      "kind": "history",            // live | history | forecast | settings | advice
      "period": "This month",
      "screen": "bill",             // home | energy | bill | brownout | alerts | settings | null: where the app shows it
      "as_of_ts": 1762912800        // measured (live) or computed (others); null for settings
    }
  ]
}
```

Every number in `reply` comes from the backend's data, never from the model (see `server/ai/README.md`).
`facts_used` and `sources` are additions. `sources` lists exactly the facts the answer used (rule-based
answers too), built by the backend from the same data, so the app can show where the answer came from
and link to the screen with that data. An out-of-scope refusal has no sources.

### `GET /api/summary/daily`

```jsonc
{
  "date": "2026-11-11", "summary": "Kahapon, 82% ng kuryente mo ay galing sa araw ...",
  "totals": { "pv_kwh": 19.2, "load_kwh": 15.0, "grid_import_kwh": 2.7, "cost_php": 35.1, "savings_php": 160.0 },
  "source": "llm"
}
```

Pre-generated by the backend (not on demand).

### `GET|PUT /api/settings`

```json
{ "rate_php_per_kwh": 13.0, "battery_kwh": 10.0, "user_name": "Juan", "device_id": "solaris-001", "setup": "solar" }
```

`PUT` takes any subset of these fields and returns the full object. `setup`: `solar` | `meter_only` |
`solar_and_meter` (see "Household setup" above).

### `WS /ws/live`

Each message is `{ "type": ..., "data": ... }`:

| `type` | `data` |
|---|---|
| `telemetry` | Same object as `GET /api/live` |
| `alert` | One alert object (same as in `/api/alerts`) |
| `status` | The `device` object from `/api/live` |
| `meter` | Contract B meter payload + `device_id` (only when a smart/utility meter is on the bus; the app may ignore it: in `meter_only` each reading also comes as a `telemetry` message) |

The server sends one `telemetry` message right after the socket connects. Reconnect with backoff if it drops.
