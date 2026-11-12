# Sinag contracts

Each workstream depends on the others **only** through these files. Build against them
with fake data until the real piece is ready.

> **Changing a contract?** Post it in the group chat first, get Aldrin's OK, then update the file here.

| File | Between | Owner |
|---|---|---|
| [A-inverter-register-map.md](A-inverter-register-map.md) | Inverter simulator ↔ Sinag device (Modbus RTU, slave 1) | Adrian |
| [A2-smart-meter-register-map.md](A2-smart-meter-register-map.md) | Simulator (meter mode) ↔ Sinag device (Modbus RTU, slave 2) | Adrian |
| [A3-meralco-meter-c12.md](A3-meralco-meter-c12.md) | Simulator (MERALCO mode) ↔ Sinag device (ANSI C12.18) | Adrian |
| [B-mqtt.md](B-mqtt.md) | Sinag device → backend (MQTT) | Adrian + Andy |
| [C-api.md](C-api.md) | Backend → Flutter app (REST + WebSocket) | Andy + Aldrin |
| [examples/](examples/) | Sample JSON for every Contract C response. The backend's mock mode serves these files, and the Flutter `MockApiService` can load the same ones. | Andy + Aldrin |

Data path: simulator (or real inverter) → RS485/Modbus → Sinag device → MQTT → backend → SQLite → REST/WebSocket → Flutter app.
