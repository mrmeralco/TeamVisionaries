"""LLM client. Returns the model's JSON reply as a dict.

LLM_PROVIDER=ollama (default): local Ollama native API, Qwen 3.5.
  - think=false: Qwen 3.5 is a thinking model; thinking makes replies 3-10x slower and isn't needed here.
  - format=<JSON schema>: Ollama constrains decoding so the reply is always valid JSON in our shape.
  - temperature 0 + fixed seed: same facts + same question = same answer (repeatable demo, testable).
  - keep_alive: keeps the model in RAM between questions so only the first call is slow.
LLM_PROVIDER=openai: any OpenAI-compatible API (cloud fallback). Same prompts and schema.
"""
import json
import logging
import time

import httpx

from app import config

log = logging.getLogger("solaris.llm")


class LLMUnavailable(Exception):
    pass


async def complete_json(system: str, messages: list[dict], schema: dict, max_tokens: int = 220) -> dict:
    if not config.LLM_ENABLED:
        raise LLMUnavailable("LLM_ENABLED=0")
    msgs = [{"role": "system", "content": system}, *messages]
    t0 = time.monotonic()
    try:
        async with httpx.AsyncClient(timeout=config.LLM_TIMEOUT_S) as client:
            if config.LLM_PROVIDER == "ollama":
                r = await client.post(f"{config.OLLAMA_URL}/api/chat", json={
                    "model": config.LLM_MODEL, "messages": msgs, "stream": False, "think": False,
                    "format": schema, "keep_alive": config.LLM_KEEP_ALIVE,
                    "options": {"temperature": 0, "seed": 7, "num_predict": max_tokens, "num_ctx": 4096},
                })
                r.raise_for_status()
                text = r.json()["message"]["content"]
            else:
                r = await client.post(f"{config.LLM_BASE_URL.rstrip('/')}/chat/completions",
                                      headers={"Authorization": f"Bearer {config.LLM_API_KEY}"}, json={
                    "model": config.LLM_MODEL, "messages": msgs, "temperature": 0, "max_tokens": max_tokens,
                    "response_format": {"type": "json_schema", "json_schema": {"name": "solaris_reply", "schema": schema, "strict": True}},
                })
                r.raise_for_status()
                text = r.json()["choices"][0]["message"]["content"]
    except (httpx.HTTPError, KeyError, IndexError) as e:
        raise LLMUnavailable(f"{type(e).__name__}: {e}") from e
    log.info("LLM %s answered in %.1fs", config.LLM_MODEL, time.monotonic() - t0)
    try:
        out = json.loads(text)
    except (json.JSONDecodeError, TypeError) as e:
        raise LLMUnavailable(f"reply was not JSON: {text[:200]!r}") from e
    if not isinstance(out, dict):
        raise LLMUnavailable("reply JSON is not an object")
    return out


async def ping() -> bool:
    """True if the endpoint is up AND the model is available (catches 'Ollama running, model not pulled')."""
    try:
        async with httpx.AsyncClient(timeout=2) as client:
            if config.LLM_PROVIDER == "ollama":
                r = await client.get(f"{config.OLLAMA_URL}/api/tags")
                names = {m.get("name", "") for m in (r.json().get("models") or [])}
            else:
                r = await client.get(f"{config.LLM_BASE_URL.rstrip('/')}/models",
                                     headers={"Authorization": f"Bearer {config.LLM_API_KEY}"})
                names = {m.get("id", "") for m in (r.json().get("data") or [])}
            return r.status_code == 200 and (config.LLM_MODEL in names or f"{config.LLM_MODEL}:latest" in names)
    except (httpx.HTTPError, ValueError):
        return False


async def warmup(system: str = "") -> None:
    """Load the model into memory at startup so the first real question isn't the slow one.
    Passing the system prompt also fills Ollama's prompt cache with it: every chat starts with the same
    system prompt (examples included), so only the facts and question are processed per request."""
    if not config.LLM_ENABLED or config.LLM_PROVIDER != "ollama":
        return
    try:
        async with httpx.AsyncClient(timeout=120) as client:
            await client.post(f"{config.OLLAMA_URL}/api/chat", json={
                "model": config.LLM_MODEL, "stream": False, "think": False, "keep_alive": config.LLM_KEEP_ALIVE,
                "messages": [{"role": "system", "content": system}, {"role": "user", "content": "FACTS:"}],
                "options": {"temperature": 0, "seed": 7, "num_predict": 1, "num_ctx": 4096}})
        log.info("LLM %s loaded", config.LLM_MODEL)
    except httpx.HTTPError as e:
        log.warning("LLM warmup failed: %s", e)
