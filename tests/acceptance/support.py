"""Shared settings and helpers for the acceptance tests (see conftest.py for the fixtures)."""
import os
import time

import pytest

API = os.getenv("SOLARIS_API", "http://localhost:8000").rstrip("/")
MQTT_HOST = os.getenv("MQTT_HOST", "localhost")
MQTT_PORT = int(os.getenv("MQTT_PORT", "1883"))
DEVICE_ID = os.getenv("SOLARIS_DEVICE_ID", "solaris-001")
SOURCE = os.getenv("SOLARIS_SOURCE", "fake")
HUMAN_WAIT_S = float(os.getenv("SOLARIS_WAIT_S", "60"))


def wait_for(fn, timeout: float, every: float = 0.5, what: str = "condition"):
    """Polls fn() until it returns something truthy; fails with `what` after `timeout` s."""
    end = time.monotonic() + timeout
    last = None
    while time.monotonic() < end:
        try:
            last = fn()
            if last:
                return last
        except Exception as e:  # server restarting etc.
            last = e
        time.sleep(every)
    pytest.fail(f"timed out after {timeout:.0f}s waiting for {what} (last: {last!r})")
