"""SPEC (Andy): alert engine rules from the plan (workstream 2).

  fault_code != 0          -> one "fault" alert (critical) when it starts
  grid_on false            -> "brownout" alert + outage opened; back on -> "grid_restored" + outage closed
  batt_soc < 20 %          -> one "low_battery" alert (re-arms above 25 %)
  inv_temp_c > 60 °C       -> one "high_temp" alert (re-arms below 55 °C)
An alert fires on the CHANGE, never on every 5-second reading.
"""
from app import alerts, db


def reading(ts, **kw):
    base = {"ts": ts, "pv_w": 2000, "load_w": 1000, "grid_w": 0, "batt_soc": 70, "batt_w": -1000,
            "grid_on": True, "inv_temp_c": 40, "fault_code": 0}
    return base | kw


def feed(device, *readings):
    out = []
    for r in readings:
        out += [a["type"] for a in alerts.evaluate(device, r)]
    return out


def test_normal_readings_raise_nothing(device):
    assert feed(device, *(reading(100 + i * 5) for i in range(10))) == []


def test_fault_alerts_once_when_it_starts(device):
    types = feed(device, reading(100), reading(105, fault_code=21), reading(110, fault_code=21), reading(115, fault_code=21))
    assert types == ["fault"]


def test_fault_alert_explains_the_code_in_taglish(device):
    feed(device, reading(100))
    a = alerts.evaluate(device, reading(105, fault_code=21))[0]
    assert a["severity"] == "critical" and "21" in a["title"] and len(a["message"]) > 20


def test_brownout_opens_and_closes_an_outage(device):
    assert feed(device, reading(100), reading(105, grid_on=False), reading(110, grid_on=False)) == ["brownout"]
    assert db.open_outage(device)["start_ts"] == 105
    assert feed(device, reading(1905)) == ["grid_restored"]
    o = db.last_outage(device)
    assert (o["start_ts"], o["end_ts"]) == (105, 1905)
    assert db.open_outage(device) is None


def test_grid_restored_says_how_long_it_lasted(device):
    feed(device, reading(100), reading(105, grid_on=False))
    a = alerts.evaluate(device, reading(105 + 30 * 60))[0]
    assert "30 minuto" in a["message"]


def test_low_battery_has_hysteresis(device):
    socs = [30, 19, 18, 21, 19, 26, 19]  # dips, wobbles around 20, recovers past 25, dips again
    types = feed(device, *(reading(100 + i * 5, batt_soc=s) for i, s in enumerate(socs)))
    assert types == ["low_battery", "low_battery"]


def test_high_temp_has_hysteresis(device):
    temps = [40, 61, 62, 58, 61, 54, 61]
    types = feed(device, *(reading(100 + i * 5, inv_temp_c=t) for i, t in enumerate(temps)))
    assert types == ["high_temp", "high_temp"]


def test_server_restart_does_not_repeat_alerts(device):
    feed(device, reading(100), reading(105, fault_code=21, batt_soc=10))
    alerts._state.pop(device)  # simulate a restart: in-memory state is gone
    assert feed(device, reading(110, fault_code=21, batt_soc=10)) == []


def test_brownout_during_restart_is_still_logged(device):
    feed(device, reading(100))
    alerts._state.pop(device)
    assert feed(device, reading(500, grid_on=False)) == ["brownout"]
    assert db.open_outage(device) is not None


def test_alerts_are_stored_unread(device):
    feed(device, reading(100), reading(105, fault_code=21))
    stored = [a for a in db.list_alerts() if a["type"] == "fault"]
    assert stored and stored[0]["read"] is False
