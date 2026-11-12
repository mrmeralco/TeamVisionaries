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
MOCK = _bool("SOLARIS_MOCK")

DB_PATH = Path(os.getenv("SOLARIS_DB", SERVER_DIR / "solaris.db"))
# Mock mode has no DB: the settings saved in it (setup, name, rate) are kept here, so a restart keeps them.
MOCK_SETTINGS_PATH = Path(os.getenv("SOLARIS_MOCK_SETTINGS", SERVER_DIR / "mock_settings.json"))
TZ = ZoneInfo(os.getenv("SOLARIS_TZ", "Asia/Manila"))
EXAMPLES_DIR = REPO_DIR / "docs" / "contracts" / "examples"

MQTT_HOST = os.getenv("MQTT_HOST", "localhost")
MQTT_PORT = int(os.getenv("MQTT_PORT", "1883"))
MQTT_ENABLED = _bool("MQTT_ENABLED", "1")
MERALCO_RATE_ENABLED = _bool("MERALCO_RATE_ENABLED", "1")

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
# -1 leaves GPU allocation to Ollama; 0 uses CPU only.
LLM_GPU_LAYERS = int(os.getenv("LLM_GPU_LAYERS", "-1"))
AI_LOG = Path(os.getenv("AI_LOG", SERVER_DIR / "logs" / "ai.jsonl"))

# Bill forecast of daily kWh: "sarima" (weekly SARIMA, falls back to averages with < 4 weeks of history
# or no statsmodels) or "average" (weekday/weekend averages). Compare on your data: tools/backtest_forecast.py
FORECAST_METHOD = os.getenv("FORECAST_METHOD", "sarima")

# Solar + battery outlook. Weather: Open-Meteo (free, no key); only SITE_LAT/SITE_LON are sent.
WEATHER_ENABLED = _bool("WEATHER_ENABLED", "1")
WEATHER_URL = os.getenv("WEATHER_URL", "https://api.open-meteo.com/v1/forecast")
SITE_LAT = float(os.getenv("SITE_LAT", "14.5995"))   # Metro Manila
SITE_LON = float(os.getenv("SITE_LON", "120.9842"))
PV_KWP = float(os.getenv("PV_KWP", "5.0"))           # until there's a week of history to calibrate on
BATT_RESERVE_PCT = int(os.getenv("BATT_RESERVE_PCT", "20"))  # grid takes over below this
BATT_CUTOFF_PCT = int(os.getenv("BATT_CUTOFF_PCT", "5"))     # inverter shuts down here in a brownout
BATT_MAX_KW = float(os.getenv("BATT_MAX_KW", "3.0"))

# System check (/api/upgrade): the installed system and rough installed prices for the payback estimate.
# Prices are ballpark PH 2026 figures; set them from an installer's quote for real advice.
INVERTER_KW = float(os.getenv("INVERTER_KW", "5.0"))                          # hybrid inverter AC rating
UPGRADE_DAYS = int(os.getenv("UPGRADE_DAYS", "30"))                           # history the check looks at
UPGRADE_PV_PHP_PER_KWP = float(os.getenv("UPGRADE_PV_PHP_PER_KWP", "35000"))  # added panels, installed
UPGRADE_BATTERY_PHP_PER_KWH = float(os.getenv("UPGRADE_BATTERY_PHP_PER_KWH", "20000"))  # LiFePO4 module, installed
UPGRADE_INVERTER_PHP = float(os.getenv("UPGRADE_INVERTER_PHP", "70000"))      # bigger hybrid inverter, installed

# Solar plan (/api/solar-plan): sizing solar for a home that has none yet. Yield = kWh a day per kWp on an
# average Philippine day (about 4.5 peak sun hours x 0.8 losses). Prices are ballpark PH 2026 installed figures
# (panels reuse UPGRADE_PV_PHP_PER_KWP, batteries UPGRADE_BATTERY_PHP_PER_KWH); set them from a quote.
SOLAR_YIELD_KWH_PER_KWP_DAY = float(os.getenv("SOLAR_YIELD_KWH_PER_KWP_DAY", "3.6"))
SOLAR_PANEL_W = float(os.getenv("SOLAR_PANEL_W", "580"))            # one panel, W
SOLAR_PANEL_M2 = float(os.getenv("SOLAR_PANEL_M2", "2.6"))          # roof area per panel incl. spacing
SOLAR_GRIDTIE_INVERTER_PHP_PER_KW = float(os.getenv("SOLAR_GRIDTIE_INVERTER_PHP_PER_KW", "9000"))
SOLAR_HYBRID_INVERTER_PHP_PER_KW = float(os.getenv("SOLAR_HYBRID_INVERTER_PHP_PER_KW", "14000"))
SOLAR_EXPORT_PHP_PER_KWH = float(os.getenv("SOLAR_EXPORT_PHP_PER_KWH", "6.0"))   # net metering credit
# Sponsored slots under the plan: a JSON list of {id, kind, name, tagline, url}; placeholders when missing.
SPONSORS_FILE = Path(os.getenv("SPONSORS_FILE", SERVER_DIR / "sponsors.json"))

# Solar tips (/api/tips): kg of CO₂ the Philippine grid emits per kWh, for "CO₂ avoided" (Luzon-Visayas grid,
# DOE grid emission factor, about 0.71 t/MWh).
GRID_CO2_KG_PER_KWH = float(os.getenv("GRID_CO2_KG_PER_KWH", "0.71"))

# Smart meter mode (/api/meter): the grid's nominal voltage and the band the distribution code allows (±10 %).
GRID_NOMINAL_V = float(os.getenv("GRID_NOMINAL_V", "230"))
GRID_V_TOLERANCE = float(os.getenv("GRID_V_TOLERANCE", "0.10"))

# What the household has: "solar" (hybrid inverter, the original Solaris), "meter_only" (a smart or utility
# meter and no solar: everything comes from the meter) or "solar_and_meter" (both; the meter is the
# utility-side truth for the bill).
SETUPS = ("solar", "meter_only", "solar_and_meter")

DEFAULT_SETTINGS = {
    "rate_php_per_kwh": float(os.getenv("DEFAULT_RATE", "15.06")),  # Meralco overall rate, Oct 2026
    "battery_kwh": float(os.getenv("DEFAULT_BATTERY_KWH", "10.0")),
    "user_name": os.getenv("DEFAULT_USER_NAME", "Juan"),
    "device_id": os.getenv("DEFAULT_DEVICE_ID", "solaris-001"),
    "setup": os.getenv("DEFAULT_SETUP", "solar"),
}
