"""HARDWARE (Adrian + Stephen): read the inverter simulator directly over a USB-RS485 dongle.

    SINAG_SERIAL=/dev/cu.usbserial-XXXX pytest tests/acceptance -m hardware -s

Same job as Modbus Poll / QModMaster in the plan, but it also checks Contract A and the simulator logic.
Wire: dongle A -> sim A, B -> B, GND -> GND. Simulator in INVERTER mode. Nothing else polling the bus.
"""
import os
import time

import pytest

pytestmark = pytest.mark.hardware
PORT = os.getenv("SINAG_SERIAL")
if not PORT:
    pytest.skip("set SINAG_SERIAL=/dev/cu.usbserial-... to run hardware tests", allow_module_level=True)

pymodbus = pytest.importorskip("pymodbus", reason="pip install pymodbus pyserial")
from pymodbus.client import ModbusSerialClient  # noqa: E402

FIELDS = ["pv_w", "load_w", "grid_w", "batt_soc", "batt_w", "grid_on", "inv_temp_c", "fault_code"]
SIGNED = {"grid_w", "batt_w", "inv_temp_c"}


@pytest.fixture(scope="module")
def bus():
    c = ModbusSerialClient(port=PORT, baudrate=9600, bytesize=8, parity="N", stopbits=1, timeout=1)
    assert c.connect(), f"cannot open {PORT}"
    yield c
    c.close()


def read(bus, slave=1) -> dict:
    try:
        r = bus.read_holding_registers(0, count=8, device_id=slave)
    except TypeError:  # pymodbus < 3.9
        r = bus.read_holding_registers(0, count=8, slave=slave)
    assert not r.isError(), f"Modbus error: {r} (check A/B, GND, simulator in INVERTER mode, 9600 8N1, slave {slave})"
    out = {}
    for name, raw in zip(FIELDS, r.registers):
        out[name] = raw - 65536 if name in SIGNED and raw >= 32768 else raw
    return out


def ask(request, msg):
    with request.config.pluginmanager.getplugin("capturemanager").global_and_fixture_disabled():
        print(f"\n\n  >>> OPERATOR: {msg}\n", flush=True)


def test_registers_0_to_7_follow_contract_a(bus):
    r = read(bus)
    assert 0 <= r["pv_w"] <= 6000 and 0 <= r["load_w"] <= 6000
    assert 0 <= r["batt_soc"] <= 100
    assert r["grid_on"] in (0, 1)
    assert -20 <= r["inv_temp_c"] <= 120
    assert r["fault_code"] in (0, 21)


def test_energy_balance(bus):
    r = read(bus)
    if r["grid_on"]:
        assert abs(r["pv_w"] + r["grid_w"] + r["batt_w"] - r["load_w"]) <= 50, r


def test_answers_fast_and_reliably(bus):
    t0 = time.monotonic()
    for _ in range(20):
        read(bus)
    assert (time.monotonic() - t0) / 20 < 0.3, "slow replies: check baud and cable"


def test_wrong_slave_id_gets_no_answer(bus):
    try:
        r = bus.read_holding_registers(0, count=8, device_id=9)
    except TypeError:
        r = bus.read_holding_registers(0, count=8, slave=9)
    assert r.isError()


def wait_change(bus, check, timeout=60):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        r = read(bus)
        if check(r):
            return r
        time.sleep(0.5)
    pytest.fail("the simulator didn't change as expected")


def test_sun_knob_moves_pv(bus, request):
    start = read(bus)["pv_w"]
    ask(request, f"Select SUN (tap the button), then turn the knob a lot. pv_w is {start} W now.")
    wait_change(bus, lambda r: abs(r["pv_w"] - start) > 500)


def test_brownout_button(bus, request):
    ask(request, "Hold the button 1-3 s and release: BROWNOUT ON.")
    r = wait_change(bus, lambda r: r["grid_on"] == 0)
    assert r["grid_w"] == 0
    ask(request, "Hold 1-3 s again: BROWNOUT OFF.")
    wait_change(bus, lambda r: r["grid_on"] == 1)


def test_fault_button(bus, request):
    ask(request, "Hold the button 3-6 s and release: FAULT 21 ON. (Temperature should climb.)")
    r = wait_change(bus, lambda r: r["fault_code"] == 21)
    t0 = r["inv_temp_c"]
    time.sleep(5)
    assert read(bus)["inv_temp_c"] >= t0, "temperature should rise during fault 21"
    ask(request, "Hold 3-6 s again: FAULT OFF.")
    wait_change(bus, lambda r: r["fault_code"] == 0)
