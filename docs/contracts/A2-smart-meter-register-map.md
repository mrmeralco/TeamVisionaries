# Contract A2: smart meter Modbus register map (SDM120-style)

Simulator in **meter mode** (or a real Eastron SDM120) ↔ Solaris device.

- Modbus RTU, **slave ID 2**, **9600 baud, 8N1**
- **Input registers** (function 0x04)
- Every value is an IEEE-754 **float32 across two registers, high word first** (Eastron convention)

| Start reg | Field (published as) | Unit | Decimals published |
|---|---|---|---|
| 0x0000 | `voltage_v` | V | 1 |
| 0x0006 | `current_a` | A | 2 |
| 0x000C | `power_w` | W (**+ import, − export**) | 0 |
| 0x0012 | `apparent_va` | VA | 0 |
| 0x0018 | `reactive_var` | VAr | 0 |
| 0x001E | `pf` | — | 2 |
| 0x0046 | `freq_hz` | Hz | 2 |
| 0x0048 | `import_kwh` | kWh | 2 |
| 0x004A | `export_kwh` | kWh | 2 |
| 0x0156 | total kWh (sim only, not published) | kWh | 2 |

The meter models a house with grid-tie solar and no battery: net power = load − solar.
In a brownout every value reads 0 (anti-islanding). "Low voltage" sags the grid to 195 V.

A real SDM120 ships at slave 1 / 2400 baud. Set it to slave 2 / 9600 on the meter's menu.
