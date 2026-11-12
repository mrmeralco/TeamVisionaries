"""Solaris backend: FastAPI app implementing Contract C (docs/contracts/C-api.md).

Run from server/:   uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
Mock mode:          SOLARIS_MOCK=1 uvicorn app.main:app --host 0.0.0.0 --port 8000
"""
import asyncio
import contextlib
import logging
from typing import Literal

from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware

from ai import llm
from ai import service as ai

from . import config, db, energy, hub, ingest, mock, outlook, weather
from . import schemas as S  # Contract C response shapes

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("solaris")


async def _background() -> None:
    """Offline watchdog + keep yesterday's AI summary pre-generated + weather forecast fresh."""
    n = 0
    while True:
        await asyncio.sleep(5)
        try:
            if n % 360 == 0 and config.WEATHER_ENABLED:  # every 30 min, first one at startup
                await asyncio.to_thread(weather.refresh)
            ingest.check_stale()
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
        tasks.append(asyncio.create_task(_background()))
        tasks.append(asyncio.create_task(llm.warmup()))
    yield
    for t in tasks:
        t.cancel()
    ingest.stop()


app = FastAPI(title="Solaris API", version="0.1.0", lifespan=lifespan,
              description="Contract C: backend → Flutter app. See docs/contracts/C-api.md")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])


def _settings() -> dict:
    return db.get_settings()


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
def get_energy(period: Literal["day", "week", "month"] = "day"):
    if config.MOCK:
        return mock.load(f"energy_{period}")
    return energy.energy(_dev(), period)


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
    return _settings()


@app.put("/api/settings", response_model=S.Settings)
def put_settings(body: S.SettingsIn):
    if config.MOCK:
        return mock.load("settings") | body.model_dump(exclude_none=True)
    return db.put_settings(body.model_dump(exclude_none=True))


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
