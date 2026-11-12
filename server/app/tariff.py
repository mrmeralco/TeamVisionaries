"""Meralco residential pricing and seasonal usage, used by the bill forecast in energy.py.

SOURCE
  Meralco "Summary Schedule of Rates, effective October 2026 billing", residential rows, and the
  October 2026 rate press release: overall rate ₱15.0615/kWh for a typical 200 kWh household.
  (November 2026: a ₱0.1733/kWh residential refund starts, over six months. Meralco had not published
  the November schedule when this was written.)

HOW THE RATE SETTING FITS IN
  Every month Meralco announces one "overall rate" for a 200 kWh household. That number is fetched automatically from Meralco and cached as the
  read-only `rate_php_per_kwh` setting, so the bill for exactly 200 kWh equals setting x 200. Around it:
    - fixed charges: supply ₱16.38 + metering ₱5.00 per customer per month, plus 12% VAT;
    - consumption levels: Meralco charges the WHOLE month's kWh at the distribution rate of the level
      the total falls in (schedule rows "0 TO 200", "201 TO 300", "301 TO 400", "OVER 400 KWH").
      Levels above 200 kWh add the difference in distribution charge, plus VAT;
    - energy tax (BP 36), residential only, on kWh above 650.
  These tables only change after an ERC decision. The setting changes when a new monthly publication is verified.
  Not modelled: lifeline discounts (registered 4Ps households only), senior citizen discount,
  local franchise tax (varies per city, already inside the announced overall rate).

SEASON_INDEX
  Grid import in each month relative to the yearly average (mean of the 12 values = 1.0). It is a rough
  prior for a Metro Manila household: air-con use peaks in the hot dry season (April-May) and drops in
  the cool months (Dec-Feb). It is damped because the sunny months also give more solar. Replace it with
  values fitted to the household's own data once there is a year of history.
"""
import calendar
from datetime import date

VAT = 0.12
TYPICAL_KWH = 200  # the household Meralco's announced overall rate is for

# Distribution charge (₱/kWh, before VAT) by consumption level: (upper limit in kWh, rate). None = no limit.
DISTRIBUTION: list[tuple[float | None, float]] = [
    (200, 0.9803),
    (300, 1.2908),
    (400, 1.5837),
    (None, 2.0941),
]
FIXED_PHP_PER_MONTH = (16.38 + 5.00) * (1 + VAT)  # supply + metering charge per customer (SUPPLY_PHP, METERING_PHP)

# Energy tax on residential kWh above 650: (from kWh, to kWh, ₱/kWh), each slice at its own rate.
ENERGY_TAX: list[tuple[float, float | None, float]] = [(650, 1000, 0.10), (1000, 1500, 0.20), (1500, None, 0.35)]

#               Jan   Feb   Mar   Apr   May   Jun   Jul   Aug   Sep   Oct   Nov   Dec
SEASON_INDEX = (0.92, 0.93, 1.00, 1.12, 1.15, 1.06, 1.00, 0.98, 0.97, 0.96, 0.95, 0.96)


def bracket(kwh: float) -> tuple[float, float | None, float]:
    """(lower limit, upper limit, ₱/kWh added to the lowest level incl. VAT) for a month's total kWh."""
    lo = 0.0
    for hi, dist in DISTRIBUTION:
        if hi is None or kwh <= hi:
            return lo, hi, (dist - DISTRIBUTION[0][1]) * (1 + VAT)
        lo = hi
    raise AssertionError("DISTRIBUTION must end with an open level (None)")


def rate_at(kwh: float, overall_rate: float) -> float:
    """₱ per kWh (fixed charges and energy tax not included) for a month that totals `kwh`."""
    return overall_rate - FIXED_PHP_PER_MONTH / TYPICAL_KWH + bracket(kwh)[2]


def energy_tax(kwh: float) -> float:
    return sum((min(kwh, hi if hi is not None else kwh) - lo) * r for lo, hi, r in ENERGY_TAX if kwh > lo)


def cost(kwh: float, overall_rate: float) -> float:
    """₱ for a month with `kwh` of grid import. A 200 kWh month costs exactly overall_rate x 200."""
    kwh = max(0.0, kwh)
    return FIXED_PHP_PER_MONTH + kwh * rate_at(kwh, overall_rate) + energy_tax(kwh)


SCHEDULE = "Meralco Summary Schedule of Rates, October 2026 billing"
SUPPLY_PHP, METERING_PHP = 16.38, 5.00   # per customer per month, before VAT (in FIXED_PHP_PER_MONTH)


def charges(kwh: float, overall_rate: float) -> list[dict]:
    """cost() split into the bill's charges, for showing where the peso goes. They add up to cost(kwh).

    energy        everything else in Meralco's overall rate: generation, transmission, system loss,
                  subsidies, universal charges and taxes, per kWh (the overall rate less the 0-200 kWh
                  distribution charge and the fixed charges spread over 200 kWh)
    distribution  the distribution charge of the level the month's total falls in, on ALL its kWh, + VAT
    fixed         supply + metering charges, + VAT
    energy_tax    BP 36, kWh above 650 only (left out when 0)
    """
    kwh = max(0.0, kwh)
    lo, hi, _ = bracket(kwh)
    dist = next(r for h, r in DISTRIBUTION if h is None or kwh <= h)
    other = overall_rate - FIXED_PHP_PER_MONTH / TYPICAL_KWH - DISTRIBUTION[0][1] * (1 + VAT)
    out = [
        {"id": "energy", "kwh": round(kwh, 1), "php_per_kwh": round(other, 4), "php": kwh * other},
        {"id": "distribution", "kwh": round(kwh, 1), "php_per_kwh": round(dist * (1 + VAT), 4),
         "php": kwh * dist * (1 + VAT)},
        {"id": "fixed", "kwh": None, "php_per_kwh": None, "php": FIXED_PHP_PER_MONTH},
    ]
    tax = energy_tax(kwh)
    if tax > 0:
        out.append({"id": "energy_tax", "kwh": round(kwh - ENERGY_TAX[0][0], 1), "php_per_kwh": None, "php": tax})
    # Round so the parts add up to the rounded total exactly (the remainder goes to the biggest part).
    total = round(cost(kwh, overall_rate), 2)
    for c in out:
        c["php"] = round(c["php"], 2)
    out[0]["php"] = round(out[0]["php"] + total - sum(c["php"] for c in out), 2)
    return out


def level_steps(kwh: float, overall_rate: float) -> dict:
    """The consumption level a month of `kwh` lands in, and the step to the next level up and down.

    Crossing a level moves the WHOLE month to that level's distribution rate, so the bill jumps at the
    boundary: `jump_php` is that jump alone (on top of the price of the extra kWh)."""
    lo, hi, _ = bracket(kwh)
    eps = 0.01

    def jump(at: float) -> float:
        return round(cost(at + eps, overall_rate) - cost(at, overall_rate) - eps * rate_at(at, overall_rate), 2)

    return {
        "min_kwh": lo, "max_kwh": hi,
        "distribution_php_per_kwh": next(r for h, r in DISTRIBUTION if h is None or kwh <= h),
        "up": None if hi is None else {"at_kwh": hi, "kwh_away": round(hi - kwh, 1), "jump_php": jump(hi)},
        "down": None if lo == 0 else {"at_kwh": lo, "kwh_away": round(kwh - lo, 1), "jump_php": jump(lo)},
    }


def schedule(overall_rate: float) -> dict:
    """The rates the bill is priced with, as shown to the household."""
    return {
        "source": SCHEDULE,
        "overall_php_per_kwh": overall_rate,
        "vat_pct": round(VAT * 100),
        "supply_php": SUPPLY_PHP, "metering_php": METERING_PHP,
        "distribution": [{"max_kwh": hi, "php_per_kwh": r} for hi, r in DISTRIBUTION],
        "energy_tax_from_kwh": ENERGY_TAX[0][0],
    }


def season_factor(d: date) -> float:
    """SEASON_INDEX for one day, interpolated between mid-month points so it has no jump on the 1st."""
    n = calendar.monthrange(d.year, d.month)[1]
    t = (d.month - 1) + (d.day - 0.5) / n - 0.5  # months since mid-January
    i = int(t // 1)
    frac = t - i
    return SEASON_INDEX[i % 12] * (1 - frac) + SEASON_INDEX[(i + 1) % 12] * frac
