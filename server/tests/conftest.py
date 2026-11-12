"""Tests run against a throwaway SQLite DB seeded with fake history. No broker, no Ollama needed."""
import os
import subprocess
import sys
import tempfile
from pathlib import Path

import pytest

SERVER = Path(__file__).resolve().parent.parent
_tmp = tempfile.mkdtemp(prefix="solaris-test-")
os.environ.update({"SOLARIS_DB": f"{_tmp}/test.db", "MQTT_ENABLED": "0", "AI_LOG": f"{_tmp}/ai.jsonl",
                   "SOLARIS_MOCK": "0", "LLM_ENABLED": "0", "WEATHER_ENABLED": "0"})
sys.path.insert(0, str(SERVER))
sys.path.insert(0, str(SERVER.parent / "tests"))  # solaris_contract.py
subprocess.run([sys.executable, str(SERVER / "tools" / "seed_history.py"), "--days", "40", "--meter", "--meter-type", "ansi-c12"],
               check=True, env=os.environ, stdout=subprocess.DEVNULL)
# Smart meter mode: a home with a meter and no solar (tests/test_meter_mode.py switches settings to it).
METER_ONLY_DEVICE = "meter-001"
subprocess.run([sys.executable, str(SERVER / "tools" / "seed_history.py"), "--days", "40", "--meter-only",
                "--device", METER_ONLY_DEVICE], check=True, env=os.environ, stdout=subprocess.DEVNULL)


@pytest.fixture
def client():
    from fastapi.testclient import TestClient

    from app.main import app
    with TestClient(app) as c:
        yield c


@pytest.fixture
def mock_client(monkeypatch):
    from fastapi.testclient import TestClient

    from app import config
    from app.main import app
    monkeypatch.setattr(config, "MOCK", True)
    with TestClient(app) as c:
        yield c


_n = 0


@pytest.fixture
def device():
    """A fresh device id, so a test's telemetry never mixes with the seeded history or other tests."""
    global _n
    _n += 1
    return f"test-{_n}"
