"""Prompt templates (Stephen + Aldrin own these).

Rule: the backend computes every number. The model only rephrases the FACTS block in Taglish.
"""

SYSTEM = """Ikaw si Sinag, isang friendly na energy assistant para sa bahay na may solar at battery sa Pilipinas.
Sumagot sa natural na Taglish (halo ng Tagalog at English, gaya ng karaniwang Pinoy).
Mga patakaran:
- Gamitin LAMANG ang mga numero at impormasyon sa FACTS. Huwag mag-imbento o mag-compute ng bagong numero.
- Kung wala sa FACTS ang sagot, sabihin na hindi mo pa alam.
- Maikli: hanggang 80 salita. Walang markdown, walang bullet list.
- Pera ay sa piso (₱), enerhiya ay sa kWh.
- Magbigay ng isang praktikal na tip kung bagay."""

CHAT_USER = """FACTS:
{facts}

TANONG ni {user_name}: {message}"""

SUMMARY_USER = """FACTS tungkol sa kahapon ({date}):
{facts}

Isulat ang maikling recap (2-3 pangungusap, hanggang 60 salita) ng kahapon para kay {user_name}.
Banggitin kung ilang porsyento ang galing sa araw, magkano ang nagastos at natipid, at isang tip para ngayong araw."""


def peso(x: float | None) -> str:
    return "—" if x is None else f"₱{x:,.0f}"


def brownout_advice(active: bool, soc: int | None, load_w: int | None, runtime_h: float | None) -> str:
    if not active:
        return "Walang brownout ngayon. Puno-puno ang battery kapag maaraw, kaya handa ka kung sakali."
    if soc is None:
        return "May brownout. Hinihintay pa ang data mula sa inverter."
    if runtime_h is None:
        return f"May brownout. {soc}% ang battery at halos walang gumagamit ng kuryente ngayon."
    tip = ("Patayin muna ang aircon, plantsa at water heater para tumagal ang battery."
           if load_w and load_w > 1000 else "Ilaw, electric fan, ref at charger lang muna para tumagal.")
    return f"May brownout. Sa {load_w} W na gamit, aabot pa ng mga {runtime_h:g} oras ang battery mo ({soc}%). {tip}"
