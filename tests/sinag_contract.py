"""Validate any payload against docs/contracts/schema.json.

    from sinag_contract import validate
    validate("live", response.json())     # raises AssertionError listing every mismatch
"""
import json
from pathlib import Path

from jsonschema import Draft202012Validator

SCHEMA_PATH = Path(__file__).resolve().parent.parent / "docs" / "contracts" / "schema.json"
SCHEMA = json.loads(SCHEMA_PATH.read_text())
NAMES = sorted(SCHEMA["$defs"])


def errors(name: str, payload) -> list[str]:
    if name not in SCHEMA["$defs"]:
        raise KeyError(f"no schema named {name!r}; have {NAMES}")
    v = Draft202012Validator({"$defs": SCHEMA["$defs"], "$ref": f"#/$defs/{name}"})
    return [f"{'/'.join(map(str, e.absolute_path)) or '(root)'}: {e.message}" for e in v.iter_errors(payload)]


def validate(name: str, payload) -> None:
    errs = errors(name, payload)
    assert not errs, f"payload does not match contract '{name}':\n  " + "\n  ".join(errs[:15])
