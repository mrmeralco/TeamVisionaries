#!/usr/bin/env bash
# Start the Sinag host on macOS: Mosquitto on :1883 + FastAPI on :8000. Ctrl+C stops both.
#   bash server/host/start-mac.sh
set -euo pipefail
cd "$(dirname "$0")/.."            # -> server/

MOSQ="$(brew --prefix)/sbin/mosquitto"
mkdir -p logs

if lsof -nP -iTCP:1883 -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Port 1883 already in use, assuming a broker is running."
  MOSQ_PID=""
else
  "$MOSQ" -c mosquitto.conf -v > logs/mosquitto.log 2>&1 &
  MOSQ_PID=$!
fi
trap '[[ -n "$MOSQ_PID" ]] && kill $MOSQ_PID 2>/dev/null; exit' INT TERM EXIT

command -v ollama >/dev/null && ! pgrep -x ollama >/dev/null && (ollama serve >/dev/null 2>&1 &)

IP=$(ipconfig getifaddr en0 || ipconfig getifaddr en1 || echo "<this-laptop-ip>")
cat <<EOF

  Sinag host is up
  -----------------------------------------------
  MQTT broker   ${IP}:1883     (log: server/logs/mosquitto.log)
  API + docs    http://${IP}:8000/docs
  Firmware      set MQTT_HOST "${IP}" in firmware/sinag-device/config.h
  Ctrl+C to stop
  -----------------------------------------------

EOF
.venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8000
