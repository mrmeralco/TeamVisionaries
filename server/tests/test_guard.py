"""Unit tests for the hallucination guard.   cd server && python -m pytest -q"""
from ai.facts import Fact
from ai.guard import check, numbers_in

FACTS = [
    Fact("bill.month_to_date_php", "bill", "Bill ngayong buwan: ₱746", (745.78, 57.37)),
    Fact("bill.forecast_php", "bill", "Forecast: mga ₱1,995 (₱1,833 hanggang ₱2,156)", (1994.6, 1833.46, 2155.74)),
    Fact("now.battery_pct", "battery", "Battery: 78%", (78,)),
    Fact("usage.peak_hours", "usage", "Peak: 7AM, 9PM, 10PM", (7, 7, 21, 9, 22, 10)),
    Fact("today.grid_kwh", "today", "Kinuha sa grid: 2.3 kWh", (2.34,)),
]
IDS = ["bill.month_to_date_php", "bill.forecast_php"]


def ok(reply, ids=IDS, answerable=True, q="Bakit mataas ang bill ko?"):
    return check(reply, ids, answerable, FACTS, q)


def test_numbers_parsing():
    assert [v for _, v, _ in numbers_in("₱1,995 at 2.3 kWh, 9PM, 21:00")] == [1995, 2.3, 9, 21, 0]


def test_grounded_reply_passes():
    assert ok("₱746 na ang bill mo, at mga ₱1,995 ang forecast.").ok


def test_rounding_of_a_real_fact_is_allowed():
    assert ok("Mga ₱2,000 ang forecast, ₱746 na ngayon.").ok      # 2% of 1994.6
    assert ok("Kinuha sa grid ngayong araw: 2.3 kWh.", ["today.grid_kwh"]).ok
    assert ok("Pinakamaraming gamit tuwing 9PM.", ["usage.peak_hours"]).ok


def test_made_up_number_is_rejected():
    r = ok("₱746 na ang bill mo pero aabot ito ng ₱3,500.")
    assert not r.ok and r.unknown_numbers == ["3,500"]


def test_made_up_percentage_is_rejected():
    assert not ok("Tumaas ng 35% ang bill mo.").ok


def test_wrong_decimal_is_rejected():
    assert not ok("Kinuha sa grid: 2.9 kWh.", ["today.grid_kwh"]).ok


def test_number_from_the_users_question_is_allowed():
    assert ok("Hindi ko alam kung ano ang mangyayari sa 5 oras, pero ₱746 na ang bill mo.", q="Paano kung 5 oras?").ok


def test_unknown_fact_id_is_rejected():
    assert not ok("₱746 na ang bill mo.", ["bill.month_to_date_php", "bill.next_year"]).ok


def test_answerable_without_citation_is_rejected():
    assert not ok("Maayos ang lahat.", []).ok


def test_too_long_is_rejected():
    assert not ok("salita " * 200).ok
