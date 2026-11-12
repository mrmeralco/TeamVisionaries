"""Router: which fact topics a question gets.   cd server && python -m pytest -q"""
import pytest

from ai.router import topics_for


@pytest.mark.parametrize("question, must_have, must_not_have", [
    # Solar / live questions are specific: no bill bundle (it made the prompt 23 facts long).
    ("Kumusta ang solar ko?", {"now"}, {"bill", "savings"}),
    ("Ilang watts ang solar ngayon?", {"now"}, {"bill"}),
    # A cost word next to a specific topic belongs to that topic.
    ("Magkano kinuha ko sa grid kahapon?", {"yesterday"}, {"bill"}),
    ("Magkano ang natipid ko dahil sa solar?", {"savings"}, {"bill"}),
    # A cost word alone still means the bill.
    ("Bakit mahal ang kuryente?", {"bill", "usage"}, set()),
    ("Bakit mataas ang bill ko?", {"bill", "usage"}, {"savings", "today"}),
    ("Magkano ang forecast ng bill ko?", {"bill"}, set()),
    ("May problema ba ang inverter ko?", {"fault", "now"}, {"bill"}),
    # Pitch-deck question: "pinakamataas" is a cost word, but "consumption" makes it a usage question.
    ("Kailan pinakamataas ang consumption namin?", {"usage"}, {"bill"}),
    # System check: upgrade questions get the upgrade facts; look-alikes don't.
    ("Kailangan ko ba ng dagdag na battery?", {"upgrade"}, set()),
    ("Sapat pa ba ang system ko sa gamit namin?", {"upgrade"}, set()),
    ("Should I upgrade my solar?", {"upgrade"}, set()),
    ("Bakit mas malaki ang bill ko?", {"bill"}, {"upgrade"}),
    ("Sapat ba ang battery mamaya?", {"battery"}, {"upgrade"}),
    ("May problema ba ang inverter ko?", {"fault"}, {"upgrade"}),
    # Household profile: who's home and the routine; a sudden rise is a usage question (new appliance?).
    ("May tao ba sa bahay ngayon?", {"household"}, {"bill"}),
    ("Anong oras kami karaniwang umaalis?", {"household"}, {"bill"}),
    ("Bakit biglang tumaas ang gamit namin?", {"usage"}, set()),
    ("Kumusta ang solar ko?", {"now"}, {"household"}),
    # Vague: broad overview.
    ("Kumusta?", {"today", "bill", "savings"}, set()),
])
def test_topics(question, must_have, must_not_have):
    got = topics_for(question, set())
    assert must_have <= got, got
    assert not (must_not_have & got), got


def test_active_brownout_is_always_added():
    assert "brownout" in topics_for("Magkano ang bill ko?", {"brownout"})


@pytest.mark.parametrize("question,intent", [
    ("Magkano na ang bill ko?", "current"),
    ("Magkano ang forecast?", "forecast"),
    ("Bill so far at forecast?", "both"),
])
def test_bill_selection(question, intent):
    from ai.router import bill_intent, select_facts
    from ai.facts import Fact
    assert bill_intent(question) == intent
    facts = [Fact("bill.month_to_date_php", "bill", "896 pesos"),
             Fact("bill.forecast_php", "bill", "2070 pesos"),
             Fact("brownout.active", "brownout", "May brownout")]
    ids = {f.id for f in select_facts(question, facts)}
    assert "brownout.active" in ids
    assert ("bill.month_to_date_php" in ids) == (intent != "forecast")
    assert ("bill.forecast_php" in ids) == (intent != "current")
