"""Meralco residential pricing and seasonal usage, used by the bill forecast in energy.py.

Both are plain tables so they can be updated without touching the forecast math.

TARIFF
  Meralco prices residential kWh by monthly consumption level (up to 200, 201-300, 301-400, over 400 kWh).
  Most of the difference between levels is the distribution charge, which ERC changes rarely. The overall
  rate moves every month with generation cost. So:
    - the user's `rate_php_per_kwh` setting is the ₱/kWh for the lowest level (up to 200 kWh), which is the
      number to update each month from Meralco's rate announcement;
    - each higher level adds a fixed ₱/kWh on top (BRACKETS below).
  BRACKET_MODE "whole": the whole month's kWh is charged at the rate of the level the total falls in.
  BRACKET_MODE "marginal": only the kWh inside each level pay that level's rate (like income tax).
  The adders are approximate. Check them, and the mode, against a real Meralco bill.
  Not modelled: lifeline discounts (only for registered 4Ps households), fixed per-customer charges.

SEASON_INDEX
  Grid import in each month relative to the yearly average (mean of the 12 values = 1.0). It is a rough
  prior for a Metro Manila household: air-con use peaks in the hot dry season (April-May) and drops in
  the cool months (Dec-Feb). It is damped because the sunny months also give more solar. Replace it with
  values fitted to the household's own data once there is a year of history.
"""
import calendar
from datetime import date

# (upper limit of the level in kWh, ₱/kWh added to the base rate). None = no upper limit.
BRACKETS: list[tuple[float | None, float]] = [
    (200, 0.00),
    (300, 0.35),
    (400, 0.65),
    (None, 1.25),
]
BRACKET_MODE = "whole"  # "whole" or "marginal"

#               Jan   Feb   Mar   Apr   May   Jun   Jul   Aug   Sep   Oct   Nov   Dec
SEASON_INDEX = (0.92, 0.93, 1.00, 1.12, 1.15, 1.06, 1.00, 0.98, 0.97, 0.96, 0.95, 0.96)


def bracket(kwh: float) -> tuple[float, float | None, float]:
    """(lower limit, upper limit, adder) of the consumption level `kwh` falls in."""
    lo = 0.0
    for hi, add in BRACKETS:
        if hi is None or kwh <= hi:
            return lo, hi, add
        lo = hi
    raise AssertionError("BRACKETS must end with an open level (None)")


def cost(kwh: float, base_rate: float) -> float:
    """₱ for a month with `kwh` of grid import."""
    if kwh <= 0:
        return 0.0
    if BRACKET_MODE == "whole":
        return kwh * (base_rate + bracket(kwh)[2])
    total, lo = 0.0, 0.0
    for hi, add in BRACKETS:
        top = kwh if hi is None else min(kwh, hi)
        if top > lo:
            total += (top - lo) * (base_rate + add)
        if hi is None or kwh <= hi:
            break
        lo = hi
    return total


def season_factor(d: date) -> float:
    """SEASON_INDEX for one day, interpolated between mid-month points so it has no jump on the 1st."""
    n = calendar.monthrange(d.year, d.month)[1]
    t = (d.month - 1) + (d.day - 0.5) / n - 0.5  # months since mid-January
    i = int(t // 1)
    frac = t - i
    return SEASON_INDEX[i % 12] * (1 - frac) + SEASON_INDEX[(i + 1) % 12] * frac
