"""All server settings come from environment variables (or server/.env)."""
import os
from pathlib import Path
from zoneinfo import ZoneInfo

SERVER_DIR = Path(__file__).resolve().parent.parent
REPO_DIR = SERVER_DIR.parent


def _load_dotenv() -> None:
    env = SERVER_DIR / ".env"
    if not env.exists():
        return
    for line in env.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            os.environ.setdefault(k.strip(), v.strip())


_load_dotenv()


def _bool(name: str, default: str = "0") -> bool:
    return os.getenv(name, default).lower() in ("1", "true", "yes", "on")


# Serve docs/contracts/examples/*.json instead of real data (no broker or DB needed).
MOCK = _bool("SINAG_MOCK")

DB_PATH = Path(os.getenv("SINAG_DB", SERVER_DIR / "sinag.db"))
TZ = ZoneInfo(os.getenv("SINAG_TZ", "Asia/Manila"))
EXAMPLES_DIR = REPO_DIR / "docs" / "contracts" / "examples"

MQTT_HOST = os.getenv("MQTT_HOST", "localhost")
MQTT_PORT = int(os.getenv("MQTT_PORT", "1883"))
MQTT_ENABLED = _bool("MQTT_ENABLED", "1")

# Device is "offline" if no telemetry for this long, even without a last-will message.
OFFLINE_AFTER_S = int(os.getenv("OFFLINE_AFTER_S", "30"))

# LLM: any OpenAI-compatible /chat/completions endpoint. Ollama serves one at /v1.
# Cloud fallback = change LLM_BASE_URL + LLM_MODEL (+ LLM_API_KEY). LLM_ENABLED=0 -> rule-based replies only.
LLM_ENABLED = _bool("LLM_ENABLED", "1")
LLM_BASE_URL = os.getenv("LLM_BASE_URL", "http://localhost:11434/v1")
LLM_MODEL = os.getenv("LLM_MODEL", "qwen2.5:3b")
LLM_API_KEY = os.getenv("LLM_API_KEY", "ollama")
LLM_TIMEOUT_S = float(os.getenv("LLM_TIMEOUT_S", "20"))

DEFAULT_SETTINGS = {
    "rate_php_per_kwh": float(os.getenv("DEFAULT_RATE", "13.0")),
    "battery_kwh": float(os.getenv("DEFAULT_BATTERY_KWH", "10.0")),
    "user_name": os.getenv("DEFAULT_USER_NAME", "Juan"),
    "device_id": os.getenv("DEFAULT_DEVICE_ID", "sinag-001"),
}
