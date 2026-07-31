#!/usr/bin/env python3
"""Compile Portal source evidence into a deterministic architecture model and site data."""

from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import re
import sys
import tempfile
from collections import defaultdict
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
CONFIG_PATH = ROOT / "architecture/config.json"
MODEL_PATH = ROOT / "architecture/model/model.json"
SITE_DATA_PATH = ROOT / "architecture/site/data.js"
SEMANTIC_PATH = ROOT / "architecture/semantic/components.json"

DECLARATION_RE = re.compile(
    r"(?m)^\s*(?:(?:public|package|internal|private|fileprivate|open|final|indirect|nonisolated)\s+)*"
    r"(?:class|struct|enum|protocol|actor)\s+([A-Z][A-Za-z0-9_]*)\b"
)
IDENTIFIER_RE = re.compile(r"\b[A-Z][A-Za-z0-9_]{3,}\b")


class ArchitectureError(RuntimeError):
    """Raised when source-backed architecture data is invalid."""


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ArchitectureError(f"Cannot read {path.relative_to(ROOT)}: {exc}") from exc
    if not isinstance(value, dict):
        raise ArchitectureError(f"{path.relative_to(ROOT)} must contain a JSON object")
    return value


def relative(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def validate_config(config: dict[str, Any]) -> None:
    if config.get("schema_version") != "1.0.0":
        raise ArchitectureError("architecture/config.json must use schema_version 1.0.0")

    layers = config.get("layers")
    components = config.get("components")
    if not isinstance(layers, list) or not isinstance(components, list):
        raise ArchitectureError("config layers and components must be arrays")

    layer_ids = [item.get("id") for item in layers if isinstance(item, dict)]
    component_ids = [item.get("id") for item in components if isinstance(item, dict)]
    if len(layer_ids) != len(set(layer_ids)) or None in layer_ids:
        raise ArchitectureError("layer IDs must be present and unique")
    if len(component_ids) != len(set(component_ids)) or None in component_ids:
        raise ArchitectureError("component IDs must be present and unique")

    known_layers = set(layer_ids)
    for component in components:
        if component.get("layer") not in known_layers:
            raise ArchitectureError(f"unknown layer for component {component.get('id')}")
        if not component.get("external") and not component.get("patterns"):
            raise ArchitectureError(f"source component {component.get('id')} has no patterns")

    known_components = set(component_ids)
    for edge in config.get("specified_edges", []):
        if edge.get("source") not in known_components or edge.get("target") not in known_components:
            raise ArchitectureError(f"edge has unknown endpoint: {edge}")
        validate_evidence(edge.get("evidence", []), f"edge {edge.get('source')} → {edge.get('target')}")


def validate_evidence(evidence: Any, owner: str) -> list[str]:
    if not isinstance(evidence, list) or not evidence:
        raise ArchitectureError(f"{owner} must cite at least one evidence path")
    normalized: list[str] = []
    for item in evidence:
        if not isinstance(item, str) or item.startswith("/") or ".." in Path(item).parts:
            raise ArchitectureError(f"{owner} has an invalid evidence path: {item!r}")
        if not (ROOT / item).is_file():
            raise ArchitectureError(f"{owner} cites missing file: {item}")
        normalized.append(item)
    return sorted(set(normalized))


def assign_component(source_relative: str, components: list[dict[str, Any]]) -> str | None:
    for component in components:
        if component.get("external"):
            continue
        for pattern in component.get("patterns", []):
            if fnmatch.fnmatchcase(source_relative, pattern):
                return str(component["id"])
    return None


def read_sources(config: dict[str, Any]) -> tuple[list[dict[str, Any]], str]:
    source_root = ROOT / str(config["source_root"])
    components = config["components"]
    files: list[dict[str, Any]] = []
    digest = hashlib.sha256()

    for path in sorted(source_root.rglob("*.swift")):
        text = path.read_text(encoding="utf-8")
        repo_path = relative(path)
        source_relative = path.relative_to(source_root).as_posix()
        component_id = assign_component(source_relative, components)
        declarations = sorted(set(DECLARATION_RE.findall(text)))
        digest.update(repo_path.encode("utf-8"))
        digest.update(b"\0")
        digest.update(text.encode("utf-8"))
        digest.update(b"\0")
        files.append(
            {
                "path": repo_path,
                "source_path": source_relative,
                "component": component_id,
                "declarations": declarations,
                "line_count": len(text.splitlines()),
                "identifiers": sorted(set(IDENTIFIER_RE.findall(text))),
            }
        )
    return files, digest.hexdigest()


def build_reference_edges(files: list[dict[str, Any]]) -> list[dict[str, Any]]:
    symbol_owner: dict[str, str] = {}
    ambiguous: set[str] = set()
    for item in files:
        owner = item["component"]
        if owner is None:
            continue
        for symbol in item["declarations"]:
            previous = symbol_owner.get(symbol)
            if previous is not None and previous != owner:
                ambiguous.add(symbol)
            else:
                symbol_owner[symbol] = owner
    for symbol in ambiguous:
        symbol_owner.pop(symbol, None)

    relationships: dict[tuple[str, str], dict[str, set[str]]] = defaultdict(
        lambda: {"symbols": set(), "evidence": set()}
    )
    for item in files:
        source = item["component"]
        if source is None:
            continue
        for symbol in item["identifiers"]:
            target = symbol_owner.get(symbol)
            if target is None or target == source or symbol in item["declarations"]:
                continue
            relationship = relationships[(source, target)]
            relationship["symbols"].add(symbol)
            relationship["evidence"].add(item["path"])

    edges: list[dict[str, Any]] = []
    for (source, target), data in sorted(relationships.items()):
        symbols = sorted(data["symbols"])
        evidence = sorted(data["evidence"])
        if len(symbols) < 2 and len(evidence) < 2:
            continue
        edges.append(
            {
                "source": source,
                "target": target,
                "type": "references",
                "authority": "observed",
                "description": f"References {len(symbols)} declaration(s) owned by {target}.",
                "symbols": symbols[:12],
                "evidence": evidence[:12],
                "weight": len(symbols) + len(evidence),
            }
        )
    return edges


def load_semantic(component_ids: set[str]) -> list[dict[str, Any]]:
    semantic = load_json(SEMANTIC_PATH)
    if semantic.get("schema_version") != "1.0.0" or not isinstance(semantic.get("components"), list):
        raise ArchitectureError("architecture/semantic/components.json has an unsupported schema")

    records: list[dict[str, Any]] = []
    seen: set[str] = set()
    for raw in semantic["components"]:
        if not isinstance(raw, dict):
            raise ArchitectureError("semantic component entries must be objects")
        component_id = raw.get("id")
        if component_id not in component_ids or component_id in seen:
            raise ArchitectureError(f"invalid or duplicate semantic component ID: {component_id!r}")
        summary = raw.get("summary")
        if not isinstance(summary, str) or not summary.strip():
            raise ArchitectureError(f"semantic component {component_id} needs a summary")
        evidence = validate_evidence(raw.get("evidence"), f"semantic component {component_id}")
        records.append(
            {
                "id": component_id,
                "summary": summary.strip(),
                "responsibilities": normalized_strings(raw.get("responsibilities", [])),
                "flows": normalized_strings(raw.get("flows", [])),
                "open_questions": normalized_strings(raw.get("open_questions", [])),
                "evidence": evidence,
                "source_revision": str(raw.get("source_revision", "unknown")),
                "model": str(raw.get("model", "unknown")),
                "authority": "synthesized",
            }
        )
        seen.add(component_id)
    return sorted(records, key=lambda item: item["id"])


def normalized_strings(value: Any) -> list[str]:
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise ArchitectureError("semantic list fields must be arrays of strings")
    return sorted(set(item.strip() for item in value if item.strip()))


def load_specifications(config: dict[str, Any]) -> list[dict[str, str]]:
    specs: list[dict[str, str]] = []
    for spec in config.get("specifications", []):
        path = ROOT / str(spec["path"])
        if not path.is_file():
            raise ArchitectureError(f"missing specification: {spec['path']}")
        specs.append(
            {
                "id": str(spec["id"]),
                "title": str(spec["title"]),
                "path": str(spec["path"]),
                "markdown": path.read_text(encoding="utf-8").strip(),
                "authority": "specified",
            }
        )
    return specs


def compile_architecture() -> tuple[dict[str, Any], dict[str, Any]]:
    config = load_json(CONFIG_PATH)
    validate_config(config)
    files, source_hash = read_sources(config)
    component_ids = {str(item["id"]) for item in config["components"]}
    semantic = load_semantic(component_ids)

    files_by_component: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for item in files:
        if item["component"] is not None:
            files_by_component[item["component"]].append(item)

    semantic_by_id = {item["id"]: item for item in semantic}
    components: list[dict[str, Any]] = []
    for configured in config["components"]:
        component_id = str(configured["id"])
        owned = files_by_component.get(component_id, [])
        declarations = sorted({name for item in owned for name in item["declarations"]})
        component = {
            "id": component_id,
            "label": str(configured["label"]),
            "layer": str(configured["layer"]),
            "description": str(configured["description"]),
            "external": bool(configured.get("external", False)),
            "file_count": len(owned),
            "line_count": sum(item["line_count"] for item in owned),
            "declaration_count": len(declarations),
            "files": [item["path"] for item in owned],
            "declarations": declarations,
        }
        if component_id in semantic_by_id:
            component["semantic"] = semantic_by_id[component_id]
        components.append(component)

    specified_edges = []
    for edge in config.get("specified_edges", []):
        specified_edges.append(
            {
                **edge,
                "authority": "specified",
                "evidence": validate_evidence(
                    edge["evidence"], f"edge {edge['source']} → {edge['target']}"
                ),
                "weight": 20,
            }
        )

    reference_edges = build_reference_edges(files)
    unassigned = [item["path"] for item in files if item["component"] is None]
    model = {
        "schema_version": "1.0.0",
        "repository": config["repository"],
        "title": config["title"],
        "description": config["description"],
        "source_tree_sha256": source_hash,
        "layers": sorted(config["layers"], key=lambda item: item["order"]),
        "components": components,
        "edges": specified_edges + reference_edges,
        "inventory": {
            "swift_files": len(files),
            "swift_lines": sum(item["line_count"] for item in files),
            "declarations": sum(len(item["declarations"]) for item in files),
            "assigned_files": len(files) - len(unassigned),
            "unassigned_files": unassigned,
        },
    }
    site_data = {"model": model, "specifications": load_specifications(config)}
    return model, site_data


def serialized_json(value: Any) -> str:
    return json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def expected_outputs() -> dict[Path, str]:
    model, site_data = compile_architecture()
    data_json = json.dumps(site_data, separators=(",", ":"), sort_keys=True, ensure_ascii=False)
    return {
        MODEL_PATH: serialized_json(model),
        SITE_DATA_PATH: f"window.PORTAL_ARCHITECTURE={data_json};\n",
    }


def check_outputs(outputs: dict[Path, str]) -> None:
    stale: list[str] = []
    for path, expected in outputs.items():
        actual = path.read_text(encoding="utf-8") if path.is_file() else None
        if actual != expected:
            stale.append(relative(path))
    if stale:
        raise ArchitectureError(
            "generated architecture output is stale: " + ", ".join(stale) + "; run make architecture"
        )


def write_outputs(outputs: dict[Path, str]) -> None:
    for path, content in outputs.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, delete=False) as handle:
            handle.write(content)
            temporary = Path(handle.name)
        temporary.replace(path)
        print(f"wrote {relative(path)}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail if checked-in outputs are stale")
    args = parser.parse_args()
    try:
        outputs = expected_outputs()
        if args.check:
            check_outputs(outputs)
            print("architecture model and site data are current")
        else:
            write_outputs(outputs)
    except ArchitectureError as exc:
        print(f"architecture error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
