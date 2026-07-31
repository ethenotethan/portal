#!/usr/bin/env python3
"""Produce constrained, evidence-backed semantic architecture updates for changed components."""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
MODEL_PATH = ROOT / "architecture/model/model.json"
SEMANTIC_PATH = ROOT / "architecture/semantic/components.json"
COMPILER_PATH = ROOT / "scripts/build_architecture.py"


class AgentError(RuntimeError):
    """Raised when an agent response cannot cross the repository boundary."""


def load_compiler() -> Any:
    spec = importlib.util.spec_from_file_location("build_architecture", COMPILER_PATH)
    if spec is None or spec.loader is None:
        raise AgentError("cannot load architecture compiler")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def git_output(*args: str) -> str:
    process = subprocess.run(
        ["git", *args],
        cwd=ROOT,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if process.returncode != 0:
        raise AgentError(process.stderr.strip() or f"git {' '.join(args)} failed")
    return process.stdout.strip()


def changed_files(base: str, head: str) -> list[str]:
    return sorted(
        line for line in git_output("diff", "--name-only", f"{base}...{head}").splitlines() if line
    )


def affected_components(model: dict[str, Any], changes: list[str], compiler: Any) -> list[dict[str, Any]]:
    config = compiler.load_json(compiler.CONFIG_PATH)
    source_root = str(config["source_root"]).rstrip("/") + "/"
    by_id = {component["id"]: component for component in model["components"]}
    affected_ids: set[str] = set()

    for path in changes:
        if not path.startswith(source_root) or not path.endswith(".swift"):
            continue
        source_relative = path[len(source_root):]
        component_id = compiler.assign_component(source_relative, config["components"])
        if component_id:
            affected_ids.add(component_id)

    return [by_id[component_id] for component_id in sorted(affected_ids)]


def build_packet(
    model: dict[str, Any],
    components: list[dict[str, Any]],
    changes: list[str],
    existing: dict[str, Any],
    source_revision: str,
) -> dict[str, Any]:
    existing_by_id = {item["id"]: item for item in existing.get("components", [])}
    return {
        "repository": model["repository"],
        "source_revision": source_revision,
        "changed_files": changes,
        "components": [
            {
                "id": component["id"],
                "label": component["label"],
                "description": component["description"],
                "files": component["files"],
                "declarations": component["declarations"],
                "existing_semantic_record": existing_by_id.get(component["id"]),
            }
            for component in components
        ],
    }


def prompt_for(packet: dict[str, Any]) -> str:
    return f"""You maintain semantic architecture summaries for one repository.
You are intentionally constrained to the affected components in the input packet.

Return one JSON object with a `components` array. Return exactly one entry for each input component, using this schema:
{{
  "components": [{{
    "id": "input component id",
    "summary": "2-4 source-backed sentences describing current responsibility and behavior",
    "responsibilities": ["bounded responsibility"],
    "flows": ["runtime or data flow involving this component"],
    "open_questions": ["question only when evidence is insufficient"],
    "evidence": ["repository-relative source path from the input packet"]
  }}]
}}

Rules:
- Use only component IDs and evidence paths present in the packet.
- Describe current source, not desired future design.
- Do not create specifications, decisions, requirements, or architectural rules.
- Preserve a useful existing summary when the changed files do not invalidate it.
- Every entry needs at least one evidence path.
- Prefer an open question over an unsupported claim.
- Output JSON only, without Markdown fences.

Input packet:
{json.dumps(packet, indent=2, sort_keys=True)}
"""


def request_completion(prompt: str) -> tuple[dict[str, Any], str]:
    api_key = os.environ.get("OPENAI_API_KEY", "").strip()
    if not api_key:
        raise AgentError("OPENAI_API_KEY is not configured")
    base_url = (os.environ.get("OPENAI_BASE_URL") or "https://api.openai.com/v1").rstrip("/")
    model = os.environ.get("ARCHITECTURE_MODEL") or os.environ.get("OPENAI_MODEL") or "gpt-4o-mini"
    body = json.dumps(
        {
            "model": model,
            "temperature": 0.1,
            "messages": [
                {"role": "system", "content": "You emit bounded, evidence-backed architecture JSON."},
                {"role": "user", "content": prompt},
            ],
        }
    ).encode("utf-8")
    request = urllib.request.Request(
        f"{base_url}/chat/completions",
        data=body,
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
            "User-Agent": "portal-architecture-maintainer/1.0",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=180) as response:
            payload = json.load(response)
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        raise AgentError(f"architecture model request failed: {exc}") from exc

    try:
        content = payload["choices"][0]["message"]["content"].strip()
    except (KeyError, IndexError, TypeError, AttributeError) as exc:
        raise AgentError("architecture model response has no message content") from exc
    if content.startswith("```"):
        lines = content.splitlines()
        content = "\n".join(lines[1:-1])
    try:
        parsed = json.loads(content)
    except json.JSONDecodeError as exc:
        raise AgentError(f"architecture model did not return valid JSON: {exc}") from exc
    if not isinstance(parsed, dict):
        raise AgentError("architecture model response must be a JSON object")
    return parsed, model


def validate_response(
    response: dict[str, Any],
    components: list[dict[str, Any]],
    source_revision: str,
    model_name: str,
) -> list[dict[str, Any]]:
    raw_records = response.get("components")
    if not isinstance(raw_records, list):
        raise AgentError("response components must be an array")

    allowed = {component["id"]: set(component["files"]) for component in components}
    if {record.get("id") for record in raw_records if isinstance(record, dict)} != set(allowed):
        raise AgentError("response must contain exactly the affected component IDs")

    validated: list[dict[str, Any]] = []
    for record in raw_records:
        if not isinstance(record, dict):
            raise AgentError("response component entries must be objects")
        component_id = record["id"]
        summary = record.get("summary")
        if not isinstance(summary, str) or not summary.strip():
            raise AgentError(f"{component_id} has no summary")
        evidence = record.get("evidence")
        if not isinstance(evidence, list) or not evidence:
            raise AgentError(f"{component_id} has no evidence")
        if not all(isinstance(path, str) and path in allowed[component_id] for path in evidence):
            raise AgentError(f"{component_id} cites evidence outside its bounded source set")

        validated.append(
            {
                "id": component_id,
                "summary": summary.strip(),
                "responsibilities": string_list(record.get("responsibilities", []), component_id),
                "flows": string_list(record.get("flows", []), component_id),
                "open_questions": string_list(record.get("open_questions", []), component_id),
                "evidence": sorted(set(evidence)),
                "source_revision": source_revision,
                "model": model_name,
            }
        )
    return sorted(validated, key=lambda item: item["id"])


def string_list(value: Any, component_id: str) -> list[str]:
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise AgentError(f"{component_id} semantic fields must be arrays of strings")
    return sorted(set(item.strip() for item in value if item.strip()))


def merge_records(existing: dict[str, Any], updates: list[dict[str, Any]]) -> dict[str, Any]:
    records = {
        item["id"]: item
        for item in existing.get("components", [])
        if isinstance(item, dict) and isinstance(item.get("id"), str)
    }
    for update in updates:
        records[update["id"]] = update
    return {"schema_version": "1.0.0", "components": [records[key] for key in sorted(records)]}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", help="base commit for changed-file discovery")
    parser.add_argument("--head", default="HEAD", help="head commit to summarize")
    parser.add_argument("--all", action="store_true", help="reconcile every source-owned component")
    parser.add_argument("--dry-run", action="store_true", help="print the bounded packet without calling a model")
    args = parser.parse_args()

    try:
        head = git_output("rev-parse", args.head)
        base = args.base or git_output("rev-parse", f"{head}^")
        changes = changed_files(base, head)
        compiler = load_compiler()
        model = json.loads(MODEL_PATH.read_text(encoding="utf-8"))
        existing = json.loads(SEMANTIC_PATH.read_text(encoding="utf-8"))
        components = (
            [component for component in model["components"] if not component["external"]]
            if args.all
            else affected_components(model, changes, compiler)
        )
        if not components:
            print("no architecture components affected")
            return 0

        packet = build_packet(model, components, changes, existing, head)
        if args.dry_run:
            print(json.dumps(packet, indent=2, sort_keys=True))
            return 0

        updates: list[dict[str, Any]] = []
        for component in components:
            component_packet = build_packet(model, [component], changes, existing, head)
            response, model_name = request_completion(prompt_for(component_packet))
            updates.extend(validate_response(response, [component], head, model_name))
            print(f"validated semantic architecture for {component['id']}")
        merged = merge_records(existing, updates)
        SEMANTIC_PATH.write_text(json.dumps(merged, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(f"updated {len(updates)} semantic architecture component(s)")
    except (AgentError, OSError, json.JSONDecodeError) as exc:
        print(f"architecture agent error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
