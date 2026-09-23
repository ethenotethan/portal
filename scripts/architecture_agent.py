#!/usr/bin/env python3
"""Produce constrained, evidence-backed semantic architecture records.

Three kinds of record, all LLM-written and all validated by the compiler before
they can be written (see architecture/SEMANTIC_ENRICHMENT_PLAN.md):

- component summaries (`architecture/semantic/components.json`): the original
  layer, one prose record per source component;
- construct records (`architecture/semantic/constructs.json`): one record per
  construction on the System map (store, external, transport, engine, provider,
  client file, namespace, page, surface, seam) in a kind-specific schema whose
  identifiers must exist in the mechanical model;
- system flows (`architecture/semantic/flows.json`): named paths whose every step
  is an edge the map already draws.

The model sees a bounded packet (mechanical facts, the schema with its enums, the
fields already known mechanically, the current record, and capped source
excerpts from the construct's own files) and returns JSON. Anything the compiler's
validators reject is dropped with the reason printed; the previous record, if any,
is kept. Enrichment never adds a node or an edge.

Providers: an OpenAI-compatible endpoint (OPENAI_API_KEY, OPENAI_BASE_URL,
ARCHITECTURE_MODEL) or the local `claude` CLI in print mode with structured
output (ARCHITECTURE_PROVIDER=claude-cli, or automatically when no API key is set
and the CLI is on PATH).
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
MODEL_PATH = ROOT / "architecture/model/model.json"
SEMANTIC_PATH = ROOT / "architecture/semantic/components.json"
CONSTRUCTS_PATH = ROOT / "architecture/semantic/constructs.json"
FLOWS_PATH = ROOT / "architecture/semantic/flows.json"
COMPILER_PATH = ROOT / "scripts/build_architecture.py"

# Per-batch bounds: how many constructs share one request and how much source
# each may bring. Small enough to read, large enough to amortise the call.
BATCH_SIZE = {"endpoint": 8, "client": 6, "external": 4, "store": 4, "surface": 4, "page": 3}
DEFAULT_BATCH = 3
EXCERPT_LINES = 300
PACKET_CHARS = 70_000


class AgentError(RuntimeError):
    """Raised when an agent response cannot cross the repository boundary."""


def load_compiler() -> Any:
    spec = importlib.util.spec_from_file_location("build_architecture", COMPILER_PATH)
    if spec is None or spec.loader is None:
        raise AgentError("cannot load architecture compiler")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
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


# ---------------------------------------------------------------------------
# Providers
# ---------------------------------------------------------------------------

def provider_name() -> str:
    configured = os.environ.get("ARCHITECTURE_PROVIDER", "").strip()
    if configured:
        return configured
    if os.environ.get("OPENAI_API_KEY", "").strip():
        return "openai"
    if shutil.which("claude"):
        return "claude-cli"
    raise AgentError("no provider: set OPENAI_API_KEY or install the claude CLI (ARCHITECTURE_PROVIDER=claude-cli)")


def strip_fences(content: str) -> str:
    content = content.strip()
    if content.startswith("```"):
        lines = content.splitlines()
        content = "\n".join(lines[1:-1])
    return content


def request_json(prompt: str, schema: dict[str, Any]) -> tuple[dict[str, Any], str]:
    """One completion returning a JSON object that conforms to ``schema``."""
    provider = provider_name()
    if provider == "openai":
        return request_openai(prompt)
    if provider == "claude-cli":
        return request_claude_cli(prompt, schema)
    raise AgentError(f"unknown provider {provider!r}")


def request_openai(prompt: str) -> tuple[dict[str, Any], str]:
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
    try:
        parsed = json.loads(strip_fences(content))
    except json.JSONDecodeError as exc:
        raise AgentError(f"architecture model did not return valid JSON: {exc}") from exc
    if not isinstance(parsed, dict):
        raise AgentError("architecture model response must be a JSON object")
    return parsed, model


def request_claude_cli(prompt: str, schema: dict[str, Any]) -> tuple[dict[str, Any], str]:
    """The local claude CLI in print mode: no tools, structured output, no session."""
    command = [
        "claude", "-p", prompt, "--output-format", "json", "--no-session-persistence",
        "--tools", "", "--json-schema", json.dumps(schema),
    ]
    model = os.environ.get("ARCHITECTURE_MODEL", "").strip()
    if model:
        command += ["--model", model]
    try:
        run = subprocess.run(command, capture_output=True, text=True, check=False, timeout=900, cwd="/")
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise AgentError(f"claude CLI failed: {exc}") from exc
    if run.returncode != 0:
        raise AgentError(f"claude CLI exited {run.returncode}: {run.stderr.strip()[:400]}")
    try:
        envelope = json.loads(run.stdout)
    except json.JSONDecodeError as exc:
        raise AgentError(f"claude CLI printed no JSON envelope: {exc}") from exc
    if envelope.get("is_error"):
        raise AgentError(f"claude CLI reported an error: {str(envelope.get('result'))[:400]}")
    parsed = envelope.get("structured_output")
    if not isinstance(parsed, dict):
        try:
            parsed = json.loads(strip_fences(str(envelope.get("result", ""))))
        except json.JSONDecodeError as exc:
            raise AgentError(f"claude CLI response is not a JSON object: {exc}") from exc
    if not isinstance(parsed, dict):
        raise AgentError("claude CLI response must be a JSON object")
    used = list((envelope.get("modelUsage") or {}).keys())
    return parsed, (model or (used[0] if used else "claude-cli"))


# ---------------------------------------------------------------------------
# Component summaries (the original layer)
# ---------------------------------------------------------------------------

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


COMPONENT_SCHEMA = {
    "type": "object",
    "properties": {"components": {"type": "array", "items": {
        "type": "object",
        "properties": {
            "id": {"type": "string"}, "summary": {"type": "string"},
            "responsibilities": {"type": "array", "items": {"type": "string"}},
            "flows": {"type": "array", "items": {"type": "string"}},
            "open_questions": {"type": "array", "items": {"type": "string"}},
            "evidence": {"type": "array", "items": {"type": "string"}},
        },
        "required": ["id", "summary", "evidence"],
    }}},
    "required": ["components"],
}


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


# ---------------------------------------------------------------------------
# Construct records
# ---------------------------------------------------------------------------

class Context:
    """The compiled model plus the source files the validators need."""

    def __init__(self, compiler: Any) -> None:
        self.compiler = compiler
        self.model = json.loads(MODEL_PATH.read_text(encoding="utf-8"))
        config = compiler.load_json(compiler.CONFIG_PATH)
        files, _digest = compiler.read_sources(config)
        launch_files, _launch_digest = compiler.read_launch_sources(config)
        self.files = files + launch_files
        self.text_by_path = {item["path"]: item["_text"] for item in self.files}
        self.interplay = self.model["interplay"]
        self.externals = self.model.get("externals") or {"systems": []}
        self.by_id = {node["id"]: node for node in self.interplay["nodes"]}
        self.by_key = {node["history_key"]: node for node in self.interplay["nodes"] if node["kind"] != "operation"}

    def edges_of(self, node: dict[str, Any]) -> list[dict[str, Any]]:
        out: list[dict[str, Any]] = []
        for edge in self.interplay["edges"]:
            if edge["source"] == node["id"] and edge["target"] in self.by_id:
                other = self.by_id[edge["target"]]
                out.append({"direction": "out", "relation": edge["relation"], "key": other["history_key"], "label": other["label"], "kind": other["kind"]})
            elif edge["target"] == node["id"] and edge["source"] in self.by_id:
                other = self.by_id[edge["source"]]
                out.append({"direction": "in", "relation": edge["relation"], "key": other["history_key"], "label": other["label"], "kind": other["kind"]})
        return sorted(out, key=lambda item: (item["direction"], item["relation"], item["key"]))


def describe_schema(schema: dict[str, tuple[Any, ...]]) -> dict[str, str]:
    out: dict[str, str] = {}
    for name, spec in schema.items():
        kind = spec[0]
        if kind == "enum":
            out[name] = "one of: " + " | ".join(spec[1])
        elif kind == "list_enum":
            out[name] = "list drawn from: " + " | ".join(spec[1])
        elif kind == "str":
            out[name] = f"string, at most {spec[1]} characters"
        elif kind == "list_str":
            out[name] = f"list of strings, each at most {spec[1]} characters"
        elif kind == "bool":
            out[name] = "true or false"
        elif kind == "int":
            out[name] = "non-negative integer"
        elif kind == "types":
            out[name] = "list of Swift type names declared in the source tree (as seen in the excerpts)"
        elif kind == "keys":
            out[name] = f"list of construct keys that share a {'/'.join(sorted(spec[1]))} edge with this construct (use keys from `edges`)"
        elif kind == "endpoints":
            out[name] = "list of endpoint namespace labels on the map"
        elif kind == "triggers":
            out[name] = "list of trigger ids from the packet"
        elif kind == "pages":
            out[name] = "list of page ids from the packet"
        elif kind == "page_nodes":
            out[name] = "list of construct keys that belong to this page (from `members`)"
    return out


def type_excerpt(text: str, type_name: str, compiler: Any, limit: int = EXCERPT_LINES) -> dict[str, Any] | None:
    """The declaring block of ``type_name`` (first non-extension match), capped."""
    for match in compiler.TYPE_BLOCK_RE.finditer(text):
        if match.group(2) != type_name or match.group(1) == "extension":
            continue
        start = text.rfind("\n", 0, match.start()) + 1
        open_brace = text.index("{", match.start())
        end = compiler.balanced_block_end(text, open_brace + 1)
        lines = text[start:end].splitlines()
        from_line = text.count("\n", 0, start) + 1
        truncated = len(lines) > limit
        return {"from_line": from_line, "text": "\n".join(lines[:limit]) + ("\n… (truncated)" if truncated else "")}
    return None


def window_excerpt(text: str, line: int, radius: int = 6) -> dict[str, Any]:
    lines = text.splitlines()
    lo = max(1, line - radius)
    hi = min(len(lines), line + radius)
    return {"from_line": lo, "text": "\n".join(lines[lo - 1:hi])}


def construct_targets(ctx: Context) -> list[dict[str, Any]]:
    """Every construct that carries a record: nodes with a schema kind, plus pages."""
    targets: list[dict[str, Any]] = []
    for node in ctx.interplay["nodes"]:
        kind = ctx.compiler.construct_kind(node)
        if kind is not None:
            targets.append({"key": node["history_key"], "kind": kind, "node": node})
    for page in ctx.interplay.get("pages", []):
        targets.append({"key": f"page:{page['id']}", "kind": "page", "page": page})
    return targets


def construct_facts(target: dict[str, Any], ctx: Context) -> dict[str, Any]:
    compiler = ctx.compiler
    if target["kind"] == "page":
        page = target["page"]
        members = [n for n in ctx.interplay["nodes"] if n.get("page") == page["id"]]
        triggers = [t for t in ctx.interplay.get("triggers", []) if t.get("page") == page["id"]]
        files = sorted({n["path"] for n in members if n.get("path")})
        excerpts = []
        for root in page.get("roots", [])[:2]:
            for path, text in ctx.text_by_path.items():
                if re.search(rf"\bstruct\s+{re.escape(root)}\b", text):
                    excerpt = type_excerpt(text, root, compiler, 90)
                    if excerpt:
                        excerpts.append({"path": path, **excerpt})
                        files.append(path)
                    break
        return {
            "key": target["key"], "kind": "page", "label": page["label"],
            "mechanical": {"roots": page.get("roots"), "namespaces": page.get("namespaces"), "type_count": page.get("type_count")},
            "members": [{"key": n["history_key"], "kind": n["kind"], "label": n["label"]} for n in members],
            "triggers": [{"id": t["id"], "kind": t["kind"], "api": t["api"], "view": t.get("view"), "surface": t["surface"], "method": t["method"]} for t in triggers[:40]],
            "bounded_files": sorted(set(files)), "excerpts": excerpts, "prefilled": {},
        }
    node = target["node"]
    edges = ctx.edges_of(node)
    mechanical: dict[str, Any] = {
        "interplay_kind": node["kind"], "label": node["label"], "page": node.get("page"), "component": node.get("component"),
        "roles": node.get("roles"), "sub_kind": node.get("sub_kind"), "protocol": node.get("protocol"),
        "namespaces": node.get("namespaces"), "method_count": node.get("method_count"), "store": node.get("store"),
        "triggers": node.get("triggers"), "loads": node.get("loads"), "configures": node.get("configures"),
        "description": node.get("description"), "overlay_prose": node.get("overlay_prose"),
    }
    mechanical = {k: v for k, v in mechanical.items() if v not in (None, [], {}, "")}
    prefilled: dict[str, Any] = {}
    if target["kind"] == "store":
        persistence = (node.get("store") or {}).get("persistence") or ["unobserved"]
        prefilled["medium_compatible_with_source"] = sorted(set().union(*(compiler.STORE_MEDIUM_OF_PERSISTENCE.get(p, set()) for p in persistence)))
        prefilled["readers_or_writers_candidates"] = sorted(e["key"] for e in edges if e["direction"] == "in" and e["relation"] in ("uses", "loads"))
        if "keychain" in persistence:
            prefilled["sensitive"] = True
    if target["kind"] == "provider":
        prefilled["configures"] = sorted(e["key"] for e in edges if e["direction"] == "out" and e["relation"] == "configures")
        prefilled["loads"] = sorted(e["key"] for e in edges if e["direction"] == "out" and e["relation"] == "loads")
    if target["kind"] == "client":
        prefilled["wraps"] = sorted(e["key"] for e in edges if e["direction"] == "out" and e["relation"] == "implements")
    if target["kind"] == "engine":
        prefilled["runtime"] = sorted(e["key"] for e in edges if e["direction"] == "out" and e["relation"] == "runs-on")
    if target["kind"] == "transport":
        prefilled["shared_by"] = sorted({ctx.by_key[e["key"]].get("page") for e in edges if e["direction"] == "in" and e["relation"] == "holds" and ctx.by_key[e["key"]].get("page")})
    allowed = compiler.bounded_files(node, ctx.interplay, ctx.by_id, ctx.externals)
    excerpts: list[dict[str, Any]] = []
    budget = 3
    if node.get("path") and node["path"] in ctx.text_by_path:
        excerpt = type_excerpt(ctx.text_by_path[node["path"]], node["label"], compiler)
        if excerpt:
            excerpts.append({"path": node["path"], **excerpt})
            budget -= 1
    if node["kind"] == "external":
        for system in ctx.externals.get("systems", []):
            if system["id"] != node.get("system_id"):
                continue
            mechanical["external"] = {"category": system.get("category"), "description": system.get("description"), "persistence": system.get("persistence"), "file_count": system.get("file_count"), "hit_count": system.get("hit_count")}
            for hit in system.get("usage", [])[:6]:
                for site in (hit.get("evidence") or [])[:2]:
                    if site["path"] in ctx.text_by_path and budget > 0:
                        excerpts.append({"path": site["path"], **window_excerpt(ctx.text_by_path[site["path"]], site["line"], 4)})
                        budget -= 1
    if target["kind"] == "store":
        for item in ctx.model.get("stores", {}).get("items", []):
            if item["type_name"] != node["label"]:
                continue
            for mechanism in item.get("mechanisms", [])[:4]:
                site = mechanism.get("evidence") or {}
                covered = any(x["path"] == site.get("path") and x["from_line"] <= site.get("line", 0) <= x["from_line"] + EXCERPT_LINES for x in excerpts)
                if site.get("path") in ctx.text_by_path and budget > 0 and not covered:
                    excerpts.append({"path": site["path"], **window_excerpt(ctx.text_by_path[site["path"]], site["line"], 5)})
                    budget -= 1
    return {
        "key": target["key"], "kind": target["kind"], "label": node["label"], "mechanical": mechanical,
        "edges": edges[:60], "prefilled": prefilled, "bounded_files": sorted(allowed), "excerpts": excerpts,
    }


def fields_json_schema(schema: dict[str, tuple[Any, ...]]) -> dict[str, Any]:
    """The kind's field vocabulary as a JSON schema, so structured output cannot
    invent a field, overrun a length or leave an enum."""
    properties: dict[str, Any] = {}
    for name, spec in schema.items():
        kind = spec[0]
        if kind == "enum":
            properties[name] = {"type": "string", "enum": list(spec[1])}
        elif kind == "list_enum":
            properties[name] = {"type": "array", "items": {"type": "string", "enum": list(spec[1])}}
        elif kind == "str":
            properties[name] = {"type": "string", "maxLength": spec[1]}
        elif kind == "list_str":
            properties[name] = {"type": "array", "items": {"type": "string", "maxLength": spec[1]}}
        elif kind == "bool":
            properties[name] = {"type": "boolean"}
        elif kind == "int":
            properties[name] = {"type": "integer", "minimum": 0}
        else:
            properties[name] = {"type": "array", "items": {"type": "string"}}
    return {"type": "object", "properties": properties, "additionalProperties": False}


def construct_prompt(batch: list[dict[str, Any]], kind: str, ctx: Context, existing: dict[str, dict[str, Any]], source_revision: str) -> tuple[str, dict[str, Any]]:
    compiler = ctx.compiler
    schema = describe_schema(compiler.CONSTRUCT_SCHEMAS[kind])
    records = []
    for target in batch:
        facts = construct_facts(target, ctx)
        facts["existing_record"] = existing.get(target["key"])
        records.append(facts)
    packet = {"repository": ctx.model["repository"], "source_revision": source_revision, "kind": kind, "records": records}
    text = json.dumps(packet, indent=1, sort_keys=True, ensure_ascii=False)
    while len(text) > PACKET_CHARS and any(r["excerpts"] for r in records):
        longest = max((x for r in records for x in r["excerpts"]), key=lambda x: len(x["text"]))
        lines = longest["text"].splitlines()
        if len(lines) <= 20:
            break
        longest["text"] = "\n".join(lines[: max(20, len(lines) // 2)]) + "\n… (truncated)"
        text = json.dumps(packet, indent=1, sort_keys=True, ensure_ascii=False)
    prompt = f"""You describe constructions on a mechanically derived architecture map of one Swift repository.
You may only state what the packet's excerpts and mechanical facts support. The map, its nodes and edges, are authoritative; you add text, never structure.

Return one JSON object {{"records": [...]}} with exactly one record per input record, in this shape:
{{
  "key": "the input key, unchanged",
  "kind": "{kind}",
  "summary": "one paragraph, present tense, what this construction is and does in the current source",
  "fields": {{ ...only fields from the schema below; omit a field rather than guess... }},
  "open_questions": ["what the excerpts do not settle"],
  "evidence": [{{"path": "a path from bounded_files", "line": 1}}]
}}

Schema for kind {kind} (every field optional, values constrained exactly as stated):
{json.dumps(schema, indent=1)}

Rules:
- Fields under `prefilled` are known mechanically. You may narrow them (for example pick one medium from medium_compatible_with_source) but never contradict them.
- Where a field wants construct keys, use only keys that appear in this record's `edges` (or `members` for a page). Never invent a key.
- `record_type` must be Swift type names that appear in the excerpts.
- Every evidence path must be in this record's bounded_files, with a line number inside the excerpt ranges you saw (from_line plus the offset).
- Prefer an open question over an unsupported claim. Do not describe desired design.
- Keep the summary under {compiler.SEMANTIC_SUMMARY_MAX} characters, open questions under 200. Output JSON only.

Packet:
{text}
"""
    json_schema = {
        "type": "object",
        "properties": {"records": {"type": "array", "items": {
            "type": "object",
            "properties": {
                "key": {"type": "string"}, "kind": {"type": "string"},
                "summary": {"type": "string", "maxLength": compiler.SEMANTIC_SUMMARY_MAX},
                "fields": fields_json_schema(compiler.CONSTRUCT_SCHEMAS[kind]),
                "open_questions": {"type": "array", "items": {"type": "string", "maxLength": 200}},
                "evidence": {"type": "array", "minItems": 1, "items": {"type": "object", "properties": {"path": {"type": "string"}, "line": {"type": "integer", "minimum": 1}}, "required": ["path", "line"]}},
            },
            "required": ["key", "kind", "summary", "fields", "evidence"],
        }}},
        "required": ["records"],
    }
    return prompt, json_schema


def run_constructs(ctx: Context, targets: list[dict[str, Any]], source_revision: str, jobs: int, dry_run: bool) -> tuple[int, int]:
    compiler = ctx.compiler
    existing_doc = json.loads(CONSTRUCTS_PATH.read_text(encoding="utf-8")) if CONSTRUCTS_PATH.is_file() else {"schema_version": "1.0.0", "records": []}
    existing = {r["key"]: r for r in existing_doc.get("records", []) if isinstance(r, dict) and isinstance(r.get("key"), str)}
    by_kind: dict[str, list[dict[str, Any]]] = {}
    for target in targets:
        by_kind.setdefault(target["kind"], []).append(target)
    batches: list[tuple[str, list[dict[str, Any]]]] = []
    for kind, items in sorted(by_kind.items()):
        size = BATCH_SIZE.get(kind, DEFAULT_BATCH)
        for index in range(0, len(items), size):
            batches.append((kind, items[index:index + size]))
    if dry_run:
        total = 0
        for kind, batch in batches:
            prompt, _schema = construct_prompt(batch, kind, ctx, existing, source_revision)
            total += len(prompt)
            print(f"--- {kind}: {[t['key'] for t in batch]} ({len(prompt)} chars)")
            if len(batches) == 1:
                print(prompt)
        print(f"{len(batches)} request(s), {total} chars in total")
        return 0, 0

    accepted: dict[str, dict[str, Any]] = {}
    rejected = 0

    def work(item: tuple[str, list[dict[str, Any]]]) -> list[tuple[str, dict[str, Any] | None, str]]:
        kind, batch = item
        prompt, schema = construct_prompt(batch, kind, ctx, existing, source_revision)
        try:
            response, model_name = request_json(prompt, schema)
        except AgentError as exc:
            return [(t["key"], None, f"request failed: {exc}") for t in batch]
        raw_records = response.get("records") if isinstance(response, dict) else None
        if not isinstance(raw_records, list):
            return [(t["key"], None, "response has no records array") for t in batch]
        by_key_raw = {r.get("key"): r for r in raw_records if isinstance(r, dict)}
        out = []
        for target in batch:
            raw = by_key_raw.get(target["key"])
            if raw is None:
                out.append((target["key"], None, "missing from response"))
                continue
            raw = dict(raw)
            raw["source_revision"] = source_revision
            raw["model"] = model_name
            raw.pop("cited_hash", None)
            try:
                record = compiler.validate_construct_record(raw, ctx.interplay, ctx.files, ctx.externals)
            except compiler.ArchitectureError as exc:
                out.append((target["key"], None, str(exc)))
                continue
            stored = {k: v for k, v in record.items() if k not in ("stale", "authority")}
            out.append((target["key"], stored, "ok"))
        return out

    with ThreadPoolExecutor(max_workers=max(1, jobs)) as pool:
        for results in pool.map(work, batches):
            for key, record, reason in results:
                if record is None:
                    rejected += 1
                    print(f"rejected {key}: {reason}", file=sys.stderr, flush=True)
                else:
                    accepted[key] = record
                    print(f"described {key}", flush=True)
    for key, record in accepted.items():
        existing[key] = record
    # Records for constructs that left the map are dropped rather than kept stale.
    live_keys = {t["key"] for t in construct_targets(ctx)}
    kept = [existing[key] for key in sorted(existing) if key in live_keys]
    CONSTRUCTS_PATH.write_text(json.dumps({"schema_version": "1.0.0", "records": kept}, indent=2, sort_keys=True, ensure_ascii=False) + "\n", encoding="utf-8")
    return len(accepted), rejected


# ---------------------------------------------------------------------------
# System flows
# ---------------------------------------------------------------------------

JOURNEY_BRIEFS = {
    "launch": ("Starting the app", "What happens when the user starts the application: what the entry points construct, "
               "what is read from disk or the keychain, how the transport is configured and connected, what the first "
               "screen depends on. 1 to 3 flows."),
    "chat_turn": ("A chat turn", "What happens when the user does a chat turn: typing a prompt and receiving the streamed "
                  "reply, answering an approval or clarification, a voice turn, anything that is part of one exchange. "
                  "2 to 4 flows, one per distinct interaction."),
    "page": ("Entering and using a page", "What the user can do on this page: entering it (lifecycle triggers such as "
             "onAppear/task load data), then each interaction the page's views offer (each user_action trigger: buttons, "
             "toggles, pickers, gestures), and what each reaches (client file, transport, namespace, gateway, store, event "
             "stream). One flow for entering the page, then one flow per distinct interaction or group of closely related "
             "interactions. 1 to 4 flows."),
}


def journey_scope(ctx: Context, journey: str, page_id: str | None) -> tuple[set[str], list[dict[str, Any]]]:
    """The node keys and triggers a journey may use: the page's constructs, everything
    one edge away from them, the transport and gateway, the event stream, externals."""
    key_of = {n["id"]: n["history_key"] for n in ctx.interplay["nodes"]}
    drawn = {n["history_key"]: n for n in ctx.interplay["nodes"] if n["kind"] != "operation"}
    page = page_id or ("launch" if journey == "launch" else "chat")
    seeds = {k for k, n in drawn.items() if n.get("page") == page}
    always = {k for k, n in drawn.items() if n["kind"] in ("seam", "external") or (n["kind"] == "owner" and "transport" in (n.get("roles") or []))
              or n.get("sub_kind") == "event_bus" or n["kind"] == "endpoint" or n["kind"] == "client"}
    scope = set(seeds) | always
    for edge in ctx.interplay["edges"]:
        source, target = key_of.get(edge["source"]), key_of.get(edge["target"])
        if source in seeds and target in drawn:
            scope.add(target)
        if target in seeds and source in drawn:
            scope.add(source)
    # The core's own resources and sections travel with it so a flow can name the pool.
    core = next((n for n in drawn.values() if n["kind"] == "owner" and "transport" in (n.get("roles") or [])), None)
    if core:
        scope |= {k for k, n in drawn.items() if n.get("owner_type") == core["label"] and n["kind"] in ("resource", "section")}
    triggers = [t for t in ctx.interplay.get("triggers", []) if t.get("page") == page]
    return scope, triggers


def flows_prompt(ctx: Context, journey: str, page_id: str | None, existing: list[dict[str, Any]], source_revision: str) -> tuple[str, dict[str, Any]]:
    compiler = ctx.compiler
    key_of = {n["id"]: n["history_key"] for n in ctx.interplay["nodes"]}
    drawn = {n["history_key"]: n for n in ctx.interplay["nodes"] if n["kind"] != "operation"}
    scope, triggers = journey_scope(ctx, journey, page_id)
    page = page_id or ("launch" if journey == "launch" else "chat")
    page_label = next((p["label"] for p in ctx.interplay.get("pages", []) if p["id"] == page), page)
    nodes = [{"key": k, "kind": drawn[k]["kind"], "label": drawn[k]["label"], "page": drawn[k].get("page"), "roles": drawn[k].get("roles"),
              "summary": (drawn[k].get("semantic") or {}).get("summary")} for k in sorted(scope) if k in drawn]
    triples = sorted({(key_of[e["source"]], e["relation"], key_of[e["target"]]) for e in ctx.interplay["edges"]
                      if key_of.get(e["source"]) in scope and key_of.get(e["target"]) in scope})
    trigger_rows = []
    for t in triggers:
        surface = compiler.surface_node_for(ctx.interplay["nodes"], t["surface"])
        if surface is not None:
            trigger_rows.append({"id": t["id"], "kind": t["kind"], "api": t["api"], "view": t.get("view"), "surface_key": surface["history_key"],
                                 "method": t["method"], "namespaces": t.get("namespaces"), "path": t["path"], "line": t["line"]})
    files_of = {k: drawn[k].get("path") for k in scope if k in drawn and drawn[k].get("path")}
    title, brief = JOURNEY_BRIEFS[journey]
    packet = {
        "repository": ctx.model["repository"], "source_revision": source_revision,
        "journey": journey, "page": page, "page_label": page_label, "brief": brief,
        "nodes": nodes, "edges": [list(t) for t in triples],
        "trigger_edges": f"a trigger row implies the edge [\"page:{page}\", \"triggers\", surface_key]; a flow that starts from a user action or from launch should begin with it",
        "triggers": trigger_rows[:120], "node_files": files_of, "existing_flows_for_this_journey": existing,
    }
    text = json.dumps(packet, indent=1, sort_keys=True, ensure_ascii=False)
    prompt = f"""You describe one user journey of an application as system flows over its mechanically derived architecture graph.
Journey: {title} ({'page ' + page_label if journey == 'page' else journey}). Brief: {brief}
A flow is a path over edges that exist in the graph, never a diagram beside it; it will be rendered as a sequence diagram whose participants are the nodes and whose messages are the steps.

Return one JSON object {{"flows": [...]}}, each flow shaped:
{{
  "id": "kebab-case-slug, unique, prefixed with the journey or page (e.g. cron-open-dashboard)",
  "title": "at most 80 characters, from the user's point of view (\"Open the cron dashboard\", \"Toggle a job\")",
  "interaction": "at most 80 characters: the user action or lifecycle moment that starts it (\"Refresh button\", \"page appears\", \"app starts\")",
  "summary": "what happens end to end, at most {compiler.SEMANTIC_SUMMARY_MAX} characters, present tense",
  "journey": "{journey}",
  "page": "{page}",
  "trigger": "a trigger id from `triggers`, or null",
  "steps": [{{"from": "node key", "to": "node key", "relation": "edge relation", "note": "what this hop means for the user, at most {compiler.SEMANTIC_NOTE_MAX} characters"}}],
  "outcome": "what the user sees at the end, at most 200 characters",
  "evidence": [{{"path": "a file from node_files of a node in the steps", "line": 1}}]
}}

Hard rules:
- Every step must be exactly one of the listed `edges` triples [from, relation, to], or a trigger edge ["page:{page}", "triggers", surface_key] for a listed trigger. Do not invent edges.
- Steps are connected: a step's `from` must be a node an earlier step already reached (or the very first `from`); fan-out from an earlier node is allowed.
- {compiler.FLOW_MIN_STEPS} to {compiler.FLOW_MAX_STEPS} steps. Start each flow from the trigger edge when a trigger fits.
- Cover the interactions the triggers show; do not describe interactions the triggers and edges cannot support.
- Evidence lines are best-effort line numbers in the named file (line 1 is acceptable when unknown).
- Output JSON only.

Packet:
{text}
"""
    json_schema = {
        "type": "object",
        "properties": {"flows": {"type": "array", "items": {
            "type": "object",
            "properties": {
                "id": {"type": "string", "pattern": "^[a-z][a-z0-9-]{2,60}$"},
                "title": {"type": "string", "maxLength": 80},
                "interaction": {"type": "string", "maxLength": 80},
                "summary": {"type": "string", "maxLength": compiler.SEMANTIC_SUMMARY_MAX},
                "journey": {"type": "string", "enum": [journey]},
                "page": {"type": "string", "enum": [page]},
                "trigger": {"type": ["string", "null"]},
                "steps": {"type": "array", "minItems": compiler.FLOW_MIN_STEPS, "maxItems": compiler.FLOW_MAX_STEPS, "items": {"type": "object", "properties": {
                    "from": {"type": "string"}, "to": {"type": "string"}, "relation": {"type": "string"},
                    "note": {"type": "string", "maxLength": compiler.SEMANTIC_NOTE_MAX}},
                    "required": ["from", "to", "relation"]}},
                "outcome": {"type": "string", "maxLength": 200},
                "evidence": {"type": "array", "minItems": 1, "items": {"type": "object", "properties": {"path": {"type": "string"}, "line": {"type": "integer", "minimum": 1}}, "required": ["path", "line"]}},
            },
            "required": ["id", "title", "interaction", "summary", "journey", "page", "steps", "outcome", "evidence"],
        }}},
        "required": ["flows"],
    }
    return prompt, json_schema


def all_journeys(ctx: Context) -> list[tuple[str, str | None]]:
    journeys: list[tuple[str, str | None]] = [("launch", None), ("chat_turn", None)]
    for page in ctx.interplay.get("pages", []):
        if page["id"] not in ("launch", "chat"):
            journeys.append(("page", page["id"]))
    return journeys


def run_flows(ctx: Context, source_revision: str, journeys: list[tuple[str, str | None]], jobs: int, dry_run: bool, replace: bool) -> tuple[int, int]:
    compiler = ctx.compiler
    existing_doc = json.loads(FLOWS_PATH.read_text(encoding="utf-8")) if FLOWS_PATH.is_file() else {"schema_version": "1.0.0", "flows": []}
    existing = [f for f in existing_doc.get("flows", []) if isinstance(f, dict) and isinstance(f.get("id"), str)]
    selected = {(j, p or ("launch" if j == "launch" else "chat")) for j, p in journeys}

    def for_journey(journey: str, page_id: str | None) -> list[dict[str, Any]]:
        page = page_id or ("launch" if journey == "launch" else "chat")
        return [f for f in existing if f.get("journey") == journey and f.get("page") == page]

    if dry_run:
        for journey, page_id in journeys:
            prompt, _schema = flows_prompt(ctx, journey, page_id, [] if replace else for_journey(journey, page_id), source_revision)
            print(f"--- {journey} {page_id or ''}: {len(prompt)} chars")
        return 0, 0

    def work(item: tuple[str, str | None]) -> list[tuple[dict[str, Any] | None, str]]:
        journey, page_id = item
        prompt, schema = flows_prompt(ctx, journey, page_id, [] if replace else for_journey(journey, page_id), source_revision)
        try:
            response, model_name = request_json(prompt, schema)
        except AgentError as exc:
            return [(None, f"{journey} {page_id or ''}: request failed: {exc}")]
        raw_flows = response.get("flows") if isinstance(response, dict) else None
        if not isinstance(raw_flows, list):
            return [(None, f"{journey} {page_id or ''}: response has no flows array")]
        out = []
        for raw in raw_flows:
            if not isinstance(raw, dict):
                out.append((None, "flow is not an object"))
                continue
            raw = dict(raw)
            raw["source_revision"] = source_revision
            raw["model"] = model_name
            try:
                flow = compiler.validate_flow(raw, ctx.interplay, ctx.files)
            except compiler.ArchitectureError as exc:
                out.append((None, f"{raw.get('id')!r}: {exc}"))
                continue
            if flow["problems"]:
                out.append((None, f"{flow['id']}: " + "; ".join(flow["problems"])))
                continue
            out.append(({k: v for k, v in flow.items() if k not in ("status", "problems", "authority")}, "ok"))
        return out

    kept: dict[str, dict[str, Any]] = {}
    if not replace:
        kept = {f["id"]: f for f in existing if (f.get("journey"), f.get("page")) not in selected and f.get("journey")}
    rejected = 0
    accepted = 0
    with ThreadPoolExecutor(max_workers=max(1, jobs)) as pool:
        for results in pool.map(work, journeys):
            for flow, reason in results:
                if flow is None:
                    rejected += 1
                    print(f"rejected flow {reason}", file=sys.stderr, flush=True)
                else:
                    kept[flow["id"]] = flow
                    accepted += 1
                    print(f"traced flow {flow['id']} ({flow['journey']} {flow['page']}, {len(flow['steps'])} steps)", flush=True)
    FLOWS_PATH.write_text(json.dumps({"schema_version": "1.0.0", "flows": [kept[k] for k in sorted(kept)]}, indent=2, sort_keys=True, ensure_ascii=False) + "\n", encoding="utf-8")
    return accepted, rejected


# ---------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base", help="base commit for changed-file discovery (component mode)")
    parser.add_argument("--head", default="HEAD", help="head commit to summarize")
    parser.add_argument("--all", action="store_true", help="component mode: reconcile every source-owned component")
    parser.add_argument("--constructs", action="store_true", help="write construct records (architecture/semantic/constructs.json)")
    parser.add_argument("--kinds", default="", help="construct mode: comma-separated schema kinds to include")
    parser.add_argument("--keys", default="", help="construct mode: comma-separated construct keys to include")
    parser.add_argument("--stale-only", action="store_true", help="construct mode: only constructs with no record or a stale one")
    parser.add_argument("--flows", action="store_true", help="write system flows (architecture/semantic/flows.json)")
    parser.add_argument("--journeys", default="", help="flows mode: comma-separated journeys to (re)write, e.g. launch,chat_turn,page:cron (default: all)")
    parser.add_argument("--replace-flows", action="store_true", help="flows mode: discard every existing flow first")
    parser.add_argument("--jobs", type=int, default=4, help="construct mode: parallel requests")
    parser.add_argument("--dry-run", action="store_true", help="print the bounded packet(s) without calling a model")
    args = parser.parse_args()

    try:
        head = git_output("rev-parse", args.head)
        compiler = load_compiler()
        if args.constructs or args.flows:
            ctx = Context(compiler)
            if args.constructs:
                targets = construct_targets(ctx)
                if args.kinds:
                    wanted = {k.strip() for k in args.kinds.split(",") if k.strip()}
                    targets = [t for t in targets if t["kind"] in wanted]
                if args.keys:
                    wanted_keys = {k.strip() for k in args.keys.split(",") if k.strip()}
                    targets = [t for t in targets if t["key"] in wanted_keys]
                if args.stale_only:
                    described = {n["history_key"]: n.get("semantic") for n in ctx.interplay["nodes"]}
                    described.update({f"page:{p['id']}": p.get("semantic") for p in ctx.interplay.get("pages", [])})
                    targets = [t for t in targets if not described.get(t["key"]) or described[t["key"]].get("stale")]
                if not targets:
                    print("no constructs selected")
                else:
                    accepted, rejected = run_constructs(ctx, targets, head, args.jobs, args.dry_run)
                    if not args.dry_run:
                        print(f"construct records: {accepted} described, {rejected} rejected")
            if args.flows:
                journeys = all_journeys(ctx)
                if args.journeys:
                    wanted = [j.strip() for j in args.journeys.split(",") if j.strip()]
                    journeys = [(j.split(":", 1)[0], j.split(":", 1)[1] if ":" in j else None) for j in wanted]
                accepted, rejected = run_flows(ctx, head, journeys, args.jobs, args.dry_run, args.replace_flows)
                if not args.dry_run:
                    print(f"flows: {accepted} kept, {rejected} rejected")
            return 0

        base = args.base or git_output("rev-parse", f"{head}^")
        changes = changed_files(base, head)
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
            response, model_name = request_json(prompt_for(component_packet), COMPONENT_SCHEMA)
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
