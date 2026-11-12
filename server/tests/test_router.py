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
    # Vague: broad overview.
    ("Kumusta?", {"today", "bill", "savings"}, set()),
])
def test_topics(question, must_have, must_not_have):
    got = topics_for(question, set())
    assert must_have <= got, got
    assert not (must_not_have & got), got


def test_active_brownout_is_always_added():
    assert "brownout" in topics_for("Magkano ang bill ko?", {"brownout"})
