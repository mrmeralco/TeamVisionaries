#!/usr/bin/env bash
# Run Solaris for real on a macOS host: MQTT broker, Ollama, and the API + landing page + APK on :8000.
#   bash server/host/start-production.sh             normal start
#   bash server/host/start-production.sh --update    git pull first (new APK, new code), reinstall Python packages
#   bash server/host/start-production.sh --no-ai     don't start Ollama (Mira uses rule-based answers)
# Ctrl+C stops everything it started. The server restarts itself if it crashes; logs in server/logs/server.log.
set -uo pipefail
cd "$(dirname "$0")/.."            # -> server/
REPO="$(cd .. && pwd)"
PORT=${PORT:-8000}
UPDATE=0; NOAI=0
for a in "$@"; do case "$a" in --update) UPDATE=1;; --no-ai) NOAI=1;; *) echo "unknown option $a"; exit 1;; esac; done
mkdir -p logs
LOG="$PWD/logs/server.log"
step() { printf '\033[36m== %s\033[0m\n' "$*"; }
warn() { printf '\033[33m   ! %s\033[0m\n' "$*"; }

# ------------------------------------------------------------------ checks --
if [[ $UPDATE == 1 ]]; then
  step "Updating from git"; git -C "$REPO" pull --ff-only || warn "git pull failed (local changes?). Starting with what is here."
fi
[[ -x .venv/bin/python ]] || { echo "Python env missing. Run: bash server/host/setup-mac.sh"; exit 1; }
[[ $UPDATE == 1 ]] && { step "Python packages"; .venv/bin/pip install -q -r requirements.txt; }
[[ -f .env ]] || { cp .env.example .env; warn "created server/.env from .env.example"; }
grep -qE '^\s*SOLARIS_MOCK\s*=\s*1' .env && step "Mock data enabled; Mira still uses local Ollama and seeded history"
DB_PATH=$(.venv/bin/python -c 'from app.config import DB_PATH; print(DB_PATH)')
[[ -f "$DB_PATH" ]] || { step "No database yet: seeding 45 days of demo history"; .venv/bin/python tools/seed_history.py --meter; }

APK="$REPO/landing/downloads/solaris.apk"
if [[ -f "$APK" ]]; then step "APK found: landing/downloads/solaris.apk ($(( $(wc -c < "$APK") / 1048576 )) MB)"
else warn "No APK at landing/downloads/solaris.apk. Pull the repo (--update) or build it: bash scripts/build-apk.sh"; fi

if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Port $PORT is already in use:"; lsof -nP -iTCP:"$PORT" -sTCP:LISTEN; exit 1
fi

# ---------------------------------------------------------------- services --
MOSQ_PID=""; CAF_PID=""; SRV_PID=""
cleanup() {
  [[ -n "$SRV_PID" ]] && kill "$SRV_PID" 2>/dev/null
  [[ -n "$MOSQ_PID" ]] && kill "$MOSQ_PID" 2>/dev/null
  [[ -n "$CAF_PID" ]] && kill "$CAF_PID" 2>/dev/null
  exit 0
}
trap cleanup INT TERM

if lsof -nP -iTCP:1883 -sTCP:LISTEN >/dev/null 2>&1; then
  step "MQTT broker already running on :1883"
else
  MOSQ="$(brew --prefix 2>/dev/null)/sbin/mosquitto"
  [[ -x "$MOSQ" ]] || { echo "Mosquitto not installed. Run: bash server/host/setup-mac.sh"; exit 1; }
  step "Starting MQTT broker on :1883"
  "$MOSQ" -c mosquitto.conf -v > logs/mosquitto.log 2>&1 & MOSQ_PID=$!
fi

if [[ $NOAI == 0 ]]; then
  if command -v ollama >/dev/null; then
    pgrep -x ollama >/dev/null || pgrep -f "ollama serve" >/dev/null || { step "Starting Ollama"; (ollama serve >/dev/null 2>&1 &); sleep 3; }
    MODEL=$(grep -E '^\s*LLM_MODEL\s*=' .env | head -n1 | cut -d= -f2 | tr -d ' '); MODEL=${MODEL:-qwen3.5:9b}
    if ollama list 2>/dev/null | grep -qF "$MODEL"; then step "Ollama ready with $MODEL"
    else warn "Ollama model $MODEL is not pulled: ollama pull $MODEL  (Mira falls back to rule-based answers)"; fi
  else warn "Ollama not installed: Mira answers with rule-based replies."; fi
fi

caffeinate -dims -w $$ & CAF_PID=$!   # keep the Mac awake while this runs

# ------------------------------------------------------------------ banner --
IFACE=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
IP=$( { [[ -n "$IFACE" ]] && ipconfig getifaddr "$IFACE"; } || ipconfig getifaddr en0 || ipconfig getifaddr en1 || echo "<this-laptop-ip>")
NAME=$(scutil --get LocalHostName 2>/dev/null || hostname -s)
cat <<EOF

  Solaris is running (production)
  ------------------------------------------------------------
  Website       http://${IP}:${PORT}/
  Android app   http://${IP}:${PORT}/apk
  Web app       http://${IP}:${PORT}/app/
  In the app    Settings > server address:  ${IP}:${PORT}
  API docs      http://${IP}:${PORT}/docs
  MQTT broker   ${IP}:1883   (firmware: MQTT_MDNS_HOST "${NAME}", MQTT_HOST "${IP}")
  Logs          server/logs/server.log, server/logs/mosquitto.log
  Phones must be on the same Wi-Fi / hotspot as this laptop.
  Ctrl+C to stop
  ------------------------------------------------------------

EOF

# -------------------------------------------------------------- run + restart --
export PYTHONUNBUFFERED=1
while true; do
  printf '\n===== %s server start =====\n' "$(date +%FT%T)" >> "$LOG"
  .venv/bin/python -m uvicorn app.main:app --host 0.0.0.0 --port "$PORT" --proxy-headers --timeout-graceful-shutdown 5 \
    > >(tee -a "$LOG") 2>&1 &
  SRV_PID=$!
  wait "$SRV_PID"; code=$?
  SRV_PID=""
  warn "Server stopped (exit $code). Restarting in 3 s... (Ctrl+C to quit)"
  sleep 3
done
