"""Contract C as code: one Pydantic model per response in docs/contracts/C-api.md.

These models are the backend's side of the contract:
- every route in main.py declares its `response_model`, so /docs and /openapi.json show the exact
  shapes the Flutter app gets, and FastAPI validates each response before sending it;
- tests/test_contract.py checks every file in docs/contracts/examples/ and every real-mode response
  against them, so the doc, the examples and the code can't drift apart silently.

Changing a model here = changing Contract C. Post in the group chat and get Aldrin's OK first,
then update C-api.md and the matching examples/*.json in the same commit.
"""
from typing import Literal

from pydantic import BaseModel, Field

State = Literal["solar", "battery", "grid", "brownout", "fault", "offline"]
AlertType = Literal["fault", "brownout", "grid_restored", "low_battery", "high_temp", "device_offline", "device_online"]
Severity = Literal["info", "warning", "critical"]
Source = Literal["llm", "fallback"]


# ---------------------------------------------------------------- /api/live --
class Device(BaseModel):
    id: str
    online: bool = Field(description="False when the MQTT last will fired or no telemetry for 30 s")
    rssi: int | None = None
    fw: str | None = None
    last_seen_ts: int | None = Field(None, description="Unix s of the latest telemetry; null if none yet")


class Telemetry(BaseModel):
    """Contract B telemetry, as stored."""
    ts: int
    pv_w: int
    load_w: int
    grid_w: int = Field(description="+ import, − export")
    batt_soc: int = Field(description="%")
    batt_w: int = Field(description="+ discharging, − charging")
    grid_on: bool = Field(description="false = brownout")
    inv_temp_c: int
    fault_code: int = Field(description="0 = OK")


class Live(BaseModel):
    device: Device
    telemetry: Telemetry | None = Field(description="null if nothing received yet")
    state: State
    status_line: str
    saved_today_php: float
    rate_php_per_kwh: float


# -------------------------------------------------------------- /api/energy --
class EnergyKwh(BaseModel):
    pv_kwh: float
    load_kwh: float
    grid_import_kwh: float
    grid_export_kwh: float
    batt_charge_kwh: float
    batt_discharge_kwh: float


class EnergyPoint(EnergyKwh):
    ts: int = Field(description="Bucket start, Unix s")
    label: str = Field(description='"14:00" (day), "Mon" (week), "Nov 3" (month)')


class Energy(BaseModel):
    period: Literal["day", "week", "month"]
    bucket: Literal["hour", "day"]
    start_ts: int
    end_ts: int
    points: list[EnergyPoint]
    totals: EnergyKwh
    self_sufficiency_pct: float = Field(description="(1 - grid_import / load) * 100")


# ---------------------------------------------------------------- /api/bill --
class WeeklyCost(BaseModel):
    week_start_ts: int
    label: str
    php: float


class Bill(BaseModel):
    month: str = Field(description="YYYY-MM", pattern=r"^\d{4}-\d{2}$")
    days_elapsed: int
    days_in_month: int
    rate_php_per_kwh: float
    month_to_date_kwh: float
    month_to_date_php: float
    forecast_php: float
    forecast_low_php: float
    forecast_high_php: float
    last_month_php: float | None = Field(description="null if no data for last month")
    vs_last_month_pct: float | None = Field(description="forecast vs last month; null if no last month")
    savings_today_php: float
    savings_month_php: float
    weekly_costs: list[WeeklyCost]


# ------------------------------------------------------------ /api/brownout --
class Brownout(BaseModel):
    active: bool
    start_ts: int | None = Field(description="Current outage, or the last one when not active; null if none")
    duration_min: int | None
    batt_soc: int | None
    load_w: int | None
    runtime_h: float | None = Field(description="(soc% x battery_kwh) / load; null if load is 0")
    advice: str
    outages_this_month: int


# ------------------------------------------------------------- /api/outlook --
class OutlookHour(BaseModel):
    ts: int = Field(description="Hour start, Unix s. The first hour is the current one.")
    pv_kwh: float = Field(description="Forecast solar for the full hour")
    load_kwh: float = Field(description="Typical home use for this hour of the day")
    soc_pct: float | None = Field(description="Projected battery % at the end of the hour, grid on; null if no telemetry")
    cloud_pct: int | None = Field(description="Cloud cover; null when the hour has no weather forecast")


class OutlookBattery(BaseModel):
    soc_pct: int | None = Field(description="Now; null if no telemetry yet")
    reserve_pct: int = Field(description="Below this the inverter switches the house to the grid")
    reserve_ts: int | None = Field(description="When the battery reaches reserve_pct; null if not within 48 h")
    full_ts: int | None = Field(description="When the sun fills it to 100 %; null if not within 48 h")
    tomorrow_max_soc_pct: float | None = Field(description="Highest projected % tomorrow; null if no telemetry")
    grid_kwh_24h: float = Field(description="Projected grid import over the next 24 h")


class OutlookBrownout(BaseModel):
    """What happens if the grid is out from now on (the real projection when `active`)."""
    active: bool = Field(description="A brownout is happening now")
    cutoff_pct: int = Field(description="The inverter shuts down at this %")
    lasts_until_ts: int | None = Field(description="When the battery hits cutoff_pct, sun included; null = lasts past 48 h")
    hours: float | None = Field(description="Hours from now until then; null = more than 48")


class Outlook(BaseModel):
    generated_ts: int
    source: Literal["weather", "history"] = Field(description="history = no weather forecast; solar from the last 14 days")
    solar_today_kwh: float = Field(description="Produced so far today + forecast for the rest of today")
    solar_tomorrow_kwh: float
    solar_typical_kwh: float | None = Field(description="Average day, last 14 days; null without 14 days of history")
    battery: OutlookBattery
    brownout: OutlookBrownout | None = Field(description="null if no telemetry yet")
    advice: str = Field(min_length=1)
    hours: list[OutlookHour] = Field(min_length=48, max_length=48)


# ------------------------------------------------------ /api/bill/projection --
class ProjectionMonth(BaseModel):
    month: str = Field(description='"2026-12"')
    label: str = Field(description='"Disyembre 2026"')
    months_ahead: int = Field(ge=0, description="0 = this month")
    kind: Literal["forecast", "projection"] = Field(description="forecast = this month only; projection = rougher estimate")
    grid_kwh: float
    low_kwh: float | None = Field(description="null for this month (its range is in pesos only)")
    high_kwh: float | None
    bill_php: float
    low_php: float
    high_php: float
    load_kwh: float | None = Field(description="Projected home use; null for this month")
    solar_kwh: float | None = Field(description="Projected solar; null for this month")
    range_pct: int | None = Field(description="+- share of the projection range, capped at 100 (low_kwh then 0); grows each month; null for this month")


class Projection(BaseModel):
    generated_ts: int
    enough_data: bool = Field(description="false until 14 days of history: only this month's forecast")
    basis_days: int = Field(description="Days of history the projection is based on")
    rate_php_per_kwh: float = Field(description="Today's rate, assumed for every month")
    max_months: int = Field(description="Months after this one that are ever projected (3)")
    months: list[ProjectionMonth] = Field(min_length=1, description="This month first")


# ------------------------------------------------------------- /api/upgrade --
class UpgradeSystem(BaseModel):
    pv_kwp: float = Field(description="Installed solar (PV_KWP)")
    battery_kwh: float = Field(description="Battery size (settings)")
    inverter_kw: float = Field(description="Inverter AC rating (INVERTER_KW)")


class UpgradeUsage(BaseModel):
    """Daily averages over the days checked (the home's own readings)."""
    days: int
    load_kwh_day: float
    pv_kwh_day: float
    grid_import_kwh_day: float
    day_import_kwh_day: float = Field(description="Bought from the grid 6 AM-6 PM")
    night_import_kwh_day: float = Field(description="Bought from the grid 6 PM-6 AM")
    export_kwh_day: float = Field(description="Solar sent to the grid unused")
    self_sufficiency_pct: int
    battery_empty_days_pct: int = Field(description="Days the battery reached its reserve with the grid on")
    peak_load_w: int
    p95_load_w: int
    load_trend_pct: int | None = Field(description="Last 7 days vs the weeks before; null without 2 weeks of data")


class UpgradeEvidence(BaseModel):
    label: str
    value: str


class UpgradeRec(BaseModel):
    id: Literal["battery", "solar", "inverter", "usage"]
    priority: int = Field(ge=1, description="1 = best payback first; usage notes come last")
    title: str
    add: str = Field(description='Size to add or move to, e.g. "+5 kWh", "+1.5 kWp", "8 kW"')
    reason: str = Field(min_length=1, description="Taglish, built from the usage numbers")
    evidence: list[UpgradeEvidence]
    savings_php_month: int | None = Field(description="Rough; null when it doesn't save money directly")
    cost_php: int | None = Field(description="Rough installed price from config; null for usage notes")
    payback_years: float | None


class Upgrade(BaseModel):
    generated_ts: int
    enough_data: bool = Field(description="false until 7 days of readings")
    verdict: Literal["ok", "consider", "unknown"] = Field(description="consider = at least one hardware upgrade")
    headline: str = Field(min_length=1)
    system: UpgradeSystem
    usage: UpgradeUsage | None
    recommendations: list[UpgradeRec]


# -------------------------------------------------------------- /api/alerts --
class Alert(BaseModel):
    id: int
    ts: int
    type: AlertType
    severity: Severity
    title: str
    message: str
    read: bool


class AlertList(BaseModel):
    unread: int
    alerts: list[Alert] = Field(description="Newest first, max 100")


class ReadAll(BaseModel):
    unread: Literal[0]


# ---------------------------------------------------------------- /api/chat --
class ChatIn(BaseModel):
    message: str = Field(min_length=1, max_length=500)


class Chip(BaseModel):
    label: str
    value: str


class ChatSource(BaseModel):
    """One piece of the user's data behind an answer (see server/ai/sources.py)."""
    id: str = Field(description="Fact id, same as in facts_used")
    label: str = Field(description='Short name, e.g. "Bill forecast"')
    value: str | None = Field(None, description='Headline value, e.g. "₱2,450"')
    detail: str = Field(description="The fact as one Taglish sentence, with its full numbers")
    kind: Literal["live", "history", "forecast", "settings", "advice"]
    period: str = Field(description='What time it covers, e.g. "This month"')
    screen: Literal["home", "energy", "bill", "brownout", "alerts", "settings"] | None = Field(
        None, description="App screen that shows this data")
    as_of_ts: int | None = Field(None, description="When it was measured (live) or computed; null for settings")


class Chat(BaseModel):
    reply: str
    chips: list[Chip]
    source: Source = Field(description="fallback = LLM down, too slow, or failed the fact check")
    facts_used: list[str] = Field(default_factory=list, description="Ids of the facts behind the answer")
    sources: list[ChatSource] = Field(default_factory=list, description="The data behind the answer, for the app to show")


# ------------------------------------------------------- /api/summary/daily --
class SummaryTotals(BaseModel):
    pv_kwh: float
    load_kwh: float
    grid_import_kwh: float
    cost_php: float
    savings_php: float
    self_sufficiency_pct: float


class DailySummary(BaseModel):
    date: str = Field(description="YYYY-MM-DD (yesterday, Asia/Manila)", pattern=r"^\d{4}-\d{2}-\d{2}$")
    summary: str
    totals: SummaryTotals
    source: Source


# ------------------------------------------------------------ /api/settings --
class Settings(BaseModel):
    rate_php_per_kwh: float
    battery_kwh: float
    user_name: str
    device_id: str


class SettingsIn(BaseModel):
    """PUT body: any subset of Settings."""
    rate_php_per_kwh: float | None = Field(None, gt=0, lt=100)
    battery_kwh: float | None = Field(None, gt=0, lt=200)
    user_name: str | None = Field(None, max_length=40)
    device_id: str | None = Field(None, max_length=32)


# -------------------------------------------------------------- /api/health --
class Health(BaseModel):
    ok: bool
    mock: bool
    llm: str | None
    llm_provider: str
    llm_reachable: bool


# ----------------------------------------------------------------- /ws/live --
class Meter(BaseModel):
    """Contract B meter payload + device_id. Extra fields from the meter are passed through."""
    model_config = {"extra": "allow"}
    device_id: str
    ts: int
    meter_type: Literal["sdm120", "ansi-c12"]


class WsTelemetry(BaseModel):
    type: Literal["telemetry"]
    data: Live


class WsAlert(BaseModel):
    type: Literal["alert"]
    data: Alert


class WsStatus(BaseModel):
    type: Literal["status"]
    data: Device


class WsMeter(BaseModel):
    type: Literal["meter"]
    data: Meter


WsMessage = WsTelemetry | WsAlert | WsStatus | WsMeter
