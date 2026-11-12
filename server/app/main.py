"""Solaris backend: FastAPI app implementing Contract C (docs/contracts/C-api.md).

Run from server/:   uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
Mock mode:          SOLARIS_MOCK=1 uvicorn app.main:app --host 0.0.0.0 --port 8000
"""
import asyncio
import contextlib
import logging
import mimetypes
from typing import Literal

from fastapi import FastAPI, HTTPException, Query, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import RedirectResponse
from fastapi.staticfiles import StaticFiles

from ai import llm, prompts
from ai import service as ai

from . import config, db, energy, household, hub, ingest, meralco, meter, mock, outlook, projection, solar_plan, tips, upgrade, weather
from . import schemas as S  # Contract C response shapes

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("solaris")


async def _watchdog() -> None:
    """Check device freshness independently of slow weather and AI requests."""
    while True:
        await asyncio.sleep(5)
        try:
            ingest.check_stale()
        except Exception:
            log.exception("device watchdog")


async def _rates() -> None:
    while True:
        try:
            result = await asyncio.to_thread(meralco.refresh)
            if result["status"] == "published":
                settings = _settings()
                hub.publish_threadsafe("telemetry", energy.live(settings["device_id"], settings))
        except Exception:
            log.exception("Meralco rate refresh")
        await asyncio.sleep(meralco.REFRESH_S)


async def _background() -> None:
    """Keep yesterday's AI summary pre-generated and weather forecast fresh."""
    n = 0
    while True:
        await asyncio.sleep(5)
        try:
            if n % 360 == 0 and config.WEATHER_ENABLED:  # every 30 min, first one at startup
                await asyncio.to_thread(weather.refresh)
            if n % 120 == 0:  # every 10 min
                s = db.get_settings()
                await ai.daily_summary(s["device_id"], s, upgrade=True)
        except Exception:
            log.exception("background task")
        n += 1


@contextlib.asynccontextmanager
async def lifespan(app: FastAPI):
    hub.bind_loop(asyncio.get_running_loop())
    tasks = []
    if config.MOCK:
        log.info("MOCK MODE: serving %s", config.EXAMPLES_DIR)
        tasks.append(asyncio.create_task(mock.ws_loop()))
    else:
        db.conn()
        ingest.start()
        tasks.append(asyncio.create_task(_watchdog()))
        if config.MERALCO_RATE_ENABLED:
            tasks.append(asyncio.create_task(_rates()))
        tasks.append(asyncio.create_task(_background()))
        tasks.append(asyncio.create_task(llm.warmup(prompts.SYSTEM)))
    yield
    for t in tasks:
        t.cancel()
    ingest.stop()


app = FastAPI(title="Solaris API", version="0.1.0", lifespan=lifespan,
              description="Contract C: backend → Flutter app. See docs/contracts/C-api.md")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])


def _settings() -> dict:
    return db.get_settings()


def _settings_response() -> dict:
    settings = _settings()
    publication = db.get_kv(meralco.CACHE_KEY) or {}
    metadata = meralco.info(publication)
    if metadata["status"] in {"published", "cached"}:
        # Keep the displayed amount and provenance from the same snapshot even
        # if a background fetch completed between the two database reads.
        settings = settings | {"rate_php_per_kwh": publication["rate_php_per_kwh"]}
    return settings | {"meralco_rate": metadata}


def _dev() -> str:
    return _settings()["device_id"]


# ------------------------------------------------------------------- REST --
@app.get("/api/health", response_model=S.Health)
async def health():
    return {"ok": True, "mock": config.MOCK, "llm": config.LLM_MODEL if config.LLM_ENABLED else None,
            "llm_provider": config.LLM_PROVIDER, "llm_reachable": await llm.ping() if config.LLM_ENABLED else False}


@app.get("/api/live", response_model=S.Live)
def get_live():
    if config.MOCK:
        return mock.load("live")
    return energy.live(_dev(), _settings())


@app.get("/api/energy", response_model=S.Energy)
def get_energy(period: Literal["day", "week", "month"] = "day", back: int = Query(0, ge=0, le=366)):
    """`back`: periods before the current one (1 = yesterday / previous 7 days / last month)."""
    if config.MOCK:
        return mock.load(f"energy_{period}")
    return energy.energy(_dev(), period, back)


@app.get("/api/bill", response_model=S.Bill)
def get_bill():
    if config.MOCK:
        return mock.load("bill")
    return energy.bill(_dev(), _settings())


@app.get("/api/brownout", response_model=S.Brownout)
def get_brownout():
    if config.MOCK:
        return mock.load("brownout")
    return energy.brownout(_dev(), _settings())


@app.get("/api/outlook", response_model=S.Outlook)
def get_outlook():
    if config.MOCK:
        return mock.load("outlook")
    return outlook.outlook(_dev(), _settings())


@app.get("/api/bill/projection", response_model=S.Projection)
def get_bill_projection():
    """This month's forecast + up to 3 projected months (app/projection.py). Later months are rougher."""
    if config.MOCK:
        return mock.load("bill_projection")
    return projection.project(_dev(), _settings())


@app.get("/api/upgrade", response_model=S.Upgrade)
def get_upgrade():
    """System check: does the solar setup still fit this household's use? (app/upgrade.py)"""
    if config.MOCK:
        return mock.load("upgrade")
    return upgrade.recommend(_dev(), _settings())


@app.get("/api/tips", response_model=S.Tips)
def get_tips():
    """Solar tips: when and how to run the house on the sun, from live, forecast and 30-day data (app/tips.py)."""
    if config.MOCK:
        return mock.load("tips")
    return tips.tips(_dev(), _settings())


@app.get("/api/solar-plan", response_model=S.SolarPlan)
def get_solar_plan():
    """For a home without solar: how big a setup its use needs (grid-tie / hybrid), savings, payback; plus
    sponsored slots kept apart from the recommendation (app/solar_plan.py)."""
    if config.MOCK:
        return mock.load("solar_plan")
    return solar_plan.plan(_dev(), _settings())


@app.get("/api/household", response_model=S.Household)
def get_household():
    """Household profile: routine and whether someone is likely home now, from home use alone; plus any new
    appliance-sized load in the last few days (app/household.py). All local: occupancy never leaves the laptop."""
    if config.MOCK:
        return mock.load("household")
    return household.household(_dev(), _settings())


@app.get("/api/meter", response_model=S.MeterInfo)
def get_meter():
    """Smart meter mode: latest reading, voltage and power factor, usage pattern, Meralco level (app/meter.py)."""
    if config.MOCK:
        return mock.load("meter")
    return meter.info(_dev(), _settings())


@app.get("/api/alerts", response_model=S.AlertList)
def get_alerts(unread_only: bool = False):
    if config.MOCK:
        return mock.load("alerts")
    return {"unread": db.unread_count(), "alerts": db.list_alerts(unread_only)}


@app.post("/api/alerts/{alert_id}/read", response_model=S.Alert)
def read_alert(alert_id: int):
    if config.MOCK:
        a = next((a for a in mock.load("alerts")["alerts"] if a["id"] == alert_id), None)
        if a is None:
            raise HTTPException(404, "alert not found")
        return a | {"read": True}
    db.execute("UPDATE alerts SET read=1 WHERE id=?", (alert_id,))
    a = db.alert_by_id(alert_id)
    if a is None:
        raise HTTPException(404, "alert not found")
    return a


@app.post("/api/alerts/read-all", response_model=S.ReadAll)
def read_all_alerts():
    if not config.MOCK:
        db.execute("UPDATE alerts SET read=1 WHERE read=0")
    return {"unread": 0}


@app.post("/api/chat", response_model=S.Chat)
async def post_chat(body: S.ChatIn):
    if config.MOCK:
        return mock.load("chat")
    return await ai.chat(_dev(), _settings(), body.message)


@app.get("/api/summary/daily", response_model=S.DailySummary)
async def get_summary(refresh: bool = False):
    if config.MOCK:
        return mock.load("summary_daily")
    return await ai.daily_summary(_dev(), _settings(), force=refresh)


@app.get("/api/settings", response_model=S.Settings)
def get_settings():
    if config.MOCK:
        return mock.load("settings")
    return _settings_response()


@app.put("/api/settings", response_model=S.Settings)
def put_settings(body: S.SettingsIn):
    if config.MOCK:
        return mock.save_settings(body.model_dump(exclude_none=True))
    db.put_settings(body.model_dump(exclude_none=True))
    return _settings_response()


@app.post("/api/settings/rate/refresh", response_model=S.Settings)
async def refresh_rate():
    if config.MOCK:
        return mock.load("settings")
    await asyncio.to_thread(meralco.refresh, True)
    settings = _settings_response()
    hub.publish_threadsafe("telemetry", energy.live(settings["device_id"], settings))
    return settings


# -------------------------------------------------------------- WebSocket --
@app.websocket("/ws/live")
async def ws_live(ws: WebSocket):
    await hub.connect(ws)
    try:
        first = mock.load("live") if config.MOCK else energy.live(_dev(), _settings())
        await ws.send_json({"type": "telemetry", "data": first})
        while True:
            await ws.receive_text()  # ignore client messages; keeps the socket open
    except WebSocketDisconnect:
        pass
    finally:
        hub.disconnect(ws)


# ---------------------------------------------------- landing page + APK --
# Mounted last so every /api and /ws route above wins. http://<laptop-ip>:8000/ is the landing page,
# /apk is a short link to type on a phone for the Android app (landing/downloads/solaris.apk).
mimetypes.add_type("application/vnd.android.package-archive", ".apk")


@app.get("/apk", include_in_schema=False)
def apk():
    return RedirectResponse("/downloads/solaris.apk")


if config.LANDING_DIR.is_dir():
    app.mount("/", StaticFiles(directory=config.LANDING_DIR, html=True), name="landing")
