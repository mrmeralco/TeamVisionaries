# Contract C: REST + WebSocket API (backend → Flutter app)

Base URL: `http://<server-laptop-ip>:8000` (the IP is entered in the app's Settings).
Interactive docs: `http://<ip>:8000/docs` (FastAPI).

Conventions:
- JSON everywhere. Field names are `snake_case`.
- **All timestamps are Unix seconds (UTC)** in a field named `ts` or ending in `_ts`. Day/week/month
  boundaries are computed in **Asia/Manila**.
- Money is pesos as a number (`_php`), energy is kWh (`_kwh`), power is W (`_w`).
- Every sample response below is a real file in [`examples/`](examples/). The backend's mock mode
  (`SINAG_MOCK=1`) serves exactly those files, so the app can be built against them first.

| Endpoint | Returns / does | Tab | Example |
|---|---|---|---|
| `GET /api/live` | Device status, latest telemetry, status line, saved today | Home | [live.json](examples/live.json) |
| `WS /ws/live` | Pushes each telemetry reading, new alerts, device status | Home, Alerts | [ws_messages.json](examples/ws_messages.json) |
| `GET /api/energy?period=day\|week\|month` | Time series + totals + self-sufficiency % | Energy | [energy_day.json](examples/energy_day.json) |
| `GET /api/bill` | Month-to-date ₱, forecast ₱ + range, vs last month, savings, weekly costs | Bill, Home | [bill.json](examples/bill.json) |
| `GET /api/brownout` | Status, start time, battery runtime estimate, advice | Brownout Advisor | [brownout.json](examples/brownout.json) |
| `GET /api/alerts` | Alert list, unread count | Alerts | [alerts.json](examples/alerts.json) |
| `POST /api/alerts/{id}/read` | Marks one alert read, returns it | Alerts | — |
| `POST /api/alerts/read-all` | Marks all read, returns `{ "unread": 0 }` | Alerts | — |
| `POST /api/chat` | `{message}` → `{reply, chips[], source}` Taglish answer | Ask Sinag | [chat.json](examples/chat.json) |
| `GET /api/summary/daily` | AI-written recap of yesterday | Home | [summary_daily.json](examples/summary_daily.json) |
| `GET /api/settings` / `PUT /api/settings` | Rate ₱/kWh, battery kWh, user name, device id | Settings | [settings.json](examples/settings.json) |
| `GET /api/health` | `{ "ok": true, "mock": false, "llm": "qwen2.5:3b" }` | Settings (connection test) | — |

`POST /api/alerts/{id}/read`, `POST /api/alerts/read-all` and `GET /api/health` are additions to the
plan's table, proposed for Aldrin's approval.

## Shapes

### `GET /api/live`

```jsonc
{
  "device": { "id": "sinag-001", "online": true, "rssi": -55, "fw": "0.3.0", "last_seen_ts": 1762912800 },
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

Bill = grid import kWh × rate (pure solar household, no net-metering credit). Forecast = month-to-date +
weekday/weekend daily averages × days left, ± one standard deviation.

### `GET /api/brownout`

```jsonc
{
  "active": true, "start_ts": 1762911000, "duration_min": 30,
  "batt_soc": 64, "load_w": 900, "runtime_h": 7.1,   // (soc% x battery_kwh) / load; null if load is 0
  "advice": "May brownout. Sa 900 W, aabot pa ng mga 7 oras ang battery mo. ...",
  "outages_this_month": 3
}
```

When `active` is false, `start_ts`/`duration_min` describe the **last** outage (or are null).

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
  "chips": [ { "label": "Bill this month", "value": "₱536" } ],
  "source": "llm"                   // llm | fallback (LLM down or too slow: rule-based answer)
}
```

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
{ "rate_php_per_kwh": 13.0, "battery_kwh": 10.0, "user_name": "Juan", "device_id": "sinag-001" }
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
