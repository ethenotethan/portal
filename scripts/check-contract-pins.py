#!/usr/bin/env python3
"""Contract pin check: the vendored hermes.architecture contract is the one Harness ships.

`architecture/contract/architecture_contract.py` is vendored byte-for-byte from
Harness (`tui_gateway/architecture_contract.py`) and is the code the compiler
validates its own output with, the gateway validates documents with, and the
renderers decode against. Drift on either side would surface only when a
document is refused or a renderer meets a field it does not know. So the copy
is pinned: `pins.json` records the sha256 of the module and of its JSON Schema
export, and this check fails when

  * the module or the schema export no longer matches its pin;
  * the schema export is not what the module itself exports (`schema_json()`);
  * the committed model (`architecture/model/model.json`) does not conform.

Changing the contract is therefore a deliberate act: vendor the new copy, bump
the pin, in the same PR — and do the same in Harness. The constraint ratchet
guards this script like every other `scripts/check-*.py`: it may be replaced,
not removed.

Usage:
    check-contract-pins.py
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
import sys
from pathlib import Path
from typing import Any, List

ROOT = Path(__file__).resolve().parents[1]
CONTRACT_DIR = ROOT / "architecture" / "contract"
MODULE_PATH = CONTRACT_DIR / "architecture_contract.py"
SCHEMA_PATH = CONTRACT_DIR / "architecture-document-v1.schema.json"
PINS_PATH = CONTRACT_DIR / "pins.json"
MODEL_PATH = ROOT / "architecture" / "model" / "model.json"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_module(path: Path) -> Any:
    spec = importlib.util.spec_from_file_location("architecture_contract_pinned", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def evaluate(root: Path = ROOT) -> List[str]:
    """Every way the vendored contract, its export, its pin or the model disagree."""
    contract_dir = root / "architecture" / "contract"
    module_path = contract_dir / "architecture_contract.py"
    schema_path = contract_dir / "architecture-document-v1.schema.json"
    pins_path = contract_dir / "pins.json"
    model_path = root / "architecture" / "model" / "model.json"
    problems: List[str] = []
    for path in (module_path, schema_path, pins_path):
        if not path.is_file():
            problems.append(f"{path.relative_to(root)}: missing")
    if problems:
        return problems
    try:
        pins = json.loads(pins_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        return [f"{pins_path.relative_to(root)}: not valid JSON ({exc})"]
    digests = pins.get("sha256") if isinstance(pins.get("sha256"), dict) else {}
    for path in (module_path, schema_path):
        pinned = digests.get(path.name)
        actual = sha256(path)
        if pinned != actual:
            problems.append(
                f"{path.relative_to(root)}: sha256 {actual[:12]}… does not match the pin {str(pinned)[:12]}… "
                "(vendor the new copy from Harness and bump pins.json in the same PR)"
            )
    module = load_module(module_path)
    if schema_path.read_text(encoding="utf-8") != module.schema_json():
        problems.append(f"{schema_path.relative_to(root)}: is not the module's own schema export (run `python3 {module_path.relative_to(root)} --schema`)")
    if str(pins.get("version")) != str(module.CONTRACT_VERSION):
        problems.append(f"{pins_path.relative_to(root)}: version {pins.get('version')!r} is not the module's {module.CONTRACT_VERSION!r}")
    if not model_path.is_file():
        problems.append(f"{model_path.relative_to(root)}: missing (run make architecture)")
        return problems
    issues = module.validate_document(json.loads(model_path.read_text(encoding="utf-8")))
    for issue in issues[:20]:
        problems.append(f"{model_path.relative_to(root)}: {issue}")
    if len(issues) > 20:
        problems.append(f"{model_path.relative_to(root)}: +{len(issues) - 20} more problem(s)")
    return problems


def main() -> int:
    problems = evaluate()
    if not problems:
        module = load_module(MODULE_PATH)
        print(f"Contract pins: {module.CONTRACT_NAME} v{module.CONTRACT_VERSION} vendored copy matches its pins and the model conforms.")
        return 0
    print(f"Contract pins: {len(problems)} problem(s):")
    for problem in problems:
        print(f"  - {problem}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
