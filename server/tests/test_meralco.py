"""Official rate extraction, protected updates, persistence and offline fallback."""
from datetime import date
import sqlite3

import httpx
import pytest
from fastapi.testclient import TestClient

from app import config, db, energy, meralco, sarima
from app.main import app


def card(value="15.0615", month="October", year="2026", label=None):
    return f'''<div class="statistics-grid__item">
        <dt>{label or month + ' Residential Rate'}</dt>
        <dd><data class="statistics-grid__number" value="{value}">{value}</data>
        <p>Overall rate for a typical household this {month} {year}</p></dd></div>'''


@pytest.fixture
def isolated_rates(tmp_path, monkeypatch):
    connection = sqlite3.connect(tmp_path / "rates.db", check_same_thread=False, isolation_level=None)
    connection.row_factory = sqlite3.Row
    connection.executescript(db.SCHEMA)
    monkeypatch.setattr(db, "_conn", connection)
    monkeypatch.setattr(config, "MERALCO_RATE_ENABLED", True)
    monkeypatch.setattr(meralco, "MIN_CHECK_S", 0)
    monkeypatch.setattr(energy, "_day_cache", {})
    monkeypatch.setattr(sarima, "_cache", {})
    monkeypatch.setattr(meralco, "download", lambda: card())
    yield
    connection.close()


def test_parses_the_overall_card_not_generation_or_change_amounts():
    html = card("0.4973", label="Generation Charge Increase") + card()
    assert meralco.parse(html, date(2026, 11, 12)) == {
        "rate_php_per_kwh": 15.0615, "billing_month": "2026-10"}


@pytest.mark.parametrize("html", [
    "<html>no rate card</html>", card("nan"), card("0.0000"), card("99,999"),
    card("15.06"), card(year="2027"), card(label="September Residential Rate"),
    card(label="Generation Charge"), card() + card(),
])
def test_rejects_missing_ambiguous_invalid_or_future_rates(html):
    with pytest.raises(ValueError):
        meralco.parse(html, date(2026, 11, 12))


def test_refresh_updates_calculation_rate_and_provenance_atomically(isolated_rates):
    result = meralco.refresh(force=True)
    assert result["status"] == "published"
    assert result["billing_month"] == "2026-10"
    assert result["source_url"] == meralco.SOURCE_URL
    assert result["reference_kwh"] == 200
    assert result["fetched_at"] == result["checked_at"]
    assert db.get_settings()["rate_php_per_kwh"] == 15.0615
    assert db.get_kv(meralco.CACHE_KEY)["rate_php_per_kwh"] == 15.0615


@pytest.mark.parametrize("failure", ["network", "invalid", "older"])
def test_failed_refresh_keeps_the_verified_rate(isolated_rates, monkeypatch, failure):
    meralco.refresh(force=True)
    before = db.get_kv(meralco.CACHE_KEY)
    if failure == "network":
        def fail():
            raise httpx.ConnectError("offline")
        monkeypatch.setattr(meralco, "download", fail)
    else:
        monkeypatch.setattr(meralco, "download", lambda: "bad page" if failure == "invalid" else card(month="September"))
    result = meralco.refresh(force=True)
    assert result["status"] == "cached"
    assert result["fetched_at"] == before["fetched_at"]
    assert result["billing_month"] == "2026-10"
    assert db.get_settings()["rate_php_per_kwh"] == 15.0615


def test_startup_refresh_reuses_recent_verified_cache(isolated_rates, monkeypatch):
    meralco.refresh(force=True)
    def unexpected():
        pytest.fail("A recent persisted rate must survive a backend restart without another download")
    monkeypatch.setattr(meralco, "download", unexpected)
    assert meralco.refresh()["status"] == "published"


def test_refresh_button_is_throttled_to_protect_the_public_source(isolated_rates, monkeypatch):
    meralco.refresh(force=True)
    monkeypatch.setattr(meralco, "MIN_CHECK_S", 60)
    def unexpected():
        pytest.fail("Repeated refresh clicks must not hammer Meralco")
    monkeypatch.setattr(meralco, "download", unexpected)
    assert meralco.refresh(force=True)["status"] == "published"


def test_no_successful_fetch_is_never_labelled_verified(isolated_rates, monkeypatch):
    monkeypatch.setattr(meralco, "download", lambda: "unrecognized page")
    result = meralco.refresh(force=True)
    assert result["status"] == "unavailable"
    assert result["billing_month"] is None and result["fetched_at"] is None


def test_api_refresh_updates_settings_and_bill_but_rate_is_read_only(isolated_rates, monkeypatch):
    # Disable the automatic worker so the test exercises the explicit endpoint only.
    monkeypatch.setattr(config, "MERALCO_RATE_ENABLED", False)
    with TestClient(app) as client:
        monkeypatch.setattr(config, "MERALCO_RATE_ENABLED", True)
        response = client.post("/api/settings/rate/refresh")
        assert response.status_code == 200
        assert response.json()["meralco_rate"]["status"] == "published"
        assert response.json()["rate_php_per_kwh"] == 15.0615
        assert client.get("/api/bill").json()["rate_php_per_kwh"] == 15.0615
        assert client.put("/api/settings", json={"rate_php_per_kwh": 1}).status_code == 422
        assert client.get("/api/settings").json()["rate_php_per_kwh"] == 15.0615


def test_settings_amount_matches_its_publication_during_background_update(isolated_rates, monkeypatch):
    meralco.refresh(force=True)
    stale_settings = db.get_settings() | {"rate_php_per_kwh": 1}
    monkeypatch.setattr(db, "get_settings", lambda: stale_settings)
    with TestClient(app) as client:
        response = client.get("/api/settings").json()
    assert response["rate_php_per_kwh"] == 15.0615
    assert response["meralco_rate"]["billing_month"] == "2026-10"


@pytest.mark.parametrize("status,headers,error", [
    (302, {"location": "http://127.0.0.1/"}, httpx.HTTPStatusError),
    (200, {"content-type": "text/plain"}, ValueError),
])
def test_download_rejects_redirects_and_non_html(monkeypatch, status, headers, error):
    transport = httpx.MockTransport(lambda request: httpx.Response(status, headers=headers))
    with httpx.Client(transport=transport) as client:
        monkeypatch.setattr(meralco.httpx, "stream", client.stream)
        with pytest.raises(error):
            meralco.download()


def test_legacy_manual_rate_is_not_treated_as_a_verified_rate(isolated_rates):
    db.put_settings({"rate_php_per_kwh": 1})
    assert meralco.info()["status"] == "unavailable"
    assert db.get_settings()["rate_php_per_kwh"] == config.DEFAULT_SETTINGS["rate_php_per_kwh"]


def test_download_rejects_oversized_pages(monkeypatch):
    transport = httpx.MockTransport(lambda request: httpx.Response(200, headers={"content-type": "text/html"},
                                                                  content=b"x" * (meralco.MAX_BYTES + 1)))
    with httpx.Client(transport=transport) as client:
        monkeypatch.setattr(meralco.httpx, "stream", client.stream)
        with pytest.raises(ValueError, match="size limit"):
            meralco.download()
