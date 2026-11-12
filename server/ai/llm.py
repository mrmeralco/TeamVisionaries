"""Tiny client for any OpenAI-compatible /chat/completions endpoint.

Default is local Ollama (http://localhost:11434/v1). For the cloud fallback, change LLM_BASE_URL,
LLM_MODEL and LLM_API_KEY in server/.env: the prompts stay the same.
"""
import logging
import time

import httpx

from app import config

log = logging.getLogger("sinag.llm")


class LLMUnavailable(Exception):
    pass


async def complete(system: str, user: str, max_tokens: int = 200, temperature: float = 0.3) -> str:
    if not config.LLM_ENABLED:
        raise LLMUnavailable("LLM_ENABLED=0")
    t0 = time.monotonic()
    try:
        async with httpx.AsyncClient(timeout=config.LLM_TIMEOUT_S) as client:
            r = await client.post(
                f"{config.LLM_BASE_URL.rstrip('/')}/chat/completions",
                headers={"Authorization": f"Bearer {config.LLM_API_KEY}"},
                json={
                    "model": config.LLM_MODEL,
                    "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
                    "max_tokens": max_tokens,
                    "temperature": temperature,
                    "stream": False,
                },
            )
            r.raise_for_status()
            text = r.json()["choices"][0]["message"]["content"].strip()
    except (httpx.HTTPError, KeyError, IndexError, ValueError) as e:
        raise LLMUnavailable(str(e)) from e
    log.info("LLM %s answered in %.1fs", config.LLM_MODEL, time.monotonic() - t0)
    if not text:
        raise LLMUnavailable("empty reply")
    return text


async def ping() -> bool:
    """True if the endpoint is up AND has LLM_MODEL (catches 'Ollama running, model not pulled')."""
    try:
        async with httpx.AsyncClient(timeout=2) as client:
            r = await client.get(f"{config.LLM_BASE_URL.rstrip('/')}/models",
                                 headers={"Authorization": f"Bearer {config.LLM_API_KEY}"})
            if r.status_code != 200:
                return False
            ids = {m.get("id", "") for m in (r.json().get("data") or [])}
            return config.LLM_MODEL in ids or f"{config.LLM_MODEL}:latest" in ids
    except (httpx.HTTPError, ValueError):
        return False
