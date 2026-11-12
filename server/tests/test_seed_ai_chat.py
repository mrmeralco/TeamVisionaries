"""Chatbot fixtures must be consistent, isolated and safe to regenerate in a new folder."""
from contextlib import closing
from datetime import datetime
import json
import sqlite3
import subprocess
import sys

import pytest

from ai import service
from app import config, db, energy, sarima
from tools import seed_ai_chat as seed


NOW = int(datetime(2026, 11, 12, 12, tzinfo=config.TZ).timestamp())


@pytest.mark.parametrize("scenario", seed.SCENARIOS)
def test_scenario_readings_and_backend_facts(tmp_path, monkeypatch, scenario):
    path = tmp_path / f"{scenario}.db"
    manifest = seed.create_fixture(path, scenario, NOW)
    with closing(sqlite3.connect(path, check_same_thread=False, isolation_level=None)) as conn:
        conn.row_factory = sqlite3.Row
        monkeypatch.setattr(db, "_conn", conn)
        monkeypatch.setattr(config, "OFFLINE_AFTER_S", 86400)
        monkeypatch.setattr(config, "FORECAST_METHOD", "average")
        monkeypatch.setattr(energy.time, "time", lambda: NOW)
        monkeypatch.setattr(energy, "today", lambda: datetime.fromtimestamp(NOW, config.TZ).date())
        monkeypatch.setattr(energy, "_day_cache", {})
        monkeypatch.setattr(sarima, "_cache", {})
        settings = db.get_settings()
        assert settings == seed.SETTINGS
        live = energy.live(seed.DEVICE, settings)
        assert live["device"]["online"] == manifest["expected"]["online"]
        bo = energy.brownout(seed.DEVICE, settings)
        assert bo["active"] == manifest["expected"]["brownout"]
        assert bo["runtime_h"] == manifest["expected"]["runtime_h"]
        if scenario == "empty":
            assert live["telemetry"] is None and manifest["history_rows"] == 0
            return
        assert live["telemetry"] == manifest["latest_telemetry"]
        assert manifest["history_rows"] >= 90 * 288
        assert conn.execute("SELECT COUNT(*) FROM telemetry WHERE ts>?", (NOW,)).fetchone()[0] == 0
        assert conn.execute("SELECT COUNT(*) FROM telemetry WHERE pv_w+grid_w+batt_w != load_w").fetchone()[0] == 0
        minimum, maximum = conn.execute("SELECT MIN(batt_soc),MAX(batt_soc) FROM telemetry").fetchone()
        assert 0 <= minimum <= maximum <= 100
        bill = energy.bill(seed.DEVICE, settings)
        assert bill["last_month_php"] > 0
        if scenario == "high-bill":
            assert bill["vs_last_month_pct"] > 0
        facts = service.gather(seed.DEVICE, settings).by_id()
        assert facts["now.battery_pct"].values[0] == seed.SCENARIOS[scenario]["batt_soc"]
        assert bool(facts["fault.active"].values) == bool(manifest["expected"]["fault_code"])
        assert json.loads(db.one("SELECT value FROM settings WHERE key='seed_ai_chat'")["value"])["fictional"]


def test_history_is_reproducible_for_the_same_date(tmp_path):
    for name in ("a", "b"):
        seed.create_fixture(tmp_path / f"{name}.db", "normal", NOW)
    with closing(sqlite3.connect(tmp_path / "a.db")) as a, closing(sqlite3.connect(tmp_path / "b.db")) as b:
        assert list(a.execute("SELECT * FROM telemetry")) == list(b.execute("SELECT * FROM telemetry"))


def test_existing_files_and_configured_database_are_untouched(tmp_path):
    original = config.DB_PATH
    path = tmp_path / "normal.db"
    path.write_bytes(b"existing data")
    with pytest.raises(FileExistsError):
        seed.create_fixture(path, "normal", NOW)
    assert path.read_bytes() == b"existing data"
    assert config.DB_PATH == original


def test_cli_checks_all_destinations_before_writing_any_fixture(tmp_path):
    existing = tmp_path / "fault.db"
    existing.write_bytes(b"keep this database")
    result = subprocess.run([sys.executable, str(seed.SERVER / "tools/seed_ai_chat.py"),
                             "--output-dir", str(tmp_path)], capture_output=True, text=True)
    assert result.returncode != 0 and "Already exists" in result.stderr
    assert not (tmp_path / "normal.db").exists()
    assert existing.read_bytes() == b"keep this database"
