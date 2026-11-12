# Hosting Solaris (server laptop)

One laptop runs everything the ESP32 and the app talk to:

| Service | Port | What it does |
|---|---|---|
| Mosquitto | 1883 | MQTT broker. The Solaris device publishes here |
| FastAPI | 8000 | Stores readings in SQLite, serves the REST/WebSocket API to the app |
| Ollama | 11434 (local only) | Taglish AI model (`qwen3.5:9b` on Andy's laptop) |

The FastAPI process on :8000 also serves the landing page (`landing/`) at `http://<ip>:8000/` and the Android app
at `http://<ip>:8000/apk`, so phones on the hotspot open one address for everything.

## Production (the demo): `start-production`

**Andy, this is the one to run.** Double-click **`start-production.bat`** (Windows) or
`bash server/host/start-production.sh` (macOS). Over the plain start script it:

- checks first: Python env, `.env` (warns if `SOLARIS_MOCK=1`), a database (seeds one if missing), the APK, port
  8000 free, Mosquitto installed, the Ollama model pulled;
- starts the broker and Ollama, then the server **without** `--reload`; if the server crashes it restarts in 3 s;
- serves the website + APK on :8000 and prints the addresses to give people:

```
  Website       http://192.168.43.100:8000/
  Android app   http://192.168.43.100:8000/apk
  In the app    Settings > server address:  192.168.43.100:8000
```

- logs to `server\logs\server.log` (and `mosquitto.log`), keeps the laptop awake while the window is open.

Options: `start-production.bat -Update` pulls the repo first (new APK, new code) and reinstalls Python packages;
`-NoAI` skips Ollama. macOS: `--update`, `--no-ai`. Ctrl+C or closing the window stops everything it started.

New APK: someone with Flutter runs `bash scripts/build-apk.sh` and pushes; Andy runs `start-production.bat -Update`.

## Windows (Andy's laptop, the demo host)

1. Install Git, clone the repo, open the `server\host` folder in File Explorer.
2. Double-click **`setup-windows.bat`** and accept the admin prompt. It installs Mosquitto, Python 3.12
   and Ollama with `winget`, creates `server\.venv`, copies `.env`, seeds 45 days of demo history,
   opens ports 1883 and 8000 in Windows Firewall, and downloads the AI model (3.3 GB).
   Run it **before the event**, on good internet. `setup-windows.bat -SkipAI` skips the model.
3. Double-click **`start-production.bat`** for the demo (above), or **`start-windows.bat`** for a plain start. It starts the broker and the API, and prints
   this laptop's IP. Close the window or press Ctrl+C to stop both.

Setup only needs to run once; running it again is safe.

## macOS

```bash
bash server/host/setup-mac.sh        # once (--skip-ai to skip the model)
```

```bash
bash server/host/start-mac.sh        # every time
```

## Pointing the Solaris device at the host

The start script prints this laptop's name and IP. Put them in
`firmware/solaris-device/config.h` together with the hotspot name and password, then reflash:

```c
#define WIFI_SSID       "team hotspot name"
#define WIFI_PASS       "hotspot password"
#define MQTT_MDNS_HOST  "ANDY-LAPTOP"       // found as ANDY-LAPTOP.local on any IP
#define MQTT_HOST       "192.168.43.100"    // used if the name doesn't answer
```

With the name set, a new IP from the hotspot needs no reflash. The serial log shows which one it
used: `[mqtt] connecting to ANDY-LAPTOP.local (192.168.43.100)` or `... did not answer, falling back`.
Check the name answers from another computer on the hotspot: `ping ANDY-LAPTOP.local`. If it
doesn't (some Windows firewall setups block mDNS, UDP 5353), the fixed IP still works.

The ESP32 only does 2.4 GHz Wi-Fi, so the hotspot must have 2.4 GHz on. The host laptop and the
ESP32 must be on the same hotspot. Tip: the hotspot usually gives the laptop the same IP every
time, so write it on the sticky note.

## Checking it works

- `http://<ip>:8000/api/health`: `"ok": true`, and `"llm_reachable": true` once Ollama has the model.
- `http://<ip>:8000/api/live`: latest reading from the device; `"state"` should not be `"offline"`.
- Watch raw MQTT traffic:
  - Windows: `"C:\Program Files\mosquitto\mosquitto_sub.exe" -t "solaris/#" -v`
  - macOS: `mosquitto_sub -t "solaris/#" -v`
- No hardware yet? `server\.venv\Scripts\python tools\fake_device.py` (Windows) or
  `server/.venv/bin/python tools/fake_device.py` (macOS) publishes fake readings.

## Troubleshooting

| Symptom | Fix |
|---|---|
| ESP32 LED slow blink (no broker) | Wrong `MQTT_HOST`, laptop not on the hotspot, or firewall. Re-run setup (it adds the firewall rules); check Windows set the hotspot network as *Private* or *Public*, both are allowed |
| ESP32 LED fast blink (no Wi-Fi) | Wrong SSID/password, or hotspot is 5 GHz only |
| `Port 1883 already in use` | Another Mosquitto is running. On Windows: `sc stop mosquitto` (admin) |
| `llm_reachable: false` | Start Ollama, or `ollama pull qwen3.5:4b`. The app still works with rule-based replies |
| Demo data looks wrong after testing | `python tools/seed_history.py --reset` |

Logs: `server/logs/mosquitto.log`; the API logs in the start window.
