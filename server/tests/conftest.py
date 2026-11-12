"""Tests run against a throwaway SQLite DB seeded with fake history. No broker, no Ollama needed."""
import os
import subprocess
import sys
import tempfile
from pathlib import Path

SERVER = Path(__file__).resolve().parent.parent
_tmp = tempfile.mkdtemp(prefix="sinag-test-")
os.environ.update({"SINAG_DB": f"{_tmp}/test.db", "MQTT_ENABLED": "0", "AI_LOG": f"{_tmp}/ai.jsonl", "SINAG_MOCK": "0"})
sys.path.insert(0, str(SERVER))
subprocess.run([sys.executable, str(SERVER / "tools" / "seed_history.py"), "--days", "40"], check=True, env=os.environ,
               stdout=subprocess.DEVNULL)
