#!/usr/bin/env bash
# One-time setup of the Solaris host on macOS: Mosquitto broker, Python env, .env, demo history, AI model.
#   bash server/host/setup-mac.sh            # everything
#   bash server/host/setup-mac.sh --skip-ai  # no Ollama model download (3.3 GB)
set -euo pipefail
cd "$(dirname "$0")/.."            # -> server/

SKIP_AI=0; [[ "${1:-}" == "--skip-ai" ]] && SKIP_AI=1

command -v brew >/dev/null || { echo "Install Homebrew first: https://brew.sh"; exit 1; }

echo "== Mosquitto (MQTT broker)"
brew list mosquitto >/dev/null 2>&1 || brew install mosquitto
brew services stop mosquitto >/dev/null 2>&1 || true   # we run it ourselves with server/mosquitto.conf

echo "== Python env"
PY=$(command -v python3.12 || command -v python3)
[[ -d .venv ]] || "$PY" -m venv .venv
.venv/bin/pip install -q --upgrade pip
.venv/bin/pip install -q -r requirements.txt

echo "== server/.env"
[[ -f .env ]] || cp .env.example .env

echo "== Demo history (45 days)"
[[ -f solaris.db ]] || .venv/bin/python tools/seed_history.py

if [[ $SKIP_AI == 0 ]]; then
  echo "== AI model (Ollama)"
  command -v ollama >/dev/null || brew install --cask ollama
  MODEL=$(grep -E '^LLM_MODEL=' .env | cut -d= -f2); MODEL=${MODEL:-qwen3.5:4b}
  pgrep -x ollama >/dev/null || (ollama serve >/dev/null 2>&1 &) ; sleep 2
  ollama pull "$MODEL"
fi

echo
echo "Setup done. Start everything with:  bash server/host/start-mac.sh"
