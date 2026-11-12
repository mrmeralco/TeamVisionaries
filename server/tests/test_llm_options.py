"""Warmup and chat must use the same GPU allocation to avoid model reloads."""
import asyncio
import json

import httpx
import pytest

from ai import llm
from app import config


@pytest.mark.parametrize("layers", [-1, 0, 30])
def test_gpu_allocation_is_shared_by_warmup_and_chat(monkeypatch, layers):
    requests = []

    def respond(request):
        requests.append(json.loads(request.content))
        return httpx.Response(200, json={"message": {"content": '{"answerable": true}'}})

    client = httpx.AsyncClient
    monkeypatch.setattr(llm.httpx, "AsyncClient", lambda **kwargs: client(
        transport=httpx.MockTransport(respond), **kwargs))
    monkeypatch.setattr(config, "LLM_GPU_LAYERS", layers)
    monkeypatch.setattr(config, "LLM_ENABLED", True)
    monkeypatch.setattr(config, "LLM_PROVIDER", "ollama")

    async def run():
        await llm.warmup("system")
        assert await llm.complete_json("system", [], {}) == {"answerable": True}

    asyncio.run(run())
    warmup, chat = [request["options"] for request in requests]
    assert warmup["num_predict"] == 1 and chat["num_predict"] == 220
    assert {k: v for k, v in warmup.items() if k != "num_predict"} == {
        k: v for k, v in chat.items() if k != "num_predict"}
    for options in (warmup, chat):
        if layers < 0:
            assert "num_gpu" not in options
        else:
            assert options["num_gpu"] == layers
