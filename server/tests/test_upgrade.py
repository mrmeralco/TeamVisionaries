"""System check (/api/upgrade): each rule fires on the usage pattern it's meant for, and only then."""
import pytest

from app import config, db, upgrade
from solaris_contract import validate


def usage(**over):
    base = {"days": 30, "load_kwh_day": 15.0, "pv_kwh_day": 17.8, "grid_import_kwh_day": 0.6,
            "day_import_kwh_day": 0.3, "night_import_kwh_day": 0.3, "export_kwh_day": 2.0,
            "self_sufficiency_pct": 96, "battery_empty_days_pct": 0, "peak_load_w": 2500, "p95_load_w": 1500,
            "load_trend_pct": 2}
    return base | over


@pytest.fixture
def check(monkeypatch):
    """check(**usage) -> /api/upgrade response for a household with that usage."""
    def run(**over):
        monkeypatch.setattr(upgrade, "stats", lambda *a, **k: usage(**over))
        upgrade._cache.clear()
        s = {**db.get_settings(), "battery_kwh": 10.0, "rate_php_per_kwh": 15.0}
        out = upgrade.recommend(s["device_id"], s)
        validate("upgrade", out)
        return out
    monkeypatch.setattr(config, "PV_KWP", 5.0)
    monkeypatch.setattr(config, "INVERTER_KW", 5.0)
    yield run
    upgrade._cache.clear()


def ids(out):
    return [r["id"] for r in out["recommendations"]]


def test_system_that_fits_says_so(check):
    out = check()
    assert out["verdict"] == "ok" and ids(out) == [] and out["headline"].startswith("Sakto")


def test_surplus_by_day_and_grid_at_night_means_battery(check):
    out = check(export_kwh_day=4.9, night_import_kwh_day=3.5, battery_empty_days_pct=100, grid_import_kwh_day=3.8)
    assert ids(out) == ["battery"] and out["verdict"] == "consider"
    r = out["recommendations"][0]
    assert r["add"] == "+5 kWh"                                   # 3.5 kWh shiftable / 80 % usable -> 2 modules
    assert r["savings_php_month"] == round(3.5 * 15 * 30)        # the night grid use it replaces
    assert r["cost_php"] == round(5 * config.UPGRADE_BATTERY_PHP_PER_KWH)
    assert "4.9" in r["reason"] and "3.5" in r["reason"]          # the reason quotes the household's numbers


def test_battery_that_never_runs_out_needs_no_more(check):
    assert "battery" not in ids(check(export_kwh_day=4.9, night_import_kwh_day=3.5, battery_empty_days_pct=10))


def test_grid_while_sunny_means_more_panels(check):
    out = check(day_import_kwh_day=3.0, export_kwh_day=0.2, night_import_kwh_day=4.0, battery_empty_days_pct=80,
                grid_import_kwh_day=7.0, pv_kwh_day=12.0, self_sufficiency_pct=55)
    assert ids(out)[0] == "solar"
    r = out["recommendations"][0]
    # deficit 3.0 by day + 3.8 the battery can't cover = 6.8 kWh; this roof makes 12 / 5 = 2.4 kWh per kWp
    assert r["add"] == "+3 kWp"
    assert "battery" not in ids(out)                              # no surplus to store: panels first


def test_peaks_near_the_inverter_rating(check):
    out = check(p95_load_w=4400, peak_load_w=5600)
    assert ids(out) == ["inverter"]
    assert out["recommendations"][0]["add"] == "7 kW"            # 5.6 kW x 1.2 rounded up from 5 kW


def test_rising_use_is_a_note_after_hardware(check):
    out = check(load_trend_pct=22, export_kwh_day=4.9, night_import_kwh_day=3.5, battery_empty_days_pct=100)
    assert ids(out) == ["battery", "usage"]
    assert [r["priority"] for r in out["recommendations"]] == [1, 2]
    assert check(load_trend_pct=22)["verdict"] == "ok"            # a note alone isn't an upgrade


def test_too_little_history(monkeypatch):
    monkeypatch.setattr(upgrade, "stats", lambda *a, **k: None)
    upgrade._cache.clear()
    s = db.get_settings()
    out = upgrade.recommend(s["device_id"], s)
    validate("upgrade", out)
    assert out["verdict"] == "unknown" and not out["enough_data"] and out["usage"] is None
    upgrade._cache.clear()


def test_seeded_household_gets_a_battery_recommendation():
    """The demo history: sunny days export a lot, the battery runs out every night."""
    upgrade._cache.clear()
    s = db.get_settings()
    out = upgrade.recommend(s["device_id"], s)
    validate("upgrade", out)
    assert out["enough_data"] and out["usage"]["days"] >= 7
    assert "battery" in ids(out)
