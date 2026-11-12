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
| `GET /api/alerts` | Alert list, unread count | Alerts | [alerts.json](examples/alerts.json) |
| `POST /api/alerts/{id}/read` | Marks one alert read, returns it | Alerts | — |
| `POST /api/alerts/read-all` | Marks all read, returns `{ "unread": 0 }` | Alerts | — |
| `POST /api/chat` | `{message}` → `{reply, chips[], source, sources[]}` Taglish answer + the data behind it | Ask Mira | [chat.json](examples/chat.json) |
| `GET /api/summary/daily` | AI-written recap of yesterday | Home | [summary_daily.json](examples/summary_daily.json) |
| `GET /api/settings` / `PUT /api/settings` | Rate ₱/kWh, battery kWh, user name, device id | Settings | [settings.json](examples/settings.json) |
| `GET /api/health` | `{ "ok": true, "mock": false, "llm": "qwen3.5:4b", "llm_provider": "ollama", "llm_reachable": true }` | Settings (connection test) | — |

`POST /api/alerts/{id}/read`, `POST /api/alerts/read-all` and `GET /api/health` are additions to the
plan's table, proposed for Aldrin's approval. `GET /api/outlook` is an addition too.

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
  "rate_php_per_kwh": 13.0
}
```

`device.online` is false when the last will fired **or** no telemetry arrived for 30 s.

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
  "weekly_costs": [ { "week_start_ts": 1761494400, "label": "Oct 27", "php": 310.4 } ]
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
corrected by the ratio of simulated to metered grid use over the last 14 days. Range = this home's weekly
variation + 10 % per month ahead (max 60 %).

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
{ "rate_php_per_kwh": 13.0, "battery_kwh": 10.0, "user_name": "Juan", "device_id": "solaris-001" }
```

`PUT` takes any subset of these fields and returns the full object.

### `WS /ws/live`

Each message is `{ "type": ..., "data": ... }`:

| `type` | `data` |
|---|---|
| `telemetry` | Same object as `GET /api/live` |
| `alert` | One alert object (same as in `/api/alerts`) |
| `status` | The `device` object from `/api/live` |
| `meter` | Raw Contract B meter payload + `device_id` (only when a smart/utility meter is on the bus; the app may ignore it) |

The server sends one `telemetry` message right after the socket connects. Reconnect with backoff if it drops.
