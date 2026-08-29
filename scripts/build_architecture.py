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

BEHAVIOR_RULES = {
    "swift.execution.main_actor": "@MainActor applied to a declaration or extension",
    "swift.execution.actor": "Swift actor declaration",
    "swift.execution.dispatch_queue": "Stored property initialized with DispatchQueue(label:)",
    "swift.task.structured": "Task initializer with closure",
    "swift.task.detached": "Task.detached closure",
    "swift.task.stored_handle": "Stored property whose declared type is Task",
    "swift.task.cancel": "cancel() invoked on a named stored Task handle",
    "swift.resource.websocket.stored": "Stored property declared as URLSessionWebSocketTask",
    "swift.resource.url_session.stored": "Stored property declared as URLSession",
    "swift.resource.sse.bytes": "URLSession bytes(for:) call in a source file containing a text/event-stream marker",
    "swift.resource.combine_subject.stored": "Stored property initialized as a PassthroughSubject or CurrentValueSubject",
    "swift.resource.continuation.stored": "Stored property declared as an AsyncStream continuation",
    "swift.resource.lock.stored": "Stored property declared or initialized as NSLock or OSAllocatedUnfairLock",
    "swift.resource.timer.stored": "Stored property declared as Timer",
    "swift.lifecycle.create": "Named stored resource assigned from a mechanically recognized factory",
    "swift.lifecycle.acquire": "lock() invoked on a named stored lock",
    "swift.lifecycle.release": "unlock() invoked on a named stored lock",
    "swift.lifecycle.invalidate": "invalidate() invoked on a named stored timer",
    "swift.lifecycle.continuation_publish": "yield() invoked on a named stored continuation",
    "swift.lifecycle.continuation_close": "finish() invoked on a named stored continuation",
    "swift.lifecycle.publish": "send() invoked on a named stored stream subject",
    "swift.lifecycle.batch": "Combine collect() batching operator in a subject pipeline",
    "swift.lifecycle.hop": "Combine receive(on:) scheduler boundary in a subject pipeline",
    "swift.lifecycle.sse_subscribe": "bytes(for:) invoked on a named stored URLSession",
    "swift.lifecycle.sse_replay_cursor": "setValue uses a Last-Event-ID header marker",
    "swift.lifecycle.start": "resume() invoked on a named stored resource",
    "swift.lifecycle.receive": "receive() invoked on a named stored resource",
    "swift.lifecycle.send": "send() invoked on a named stored resource",
    "swift.lifecycle.close": "cancel(with:reason:) invoked on a named stored WebSocket resource",
}

STATIC_SOURCE_LIMITATIONS = [
    "Static source evidence does not prove runtime overlap, scheduling order, OS thread use, or live resource counts.",
    "Regex and lexical rules identify mechanically visible declarations and operations; dynamic aliases and interprocedural flows remain unresolved.",
]


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


def stable_behavior_id(category: str, path: str, line: int, label: str) -> str:
    seed = f"{category}\0{path}\0{line}\0{label}".encode("utf-8")
    return f"{category}-{hashlib.sha256(seed).hexdigest()[:12]}"


def strip_swift_noncode(text: str) -> str:
    """Replace comments and string contents with spaces while preserving line positions."""
    output = list(text)
    index = 0
    state = "code"
    block_depth = 0
    while index < len(text):
        pair = text[index:index + 2]
        if state == "code":
            if pair == "//":
                output[index:index + 2] = "  "
                state = "line_comment"
                index += 2
                continue
            if pair == "/*":
                output[index:index + 2] = "  "
                state = "block_comment"
                block_depth = 1
                index += 2
                continue
            if text.startswith('"""', index):
                output[index:index + 3] = "   "
                state = "multiline_string"
                index += 3
                continue
            if text[index] == '"':
                output[index] = " "
                state = "string"
        elif state == "line_comment":
            if text[index] == "\n":
                state = "code"
            else:
                output[index] = " "
        elif state == "block_comment":
            if pair == "/*":
                output[index:index + 2] = "  "
                block_depth += 1
                index += 2
                continue
            if pair == "*/":
                output[index:index + 2] = "  "
                block_depth -= 1
                index += 2
                if block_depth == 0:
                    state = "code"
                continue
            if text[index] != "\n":
                output[index] = " "
        elif state == "string":
            if text[index] == "\\":
                output[index] = " "
                if index + 1 < len(text):
                    if text[index + 1] != "\n":
                        output[index + 1] = " "
                    index += 2
                    continue
            if text[index] == '"':
                output[index] = " "
                state = "code"
            elif text[index] != "\n":
                output[index] = " "
        elif state == "multiline_string":
            if text.startswith('"""', index):
                output[index:index + 3] = "   "
                state = "code"
                index += 3
                continue
            if text[index] != "\n":
                output[index] = " "
        index += 1
    return "".join(output)


def source_evidence(path: str, text: str, offset: int) -> dict[str, Any]:
    line = text.count("\n", 0, offset) + 1
    lines = text.splitlines()
    return {"path": path, "line": line, "excerpt": lines[line - 1].strip() if lines else ""}


def observed_item(category: str, kind: str, label: str, owner: str | None,
                  rule_id: str, path: str, text: str, offset: int, **extra: Any) -> dict[str, Any]:
    evidence = source_evidence(path, text, offset)
    return {
        "id": stable_behavior_id(category, path, evidence["line"], label),
        "kind": kind,
        "label": label,
        "component": owner,
        "authority": "observed",
        "evidence_class": "static_source",
        "rule_id": rule_id,
        "evidence": evidence,
        **extra,
    }


def enclosing_context(code: str, offset: int) -> tuple[str | None, str | None]:
    """Return cheaply-derived enclosing type/function using balanced source braces."""
    candidates: list[tuple[int, int, str, str]] = []
    declaration_re = re.compile(
        r"\b(class|struct|enum|actor|extension|func)\s+([A-Za-z_][A-Za-z0-9_]*)[^\n{]*\{"
    )
    for match in declaration_re.finditer(code, 0, offset + 1):
        depth = 1
        cursor = match.end()
        while cursor < len(code) and depth:
            if code[cursor] == "{":
                depth += 1
            elif code[cursor] == "}":
                depth -= 1
            cursor += 1
        end = cursor if depth == 0 else len(code)
        if match.start() <= offset < end:
            candidates.append((match.start(), end, match.group(1), match.group(2)))
    enclosing_type = None
    enclosing_function = None
    for _, _, declaration_kind, name in sorted(candidates):
        if declaration_kind == "func":
            enclosing_function = name
        else:
            enclosing_type = name
    return enclosing_type, enclosing_function


def extract_behavioral_source(path: str, text: str, component: str | None) -> dict[str, list[dict[str, Any]]]:
    code = strip_swift_noncode(text)
    domains: list[dict[str, Any]] = []
    main_actor_re = re.compile(
        r"@MainActor\s+(?:(?:public|package|internal|private|fileprivate|open|final|nonisolated)\s+)*"
        r"(?:class|struct|enum|protocol|actor|extension)\s+([A-Z][A-Za-z0-9_]*)"
    )
    for match in main_actor_re.finditer(code):
        domains.append(observed_item(
            "execution-domain", "main_actor", match.group(1), component,
            "swift.execution.main_actor", path, text, match.start()
        ))
    main_actor_names = {item["label"] for item in domains}
    actor_re = re.compile(
        r"(?m)^\s*(?:(?:public|package|internal|private|fileprivate|open|final|nonisolated)\s+)*"
        r"actor\s+([A-Z][A-Za-z0-9_]*)\b"
    )
    for match in actor_re.finditer(code):
        if match.group(1) not in main_actor_names:
            domains.append(observed_item(
                "execution-domain", "actor", match.group(1), component,
                "swift.execution.actor", path, text, match.start()
            ))
    queue_re = re.compile(
        r"(?m)^\s*(?:(?:public|package|internal|private|fileprivate)\s+)*"
        r"(?:var|let)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*DispatchQueue\s*\(\s*label\s*:"
    )
    source_lines = text.splitlines()
    for match in queue_re.finditer(code):
        evidence = source_evidence(path, text, match.start())
        original_line = source_lines[evidence["line"] - 1]
        label_match = re.search(r"label\s*:\s*\"([^\"]+)\"", original_line)
        runtime_label = label_match.group(1) if label_match else "unresolved"
        owner_type, _ = enclosing_context(code, match.start())
        domains.append(observed_item(
            "execution-domain", "dispatch_queue", match.group(1), component,
            "swift.execution.dispatch_queue", path, text, match.start(),
            owner_type=owner_type, runtime_label=runtime_label,
        ))
    domains.sort(key=lambda item: (item["evidence"]["path"], item["evidence"]["line"], item["id"]))

    task_sites: list[dict[str, Any]] = []
    task_patterns = [
        ("stored_task_handle", "swift.task.stored_handle", re.compile(
            r"(?m)^\s*(?:(?:public|package|internal|private|fileprivate|weak|unowned)\s+)*"
            r"(?:var|let)\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*Task\s*<"
        )),
        ("task_detached", "swift.task.detached", re.compile(r"\bTask\s*\.\s*detached\s*(?:\([^)]*\)\s*)?\{")),
        ("task", "swift.task.structured", re.compile(r"\bTask\s*(?:\([^)]*\)\s*)?\{")),
        ("task_cancellation", "swift.task.cancel", re.compile(
            r"\b([A-Za-z_][A-Za-z0-9_]*)\s*\??\s*\.\s*cancel\s*\("
        )),
    ]
    detached_ranges: list[tuple[int, int]] = []
    for kind, rule_id, pattern in task_patterns:
        for match in pattern.finditer(code):
            if kind == "task" and any(start <= match.start() < end for start, end in detached_ranges):
                continue
            if kind == "task_cancellation" and match.group(1) not in {
                item["label"] for item in task_sites if item["kind"] == "stored_task_handle"
            }:
                continue
            if kind == "task_detached":
                detached_ranges.append(match.span())
            label = match.group(1) if match.lastindex else ("Task.detached" if kind == "task_detached" else "Task")
            enclosing_type, enclosing_function = enclosing_context(code, match.start())
            task_sites.append(observed_item(
                "task-site", kind, label, component, rule_id, path, text, match.start(),
                enclosing_type=enclosing_type, enclosing_function=enclosing_function,
            ))
    task_sites.sort(key=lambda item: (item["evidence"]["path"], item["evidence"]["line"], item["id"]))

    resources: list[dict[str, Any]] = []
    stored_resource_specs = [
        ("websocket", "URLSessionWebSocketTask", "swift.resource.websocket.stored"),
        ("url_session", "URLSession", "swift.resource.url_session.stored"),
    ]
    for resource_kind, type_name, rule_id in stored_resource_specs:
        resource_re = re.compile(
            rf"(?m)^\s*(?:(?:public|package|internal|private|fileprivate|weak|unowned)\s+)*"
            rf"(?:var|let)\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*{type_name}\s*(\?)?(?![A-Za-z0-9_])"
        )
        for match in resource_re.finditer(code):
            owner_type, _ = enclosing_context(code, match.start())
            cardinality = (
                "one stored optional field per owner instance" if match.group(2)
                else "one stored field per owner instance"
            ) if owner_type else "unresolved"
            resources.append(observed_item(
                "resource", resource_kind, match.group(1), component,
                rule_id, path, text, match.start(), owner_type=owner_type,
                cardinality=cardinality,
            ))

    additional_resource_specs = [
        (
            "continuation",
            "swift.resource.continuation.stored",
            re.compile(
                r"(?m)^\s*(?:(?:public|package|internal|private|fileprivate)\s+)*"
                r"(?:var|let)\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*"
                r"Async(?:Throwing)?Stream\s*<[^\n>]+>\s*\.\s*Continuation\s*(\?)?"
            ),
        ),
        (
            "lock",
            "swift.resource.lock.stored",
            re.compile(
                r"(?m)^\s*(?:(?:public|package|internal|private|fileprivate)\s+)*"
                r"(?:var|let)\s+([A-Za-z_][A-Za-z0-9_]*)\s*"
                r"(?::\s*(?:NSLock|OSAllocatedUnfairLock)(?:\s*<[^\n>]+>)?\s*)?"
                r"=\s*(?:NSLock|OSAllocatedUnfairLock)\s*(?:<[^\n>]+>)?\s*\("
            ),
        ),
        (
            "timer",
            "swift.resource.timer.stored",
            re.compile(
                r"(?m)^\s*(?:(?:public|package|internal|private|fileprivate)\s+)*"
                r"(?:var|let)\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*Timer\s*(\?)?"
            ),
        ),
    ]
    for resource_kind, rule_id, resource_re in additional_resource_specs:
        for match in resource_re.finditer(code):
            owner_type, _ = enclosing_context(code, match.start())
            is_optional = bool(match.lastindex and match.group(match.lastindex) == "?")
            cardinality = (
                "one stored optional field per owner instance" if is_optional
                else "one stored field per owner instance"
            ) if owner_type else "unresolved"
            resources.append(observed_item(
                "resource", resource_kind, match.group(1), component,
                rule_id, path, text, match.start(), owner_type=owner_type,
                cardinality=cardinality,
            ))

    combine_re = re.compile(
        r"(?m)^\s*(?:(?:public|package|internal|private|fileprivate)\s+)*"
        r"(?:var|let)\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?::[^=\n]+)?=\s*"
        r"(?:PassthroughSubject|CurrentValueSubject)\s*<"
    )
    for match in combine_re.finditer(code):
        owner_type, _ = enclosing_context(code, match.start())
        resources.append(observed_item(
            "resource", "combine_subject", match.group(1), component,
            "swift.resource.combine_subject.stored", path, text, match.start(),
            owner_type=owner_type,
            cardinality="one stored field per owner instance" if owner_type else "unresolved",
        ))

    bytes_matches = list(re.finditer(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*\.\s*bytes\s*\(\s*for\s*:", code))
    if bytes_matches and "text/event-stream" in text:
        for match in bytes_matches:
            owner_type, _ = enclosing_context(code, match.start())
            resources.append(observed_item(
                "resource", "sse_stream", f"{match.group(1)}.bytes", component,
                "swift.resource.sse.bytes", path, text, match.start(), owner_type=owner_type,
                cardinality="unresolved",
            ))

    operations: list[dict[str, Any]] = []
    operation_specs = [
        ("start", "swift.lifecycle.start", "resume"),
        ("receive", "swift.lifecycle.receive", "receive"),
        ("send", "swift.lifecycle.send", "send"),
        ("close", "swift.lifecycle.close", "cancel"),
    ]
    for resource in resources:
        if resource["kind"] != "websocket":
            continue
        name = re.escape(resource["label"])
        for kind, rule_id, method in operation_specs:
            suffix = r"\s*\(\s*with\s*:" if kind == "close" else r"\s*\("
            pattern = re.compile(rf"\b{name}\s*\??\s*\.\s*{method}{suffix}")
            for match in pattern.finditer(code):
                owner_type, enclosing_function = enclosing_context(code, match.start())
                operations.append(observed_item(
                    "lifecycle-operation", kind, f"{resource['label']}.{method}", component,
                    rule_id, path, text, match.start(), resource_id=resource["id"],
                    resource_label=resource["label"], owner_type=owner_type,
                    enclosing_function=enclosing_function,
                ))

    resources_by_label = {item["label"]: item for item in resources}
    resource_operation_specs = {
        "lock": [
            ("acquire", "swift.lifecycle.acquire", "lock"),
            ("release", "swift.lifecycle.release", "unlock"),
        ],
        "continuation": [
            ("publish", "swift.lifecycle.continuation_publish", "yield"),
            ("close", "swift.lifecycle.continuation_close", "finish"),
        ],
        "timer": [("invalidate", "swift.lifecycle.invalidate", "invalidate")],
    }
    for resource in resources:
        for kind, rule_id, method in resource_operation_specs.get(resource["kind"], []):
            pattern = re.compile(
                rf"\b{re.escape(resource['label'])}\s*\??\s*\.\s*{method}\s*\("
            )
            for match in pattern.finditer(code):
                owner_type, enclosing_function = enclosing_context(code, match.start())
                operations.append(observed_item(
                    "lifecycle-operation", kind, f"{resource['label']}.{method}", component,
                    rule_id, path, text, match.start(), resource_id=resource["id"],
                    resource_label=resource["label"], owner_type=owner_type,
                    enclosing_function=enclosing_function,
                ))

    for resource in (item for item in resources if item["kind"] == "websocket"):
        factory_re = re.compile(
            rf"\b{re.escape(resource['label'])}\s*=\s*"
            r"([A-Za-z_][A-Za-z0-9_]*)\s*\.\s*webSocketTask\s*\("
        )
        for match in factory_re.finditer(code):
            session = resources_by_label.get(match.group(1))
            if session is None or session["kind"] != "url_session":
                continue
            owner_type, enclosing_function = enclosing_context(code, match.start())
            operations.append(observed_item(
                "lifecycle-operation", "create",
                f"{resource['label']} = {session['label']}.webSocketTask", component,
                "swift.lifecycle.create", path, text, match.start(),
                resource_id=resource["id"], resource_label=resource["label"],
                factory_resource_id=session["id"], owner_type=owner_type,
                enclosing_function=enclosing_function,
            ))
    for match in bytes_matches:
        session_resource = resources_by_label.get(match.group(1))
        if session_resource is not None:
            owner_type, enclosing_function = enclosing_context(code, match.start())
            operations.append(observed_item(
                "lifecycle-operation", "subscribe", f"{match.group(1)}.bytes", component,
                "swift.lifecycle.sse_subscribe", path, text, match.start(),
                resource_id=session_resource["id"], resource_label=session_resource["label"],
                owner_type=owner_type, enclosing_function=enclosing_function,
            ))
    sse_resources = [item for item in resources if item["kind"] == "sse_stream"]
    set_value_re = re.compile(r"\b[A-Za-z_][A-Za-z0-9_]*\s*\.\s*setValue\s*\(")
    for match in set_value_re.finditer(code):
        evidence = source_evidence(path, text, match.start())
        source_line = text.splitlines()[evidence["line"] - 1]
        if "Last-Event-ID" not in source_line or not sse_resources:
            continue
        owner_type, enclosing_function = enclosing_context(code, match.start())
        resource = sse_resources[0]
        operations.append(observed_item(
            "lifecycle-operation", "replay_cursor", "Last-Event-ID", component,
            "swift.lifecycle.sse_replay_cursor", path, text, match.start(),
            resource_id=resource["id"], resource_label=resource["label"],
            owner_type=owner_type, enclosing_function=enclosing_function,
        ))

    combine_resources = [item for item in resources if item["kind"] == "combine_subject"]
    for resource in combine_resources:
        publish_re = re.compile(rf"\b{re.escape(resource['label'])}\s*\.\s*send\s*\(")
        for match in publish_re.finditer(code):
            owner_type, enclosing_function = enclosing_context(code, match.start())
            operations.append(observed_item(
                "lifecycle-operation", "publish", f"{resource['label']}.send", component,
                "swift.lifecycle.publish", path, text, match.start(),
                resource_id=resource["id"], resource_label=resource["label"],
                owner_type=owner_type, enclosing_function=enclosing_function,
            ))
    for kind, rule_id, operator in [
        ("batch", "swift.lifecycle.batch", "collect"),
        ("hop", "swift.lifecycle.hop", "receive"),
    ]:
        for match in re.finditer(rf"\.\s*{operator}\s*\(", code):
            preceding = code[max(0, match.start() - 400):match.start()]
            candidates = [item for item in combine_resources if re.search(
                rf"\b{re.escape(item['label'])}\b", preceding
            )]
            if not candidates:
                continue
            resource = candidates[-1]
            owner_type, enclosing_function = enclosing_context(code, match.start())
            operations.append(observed_item(
                "lifecycle-operation", kind, f"{resource['label']}.{operator}", component,
                rule_id, path, text, match.start(), resource_id=resource["id"],
                resource_label=resource["label"], owner_type=owner_type,
                enclosing_function=enclosing_function,
            ))
    resources.sort(key=lambda item: (item["evidence"]["path"], item["evidence"]["line"], item["id"]))
    operations.sort(key=lambda item: (item["evidence"]["path"], item["evidence"]["line"], item["id"]))
    return {"execution_domains": domains, "task_sites": task_sites,
            "resources": resources, "operations": operations}


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
                "_text": text,
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


def build_behavior_model(files: list[dict[str, Any]]) -> dict[str, Any]:
    collections: dict[str, list[dict[str, Any]]] = {
        "execution_domains": [], "task_sites": [], "resources": [], "operations": []
    }
    for source in files:
        extracted = extract_behavioral_source(
            source["path"], source["_text"], source["component"]
        )
        for name in collections:
            collections[name].extend(extracted[name])
    for items in collections.values():
        items.sort(key=lambda item: (
            item["evidence"]["path"], item["evidence"]["line"], item["id"]
        ))

    resource_by_id = {item["id"]: item for item in collections["resources"]}
    clusters: dict[tuple[str, str], dict[str, Any]] = {}

    def cluster_for(component: str | None, owner_type: str | None) -> dict[str, Any] | None:
        if component is None and owner_type is None:
            return None
        key = (component or "unassigned", owner_type or component or "unresolved")
        if key not in clusters:
            digest = hashlib.sha256("\0".join(key).encode("utf-8")).hexdigest()[:12]
            clusters[key] = {
                "id": f"connectivity-pocket-{digest}",
                "component": component,
                "owner_type": owner_type,
                "resource_ids": [],
                "task_handle_ids": [],
                "operation_ids": [],
                "authority": "observed",
                "evidence_class": "static_source",
                "confidence": "mechanically_grouped",
                "derivation": (
                    "This is a static ownership/lifecycle cluster grouped by a source owner type "
                    "and component; it does not assert runtime overlap, threads, or live connection counts."
                ),
            }
        return clusters[key]

    for resource in collections["resources"]:
        cluster = cluster_for(resource["component"], resource.get("owner_type"))
        if cluster is not None:
            cluster["resource_ids"].append(resource["id"])
    for task in collections["task_sites"]:
        if task["kind"] != "stored_task_handle":
            continue
        cluster = cluster_for(task["component"], task.get("enclosing_type"))
        if cluster is not None:
            cluster["task_handle_ids"].append(task["id"])
    for operation in collections["operations"]:
        resource = resource_by_id.get(operation.get("resource_id"))
        owner_type = operation.get("owner_type") or (resource or {}).get("owner_type")
        cluster = cluster_for(operation["component"], owner_type)
        if cluster is not None:
            cluster["operation_ids"].append(operation["id"])

    pockets = []
    for key in sorted(clusters):
        pocket = clusters[key]
        for field in ("resource_ids", "task_handle_ids", "operation_ids"):
            pocket[field] = sorted(set(pocket[field]))
        if pocket["resource_ids"] or pocket["task_handle_ids"]:
            pockets.append(pocket)

    operation_by_id = {item["id"]: item for item in collections["operations"]}
    scenarios = []
    for pocket in pockets:
        operations = sorted(
            (operation_by_id[item_id] for item_id in pocket["operation_ids"]),
            key=lambda item: (item["evidence"]["path"], item["evidence"]["line"], item["id"]),
        )
        if not operations:
            continue
        scenarios.append({
            "id": pocket["id"].replace("connectivity-pocket", "scenario"),
            "pocket_id": pocket["id"],
            "component": pocket["component"],
            "owner_type": pocket["owner_type"],
            "operation_ids": [item["id"] for item in operations],
            "authority": "observed",
            "derivation": (
                "Evidence-backed source order within one static pocket; not a claim of runtime order."
            ),
        })
    return {**collections, "pockets": pockets, "scenarios": scenarios}


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
    behavior = build_behavior_model(files)
    unassigned = [item["path"] for item in files if item["component"] is None]
    model = {
        "schema_version": "1.0.0",
        "repository": config["repository"],
        "title": config["title"],
        "description": config["description"],
        "source_tree_sha256": source_hash,
        "evidence_metadata": {
            "class": "static_source",
            "rules": dict(sorted(BEHAVIOR_RULES.items())),
            "limitations": STATIC_SOURCE_LIMITATIONS,
        },
        "behavior": behavior,
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
