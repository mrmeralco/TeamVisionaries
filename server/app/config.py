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

# LLM. Default: Qwen 3.5 on local Ollama. LLM_ENABLED=0 -> rule-based replies only.
# Cloud fallback: LLM_PROVIDER=openai + LLM_BASE_URL + LLM_MODEL + LLM_API_KEY (any OpenAI-compatible API).
LLM_ENABLED = _bool("LLM_ENABLED", "1")
LLM_PROVIDER = os.getenv("LLM_PROVIDER", "ollama")
OLLAMA_URL = os.getenv("OLLAMA_URL", "http://localhost:11434").rstrip("/")
LLM_MODEL = os.getenv("LLM_MODEL", "qwen3.5:4b")
LLM_BASE_URL = os.getenv("LLM_BASE_URL", "")
LLM_API_KEY = os.getenv("LLM_API_KEY", "")
LLM_TIMEOUT_S = float(os.getenv("LLM_TIMEOUT_S", "20"))   # per LLM call
CHAT_BUDGET_S = float(os.getenv("CHAT_BUDGET_S", "25"))   # whole /api/chat incl. one retry
LLM_KEEP_ALIVE = os.getenv("LLM_KEEP_ALIVE", "60m")
AI_LOG = Path(os.getenv("AI_LOG", SERVER_DIR / "logs" / "ai.jsonl"))

DEFAULT_SETTINGS = {
    "rate_php_per_kwh": float(os.getenv("DEFAULT_RATE", "13.0")),
    "battery_kwh": float(os.getenv("DEFAULT_BATTERY_KWH", "10.0")),
    "user_name": os.getenv("DEFAULT_USER_NAME", "Juan"),
    "device_id": os.getenv("DEFAULT_DEVICE_ID", "sinag-001"),
}
