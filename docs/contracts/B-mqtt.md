# Contract B: MQTT topics and payloads (Sinag device → backend)

Broker: Mosquitto on the server laptop, port **1883**, no auth on the hotspot.
`device_id` defaults to `sinag-001` (set in `firmware/sinag-device/config.h`).

## `sinag/{device_id}/telemetry`: every 5 s, QoS 0, not retained

From the inverter (Contract A).

```json
{
  "ts": 1731300000, "pv_w": 3200, "load_w": 1800, "grid_w": 0,
  "batt_soc": 78, "batt_w": -1400, "grid_on": true,
  "inv_temp_c": 42, "fault_code": 0
}
```

| Field | Type | Notes |
|---|---|---|
| `ts` | int | Unix seconds (UTC). **`0` = device has no NTP time yet: the backend uses receive time.** |
| `pv_w`, `load_w` | int | W, ≥ 0 |
| `grid_w` | int | W, + import, − export |
| `batt_soc` | int | % |
| `batt_w` | int | W, + discharging, − charging |
| `grid_on` | bool | false = brownout |
| `inv_temp_c` | int | °C |
| `fault_code` | int | 0 = OK |

## `sinag/{device_id}/meter`: every 5 s, QoS 0, not retained

From a smart meter (Contract A2) or a utility meter (Contract A3), when one answers.

```json
{
  "ts": 1731300000, "meter_type": "sdm120",
  "voltage_v": 230.1, "current_a": 6.52, "power_w": 497, "apparent_va": 1500,
  "reactive_var": 470, "pf": 0.95, "freq_hz": 60.01,
  "import_kwh": 1520.35, "export_kwh": 12.40, "grid_on": true
}
```

`meter_type` is `"sdm120"` or `"ansi-c12"`. `power_w`: + import, − export. `grid_on` = voltage > 100 V.

## `sinag/{device_id}/status`: retained, also the MQTT last will

```json
{ "online": true, "rssi": -55, "fw": "0.3.0" }
```

Published on connect and every 30 s. The last will (retained, QoS 1) is `{"online": false}`,
so the broker flips it when the device drops off.

## Debug

```bash
mosquitto_sub -h localhost -t "sinag/#" -v
```
