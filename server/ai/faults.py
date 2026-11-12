"""Fault-code table: inverter code -> plain Taglish. Keep in sync with docs/contracts/A-inverter-register-map.md."""

FAULTS: dict[int, dict] = {
    21: {
        "title": "Sobrang init ng inverter",
        "message": "Nag-overheat ang inverter. Bawasan muna ang load, at siguraduhing may hangin "
                   "at hindi naaarawan ang inverter. Kung hindi bumaba ang init, tumawag sa installer.",
    },
}


def explain_fault(code: int) -> dict:
    return FAULTS.get(code, {
        "title": "Hindi kilalang fault",
        "message": f"May fault code {code} ang inverter. Tingnan ang manual o tumawag sa installer.",
    })
