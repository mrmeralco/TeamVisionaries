"""Money labels must keep their meaning when two periods share a sentence."""
import asyncio

import pytest

from ai import guard, llm, service
from ai.facts import Fact


FACTS = [
    Fact("bill.forecast_php", "bill", "Forecast: ₱2,773 (₱2,442 hanggang ₱3,028)", (2773, 2442, 3028)),
    Fact("bill.last_month_php", "bill", "Bill noong nakaraang buwan: ₱2,051", (2051,)),
    Fact("bill.month_to_date_php", "bill", "Nagastos: ₱1,155", (1155,)),
    Fact("bill.savings_month_php", "savings", "Natipid: ₱1,324", (1324,)),
]
IDS = [f.id for f in FACTS]
QUESTION = "Bakit mataas ang bill ko?"


@pytest.mark.parametrize("reply", [
    "Mataas ang forecast na ₱2,773 kumpara sa nakaraang buwan na ₱2,051.",
    "Mataas ang forecast ng ₱2,773 kumpara sa nakaraang buwan na ₱2,051.",
    "Mas mataas ang forecast na ₱2,773 kaysa noong nakaraang buwan na ₱2,051.",
    "Forecast na ₱2,773 kaysa sa nagastos noong nakaraang buwan na ₱2,051.",
    "The forecast is ₱2,773 compared to last month at ₱2,051.",
    "The forecast is ₱2,773 compared with the previous month at ₱2,051.",
    "The forecast is ₱2,773 versus last month at ₱2,051.",
    "The forecast is ₱2,773 vs. last month at ₱2,051.",
    "The forecast of ₱2,773 is higher than last month's ₱2,051.",
    "Bill noong nakaraang buwan: ₱2,051 kumpara sa forecast na ₱2,773.",
    "Forecast: ₱2,773 (mula ₱2,442 hanggang ₱3,028) kumpara sa nakaraang buwan: ₱2,051.",
    "Forecast: ₱2,773. Nakaraang buwan: ₱2,051.",
])
def test_valid_comparisons_keep_each_amount_with_its_label(reply):
    result = guard.check(reply, IDS, True, FACTS, QUESTION)
    assert result.ok, result.problems


@pytest.mark.parametrize("reply", [
    "Forecast na ₱2,051 kumpara sa nakaraang buwan na ₱2,773.",
    "Forecast na ₱2,773 kumpara sa nakaraang buwan na ₱1,155.",
    "The forecast is ₱2,773 compared to last month at ₱1,155.",
    "Forecast na ₱2,773 kumpara sa nakaraang buwan na ₱1,324.",
    "Forecast na ₱2,773 kumpara sa nakaraang buwan na ₱2,442.",
    "Bill noong nakaraang buwan: ₱2,773 kumpara sa forecast na ₱2,051.",
    "Forecast na ₱2,773 kumpara sa ₱1,155.",
    "Forecast na ₱2,773 vs. ₱1,155.",
    "Forecast na ₱2,773 kumpara sa nakaraang buwan na ₱9,999.",
    "Natipid na ₱1,155 kumpara sa nagastos na ₱1,324.",
])
def test_comparisons_cannot_swap_or_invent_amounts(reply):
    assert not guard.check(reply, IDS, True, FACTS, QUESTION).ok


def test_comparison_requires_the_previous_month_citation():
    reply = "Forecast na ₱2,773 kumpara sa nakaraang buwan na ₱2,051."
    ids = [i for i in IDS if i != "bill.last_month_php"]
    result = guard.check(reply, ids, True, FACTS, QUESTION)
    assert not result.ok
    assert any("must cite" in problem and "bill.last_month_php" in problem for problem in result.problems)


@pytest.mark.parametrize("connector", ["habang", "at", "and", "but"])
def test_cost_and_savings_still_have_separate_labels(connector):
    reply = f"₱1,155 ang nagastos mo {connector} ₱1,324 ang natipid."
    result = guard.check(reply, IDS, True, FACTS, QUESTION)
    assert result.ok, result.problems


def test_valid_comparison_is_returned_without_retry_or_fallback(monkeypatch):
    reply = "Mataas ang forecast na ₱2,773 kumpara sa nakaraang buwan na ₱2,051."
    calls = []

    async def complete(*args):
        calls.append(1)
        return {"answerable": True, "reply": reply,
                "fact_ids": ["bill.forecast_php", "bill.last_month_php"]}

    monkeypatch.setattr(llm, "complete_json", complete)
    out = asyncio.run(service.ask(QUESTION, FACTS, "fallback"))
    assert out["source"] == "llm" and out["reply"] == reply
    assert len(calls) == 1


def test_missing_money_citation_retry_identifies_the_required_fact(monkeypatch):
    reply = "Forecast na ₱2,773 kumpara sa nakaraang buwan na ₱2,051."
    calls = []

    async def complete(system, messages, schema):
        calls.append(messages[-1]["content"])
        ids = ["bill.forecast_php"]
        if len(calls) == 2:
            assert "bill.last_month_php" in calls[-1]
            ids.append("bill.last_month_php")
        return {"answerable": True, "reply": reply, "fact_ids": ids}

    monkeypatch.setattr(llm, "complete_json", complete)
    out = asyncio.run(service.ask(QUESTION, FACTS, "fallback"))
    assert len(calls) == 2 and out["source"] == "llm"
