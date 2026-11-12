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
Setup = Literal["solar", "meter_only", "solar_and_meter"]
MeterType = Literal["sdm120", "ansi-c12"]


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


class MeterReading(BaseModel):
    """Contract B meter payload, as stored (smart meter A2 or Meralco meter A3)."""
    ts: int
    meter_type: MeterType
    voltage_v: float
    current_a: float | None = None
    power_w: float = Field(description="+ import, − export")
    apparent_va: float | None = None
    reactive_var: float | None = None
    pf: float | None = Field(None, ge=-1, le=1)
    freq_hz: float | None = None
    import_kwh: float = Field(description="Meter register: kWh bought from the grid since it was installed")
    export_kwh: float
    grid_on: bool


class Live(BaseModel):
    device: Device
    telemetry: Telemetry | None = Field(description="null if nothing received yet; always null when setup is meter_only")
    state: State
    status_line: str
    saved_today_php: float
    rate_php_per_kwh: float
    setup: Setup = Field("solar", description="The household's setup (settings)")
    meter: MeterReading | None = Field(None, description="Latest meter reading; null for setup solar or before one arrives")


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


class BillDay(BaseModel):
    day: int = Field(ge=1, le=31)
    kwh: float = Field(description="Grid kWh that day: metered (actual), expected full day (today, forecast)")
    kind: Literal["actual", "today", "forecast"]
    cum_kwh: float = Field(description="Month's running total at the end of the day")
    cum_low_kwh: float = Field(description="Likely range of the running total; = cum_kwh on metered days")
    cum_high_kwh: float


class LevelStep(BaseModel):
    at_kwh: float = Field(description="The level boundary")
    kwh_away: float = Field(description="kWh between the forecast and the boundary")
    jump_php: float = Field(description="Crossing it moves the whole month's kWh to the next distribution rate: "
                                        "the bill's jump at the boundary, on top of the extra kWh themselves")


class BillLevel(BaseModel):
    min_kwh: float = Field(description="Lower boundary (the level is over this; 0 = from the first kWh)")
    max_kwh: float | None = Field(description="Upper boundary; null = the open top level")
    distribution_php_per_kwh: float = Field(description="This level's distribution charge, before VAT")
    up: LevelStep | None = Field(description="The next level up; null at the top level")
    down: LevelStep | None = Field(description="The level below; null at the lowest level")


class BillCharge(BaseModel):
    id: Literal["energy", "distribution", "fixed", "energy_tax"] = Field(
        description="energy: generation, transmission, system loss, subsidies and taxes in the overall rate | "
                    "distribution: the level's distribution charge on all the month's kWh, + VAT | "
                    "fixed: supply + metering, + VAT | energy_tax: BP 36, kWh above 650")
    kwh: float | None = Field(description="kWh it is charged on; null for fixed charges")
    php_per_kwh: float | None = Field(description="incl. VAT; null when not per kWh")
    php: float = Field(description="The parts add up to forecast_php")


class DistributionRate(BaseModel):
    max_kwh: float | None = Field(description="Level's upper boundary; null = over the last one")
    php_per_kwh: float = Field(description="Before VAT")


class BillRates(BaseModel):
    source: str = Field(description="The Meralco schedule the tables come from")
    overall_php_per_kwh: float = Field(description="The rate setting: Meralco's overall rate for a 200 kWh home")
    vat_pct: float
    supply_php: float = Field(description="Per month, before VAT")
    metering_php: float = Field(description="Per month, before VAT")
    distribution: list[DistributionRate]
    energy_tax_from_kwh: float


class ForecastDetail(BaseModel):
    """How forecast_php is made: the evidence the Bill screen shows."""
    kwh: float = Field(description="Expected grid kWh for the whole month (priced into forecast_php)")
    low_kwh: float
    high_kwh: float
    method: Literal["sarima", "average"] = Field(description="sarima: weekly SARIMA model | average: weekday/weekend averages")
    model: str
    history_days: int = Field(description="Past days with data the model learned from (up to 56)")
    done_days: int = Field(description="Finished days this month (metered)")
    done_kwh: float
    days_left: int = Field(description="Today and the days after it (forecast)")
    days_left_kwh: float
    recent_kwh_per_day: float | None = Field(description="Average of the last 14 days, season-adjusted; null under 7 days")
    level: BillLevel = Field(description="The consumption level the forecast lands in")
    charges: list[BillCharge]
    rates: BillRates
    days: list[BillDay] = Field(description="Every day of the month: running total, metered then forecast")


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
    grid_source: Literal["inverter", "meter"] = Field(
        "inverter", description="Where the grid kWh come from: the meter whenever the home has one")
    forecast_detail: ForecastDetail | None = Field(
        None, description="How the forecast is made: kWh, level, charges, rates, day by day; null on older servers")


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


# ---------------------------------------------------------------- /api/tips --
class TipWindow(BaseModel):
    """The next WINDOW_H hours with the most solar left over after typical use."""
    start_ts: int
    end_ts: int
    surplus_kwh: float = Field(description="Forecast solar minus typical home use over the window")
    day: Literal["today", "tomorrow"]


class TipImpact(BaseModel):
    """This month so far."""
    month: str = Field(pattern=r"^\d{4}-\d{2}$")
    solar_kwh: float = Field(description="Made by the panels")
    clean_share_pct: float = Field(description="Home use not bought from the grid (self-sufficiency)")
    co2_avoided_kg: float = Field(description="solar_kwh x GRID_CO2_KG_PER_KWH")
    trees: int = Field(ge=0, description="Grown trees that take up that much CO₂ in a year")


class Tip(BaseModel):
    id: str = Field(description="surplus_now | grid_now | best_window | cloudy_tomorrow | shift_to_day | "
                                "spread_loads | precool | general")
    kind: Literal["now", "today", "habit", "general"]
    priority: int = Field(ge=1, description="1 = most urgent")
    title: str = Field(min_length=1)
    body: str = Field(min_length=1, description="Taglish, built from the home's numbers")
    evidence: list[UpgradeEvidence]
    savings_php_month: int | None = Field(description="Rough upper bound; null when not directly about money")


class Tips(BaseModel):
    generated_ts: int
    best_window: TipWindow | None = Field(description="null when no window has enough sun (today or tomorrow)")
    impact: TipImpact | None = Field(description="null before any solar this month")
    tips: list[Tip] = Field(min_length=1, description="Most urgent first; always ends with one general tip")


# ----------------------------------------------------------- /api/household --
class HouseholdNow(BaseModel):
    """The last 30 minutes of home use against the household's routine."""
    state: Literal["active", "asleep", "away", "quiet", "unknown"] = Field(
        description="active = someone is using things; asleep / away = only the always-on load, at an hour the "
                    "house usually sleeps / is empty; quiet = only the always-on load at a usually busy hour; "
                    "unknown = device offline or no data")
    likely_home: bool | None = Field(description="null when it can't be told")
    load_w: int | None = Field(description="Average home use over the last 30 minutes")
    usual_home_pct: int | None = Field(ge=0, le=100, description="How often the house is active at this hour")
    unusual: bool = Field(description="Active at an hour that is active less than 20 % of the time")
    next_active_ts: int | None = Field(description="When not active: start of the next usually-busy hour")
    text: str = Field(min_length=1, description="Taglish, built from the numbers above")


class AwayWindow(BaseModel):
    start_hour: int = Field(ge=0, le=23)
    end_hour: int = Field(ge=0, le=24)


class RoutineDay(BaseModel):
    wake_hour: int | None = Field(ge=0, le=23, description="End of the quiet stretch around 3 AM")
    sleep_hour: int | None = Field(ge=0, le=23, description="Start of the quiet stretch around 3 AM; null if "
                                                            "the house is busy all night (e.g. aircon)")
    away: AwayWindow | None = Field(description="Longest daytime quiet stretch, 3 h+")
    peak_hour: int = Field(ge=0, le=23)
    home_pct: list[int] = Field(min_length=24, max_length=24, description="% of time active, per hour 0-23")
    avg_w: list[int] = Field(min_length=24, max_length=24, description="Average home use per hour 0-23")


class Routine(BaseModel):
    weekday: RoutineDay | None
    weekend: RoutineDay | None


class Archetype(BaseModel):
    id: Literal["away_daytime", "home_daytime", "mixed", "unknown"]
    label: str
    description: str


class Trait(BaseModel):
    id: str = Field(description="early_riser | night_owl | night_load | evening_peak | weekend_home | high_baseload")
    label: str


class Baseload(BaseModel):
    watts: int = Field(ge=0, description="Always-on use: 10th percentile of 15-minute averages")
    kwh_month: float
    php_month: int = Field(description="Upper bound: at the full rate, as if none of it came from the sun")
    share_pct: float = Field(ge=0, le=100, description="Share of all home use")


class NewLoad(BaseModel):
    """Use that appeared in the last few days, compared with the 4 weeks before: maybe a new appliance."""
    id: str
    kind: Literal["always_on", "scheduled"]
    start_hour: int | None = Field(ge=0, le=23, description="scheduled only")
    end_hour: int | None = Field(ge=0, le=23, description="scheduled only (exclusive)")
    added_w: int
    kwh_day: float
    php_month: int = Field(description="Upper bound: kwh_day x 30 x rate")
    since_ts: int = Field(description="Local midnight of the first day it showed")
    days_seen: int = Field(ge=1)
    guess: str = Field(description="What it might be, from its watts and hours (Taglish)")
    text: str = Field(min_length=1)


class Household(BaseModel):
    generated_ts: int
    now: HouseholdNow
    days_used: int = Field(ge=0, description="Days with data in the last 28")
    confidence: Literal["none", "low", "medium", "high"] = Field(description="none < 3 days, low < 7, medium < 21")
    baseload: Baseload | None
    daylight_use_pct: float | None = Field(description="Share of home use between 6 AM and 6 PM")
    routine: Routine
    archetype: Archetype
    traits: list[Trait]
    new_loads: list[NewLoad] = Field(max_length=2, description="Biggest first")


# --------------------------------------------------------------- /api/meter --
class MeterQuality(BaseModel):
    nominal_v: float = Field(description="GRID_NOMINAL_V (230)")
    low_limit_v: float = Field(description="nominal - GRID_V_TOLERANCE")
    high_limit_v: float
    voltage_status: Literal["normal", "low", "high", "off"] = Field(description="Now; off = brownout")
    min_v_24h: float | None = Field(description="Last 24 h with the grid on; null without readings")
    avg_v_24h: float | None
    max_v_24h: float | None
    out_of_range_pct_24h: float | None = Field(description="Share of last-24 h readings outside the limits")
    pf_status: Literal["good", "fair", "poor"] | None = Field(description="good >= 0.90, fair >= 0.80; null if the meter has no PF")


class MeterUsage(BaseModel):
    """Last 7 finished days of grid import from the meter (= home use when setup is meter_only)."""
    days: int = Field(ge=1, description="Days with readings")
    import_kwh_day: float
    base_w: int = Field(description="Always-on use: 10th percentile of the power drawn")
    peak_w: int
    peak_hours: list[int] = Field(description="Up to 3 hours of the day (0-23) with the most use, ascending")
    night_share_pct: int = Field(description="Share used 6 PM-6 AM")
    weekday_kwh_day: float | None
    weekend_kwh_day: float | None
    by_hour_kwh: list[float] = Field(min_length=24, max_length=24, description="Typical day: kWh in each hour 0-23")


class MeterTier(BaseModel):
    """Where this month lands in Meralco's consumption levels (the whole month pays its level's rate)."""
    month: str = Field(pattern=r"^\d{4}-\d{2}$")
    days_left: int = Field(description="Including today")
    month_to_date_kwh: float
    forecast_kwh: float = Field(description="Same forecast as /api/bill")
    level_min_kwh: float = Field(description="Level the forecast is in: above this ...")
    level_max_kwh: float | None = Field(description="... up to this; null = open-ended (over 400 kWh)")
    rate_php_per_kwh: float = Field(description="₱/kWh at that level (fixed charges not included)")
    kwh_above_lower_level: float | None = Field(description="Forecast minus level_min_kwh; null in the lowest level")
    save_php_at_lower_level: int | None = Field(description="₱ saved if the month ends at level_min_kwh instead")
    kwh_to_next_level: float | None = Field(description="kWh left before the dearer level; null in the top level")
    next_level_rate_php_per_kwh: float | None


class MeterInsight(BaseModel):
    id: Literal["voltage", "power_factor", "tier_drop", "tier_near", "tier", "peak_hours", "base_load", "reading"]
    tone: Literal["info", "good", "warning"]
    title: str = Field(min_length=1)
    body: str = Field(min_length=1, description="Taglish, built from this response's numbers")
    evidence: list[UpgradeEvidence]


class MeterInfo(BaseModel):
    generated_ts: int
    setup: Setup
    online: bool = Field(description="A fresh meter reading within OFFLINE_AFTER_S")
    reading: MeterReading | None = Field(description="null until the first meter reading")
    quality: MeterQuality | None
    usage: MeterUsage | None = Field(description="null until a full day of meter readings")
    tier: MeterTier | None = Field(description="null when the bill doesn't come from the meter")
    insights: list[MeterInsight] = Field(description="Warnings first, then money, habits, the reading")


# ---------------------------------------------------------- /api/solar-plan --
class SolarPlanUsage(BaseModel):
    """The household's typical day, last 30 days (the meter, in a home without solar)."""
    kwh_day: float
    day_kwh_day: float = Field(description="6 AM-6 PM")
    night_kwh_day: float
    night_share_pct: int = Field(ge=0, le=100)
    peak_w: int = Field(description="99th percentile of home use, last 7 days")
    bill_php_month: int = Field(description="A 30-day month at this use, today's rate and tiers")


class SolarOption(BaseModel):
    id: Literal["grid_tie", "hybrid"]
    recommended: bool
    title: str
    pv_kwp: float
    panels: int = Field(ge=1)
    panel_w: int
    roof_m2: int = Field(description="Roof area the panels need, incl. spacing")
    inverter_kw: float
    battery_kwh: float | None = Field(description="null for grid_tie")
    solar_kwh_day: float = Field(description="Made on an average PH day")
    covers_pct: int = Field(ge=0, le=100, description="Share of home use from solar or battery")
    export_kwh_day: float
    bill_before_php_month: int
    bill_after_php_month: int = Field(description="Tiered bill for what's still bought, minus net metering credit")
    savings_php_month: int
    cost_php: int = Field(description="Rough installed price (config)")
    payback_years: float | None
    backup_hours: float | None = Field(description="Battery at the usual night load in a brownout; null without one")
    co2_kg_year: int
    why: str


class Sponsor(BaseModel):
    """Ad slot shown apart from the recommendation, labelled as sponsored."""
    id: str
    kind: Literal["installer", "panel_brand", "inverter_brand", "battery_brand", "financing"]
    name: str
    tagline: str
    url: str | None
    placeholder: bool = Field(description="true = an empty slot (no SPONSORS_FILE)")


class SolarPlan(BaseModel):
    generated_ts: int
    setup: Setup
    has_solar: bool = Field(description="true -> no options (see /api/upgrade)")
    days: int = Field(ge=0, description="Days with data, last 30")
    headline: str = Field(min_length=1)
    usage: SolarPlanUsage | None = Field(description="null with < 7 days of data or when the home has solar")
    options: list[SolarOption] = Field(max_length=2, description="Recommended first; [] when usage is null")
    yield_kwh_per_kwp_day: float
    sponsors: list[Sponsor]
    disclaimer: str


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
    setup: Setup = Field(description="solar | meter_only (smart meter, no solar) | solar_and_meter")


class SettingsIn(BaseModel):
    """PUT body: any subset of Settings."""
    rate_php_per_kwh: float | None = Field(None, gt=0, lt=100)
    battery_kwh: float | None = Field(None, gt=0, lt=200)
    user_name: str | None = Field(None, max_length=40)
    device_id: str | None = Field(None, max_length=32)
    setup: Setup | None = None


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
    meter_type: MeterType


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
