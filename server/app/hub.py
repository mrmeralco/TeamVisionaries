"""Fan-out of live messages to every connected /ws/live client.

The MQTT thread calls publish_threadsafe(); FastAPI's event loop does the sending.
"""
import asyncio
import json

from fastapi import WebSocket

_clients: set[WebSocket] = set()
_loop: asyncio.AbstractEventLoop | None = None


def bind_loop(loop: asyncio.AbstractEventLoop) -> None:
    global _loop
    _loop = loop


async def connect(ws: WebSocket) -> None:
    await ws.accept()
    _clients.add(ws)


def disconnect(ws: WebSocket) -> None:
    _clients.discard(ws)


async def broadcast(type_: str, data) -> None:
    msg = json.dumps({"type": type_, "data": data}, ensure_ascii=False)
    for ws in list(_clients):
        try:
            await ws.send_text(msg)
        except Exception:
            _clients.discard(ws)


def publish_threadsafe(type_: str, data) -> None:
    if _loop is not None and _loop.is_running():
        asyncio.run_coroutine_threadsafe(broadcast(type_, data), _loop)
