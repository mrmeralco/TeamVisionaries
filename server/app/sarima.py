"""SARIMA forecast of daily grid-import kWh with a weekly cycle, used by the bill forecast (energy.py).

Input: up to HISTORY_DAYS finished days, each already divided by its annual season factor
(tariff.season_factor), so SARIMA only has to learn the weekly pattern and the recent level. Days without
data are NaN; the Kalman filter skips them. The model is fitted on log(1 + kWh): daily use is skewed and
never negative, and on the raw scale simulated days went below zero, which made the range far too narrow.
A few standard orders are fitted and the lowest AIC wins.

Output: the expected kWh for each day ahead, plus SIMS simulated paths for the month-end range.

fit() returns None, and the caller falls back to weekday/weekend averages, when statsmodels isn't
installed, there are fewer than MIN_DAYS days with data, the series barely varies, or no order fits.
A forecast is cached per device per day: it only depends on finished days.
"""
import logging
import warnings
from datetime import date

log = logging.getLogger("solaris.sarima")

HISTORY_DAYS = 56   # 8 weekly cycles; the first bill of a day integrates every one of these days
MIN_DAYS = 28        # 4 weekly cycles
SEASON = 7
SIMS = 500
# (p, d, q), (P, D, Q, s): small stationary weekly models with a constant, so AIC compares like with like
# (differenced models are fitted on fewer points and their AIC isn't comparable). Differencing also
# extrapolated noise in backtests (tools/backtest_forecast.py).
ORDERS = [
    ((1, 0, 0), (1, 0, 0, SEASON)),
    ((1, 0, 0), (1, 0, 1, SEASON)),
    ((0, 0, 0), (1, 0, 0, SEASON)),
]

_cache: dict[tuple[str, date, int], dict | None] = {}


def available() -> bool:
    try:
        import statsmodels  # noqa: F401
    except ImportError:
        return False
    return True


def fit(series: list[float | None]):
    """Best SARIMA result for a daily series (None = no data that day), or None."""
    if not available():
        return None
    import numpy as np
    from statsmodels.tsa.statespace.sarimax import SARIMAX

    y = np.log1p(np.array([np.nan if v is None else max(0.0, float(v)) for v in series]))
    first = int(np.argmax(~np.isnan(y))) if (~np.isnan(y)).any() else len(y)
    y = y[first:]  # drop the days before the device existed
    obs = y[~np.isnan(y)]
    if len(obs) < MIN_DAYS or obs.std() < 1e-6:
        return None
    best = None
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")  # convergence chatter on short series
        for order, seasonal in ORDERS:
            try:
                res = SARIMAX(y, order=order, seasonal_order=seasonal, trend="c").fit(disp=False)
            except Exception as e:  # noqa: BLE001 - statsmodels raises many kinds; any failure = skip this order
                log.debug("SARIMA%s%s failed: %s", order, seasonal, e)
                continue
            if np.isfinite(res.aic) and (best is None or res.aic < best.aic):
                best = res
    return best


def cached_forecast(device_id: str, d: date, series: list[float | None], h: int) -> dict | None:
    """fit + predict, cached per device, day and horizon (finished days don't change during the day).
    {"model": "SARIMA(...)", "mean": per day, "paths": (h, SIMS)} or None when fit() gives up."""
    key = (device_id, d, h)
    if key not in _cache:
        if len(_cache) > 32:
            _cache.clear()
        res = fit(series)
        if res is None:
            _cache[key] = None
        else:
            mean, paths = predict(res, h)
            _cache[key] = {"model": describe(res), "mean": mean, "paths": paths}
    return _cache[key]


def predict(res, h: int):
    """(expected kWh per day ahead, simulated kWh paths shape (h, SIMS)), back on the kWh scale.
    The expected value is the mean of the simulated days, not exp(mean of logs), which would be the median."""
    import numpy as np

    # Innovations are the model's own one-step errors, resampled (residual bootstrap), not Gaussian draws:
    # sunny days push grid use to ~0, so the errors are skewed, and Gaussian noise made the range too narrow.
    # statsmodels takes custom shocks for one path at a time (~0.7 ms each).
    rng = np.random.default_rng(0)
    resid = np.asarray(res.resid)[SEASON:]
    resid = resid[np.isfinite(resid)]
    sims = np.column_stack([
        np.asarray(res.simulate(nsimulations=h, anchor="end", state_shocks=rng.choice(resid, size=(h, 1)))).reshape(h)
        for _ in range(SIMS)])
    paths = np.maximum(np.expm1(sims), 0.0)
    return paths.mean(axis=1), paths


def describe(res) -> str:
    """'SARIMA(1,0,1)(0,1,1)7' for logs and the AI facts."""
    o, s = res.model.order, res.model.seasonal_order
    return f"SARIMA({o[0]},{o[1]},{o[2]})({s[0]},{s[1]},{s[2]}){s[3]}"
