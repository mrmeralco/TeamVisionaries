# Contract A: inverter Modbus register map

Simulator (ESP32 #2) ↔ Solaris device (ESP32 #1).

- Modbus RTU, **slave ID 1**, **9600 baud, 8N1**
- **Holding registers** (function 0x03). The simulator also answers 0x04 from the same map.
- One 16-bit register per field, scale 1. The device reads registers 0–7 in one block every 5 s.

| Reg | Field | Type | Unit / meaning |
|---|---|---|---|
| 0 | `pv_w` | uint16 | Solar power, W |
| 1 | `load_w` | uint16 | Home use, W |
| 2 | `grid_w` | int16 | Grid power, W (**+ import, − export**) |
| 3 | `batt_soc` | uint16 | Battery charge, % |
| 4 | `batt_w` | int16 | Battery power, W (**+ discharging, − charging**) |
| 5 | `grid_on` | uint16 | 1 = grid available, 0 = brownout |
| 6 | `inv_temp_c` | int16 | Inverter temperature, °C |
| 7 | `fault_code` | uint16 | 0 = OK, otherwise a fault code (see below) |

Energy balance the simulator keeps: `load_w = pv_w + grid_w + batt_w`.

## Fault codes

| Code | Meaning |
|---|---|
| 0 | OK |
| 21 | Overheating (simulator: hold the button 3–6 s; temperature climbs to ~78 °C) |

Add new codes here and in `server/ai/faults.py` together.

## Real inverters

A real hybrid inverter uses its own register numbers. A **brand profile** in
`firmware/solaris-device/profiles.h` maps its registers (address, scale, signed) onto these same
8 fields, so nothing past the device changes.
