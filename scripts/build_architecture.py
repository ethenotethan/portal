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
INTERPLAY_OVERLAY_PATH = ROOT / "architecture/interplay/overlay.json"

DECLARATION_RE = re.compile(
    r"(?m)^[ \t]*(?:(?:public|package|internal|private|fileprivate|open|final|indirect|nonisolated)\s+)*"
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
    "swift.resource.rpc_pool.stored": "Stored property declared as a dictionary of CheckedContinuation (an in-flight request pool)",
    "swift.resource.on_device_model.stored": "Stored property declared as an MLX ModelContainer (an on-device language model)",
    "swift.resource.speech_synth.instantiated": "AVSpeechSynthesizer instantiated in a source owner (an on-device speech engine)",
    "swift.lifecycle.model_load": "loadContainer(...) invoked on an MLX model factory to load an on-device model",
    "swift.lifecycle.model_infer": "A ChatSession built over an on-device model container to run inference",
    "swift.lifecycle.pool_register": "A pending continuation registered into a CheckedContinuation pool before a request is sent",
    "swift.lifecycle.pool_resolve": "resume(...) invoked to settle a pending continuation from a CheckedContinuation pool",
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

# Boundary plane: external systems declared in architecture/config.json and
# matched by source signatures, plus data stores recognised by type-name
# convention with the persistence mechanism observed inside the type body.
BOUNDARY_RULES = {
    "swift.boundary.external_signature": (
        "A configured external-system signature (import, framework type, API family, or endpoint token) "
        "present in Swift code; string-scoped signatures match inside string literals only"
    ),
    "swift.store.declaration": "A class, struct, actor, or enum whose name ends in Store, Cache, Inventory, or Ledger",
    "swift.store.mechanism.file": "applicationSupportDirectory, cachesDirectory, or documentDirectory referenced inside the store type body, a same-file extension of it, or a same-file helper type named after it",
    "swift.store.mechanism.defaults": "UserDefaults or @AppStorage referenced inside the store type body, a same-file extension of it, or a same-file helper type named after it",
    "swift.store.mechanism.keychain": "A SecItem* call inside the store type body, a same-file extension of it, or a same-file helper type named after it",
    "swift.store.artifact_literal": "A string literal in the store type body, a same-file extension, or a same-file namesake helper that names a file, or a folder passed with isDirectory: true",
}
BOUNDARY_LIMITATIONS = [
    "External-system usage is attributed per configured signature; a system reached only through an unlisted API, or through a wrapper in another file, is not attributed to the caller.",
    "Store persistence mechanisms are observed inside the declaring type body, its same-file extensions, and same-file helper types whose name starts with the store name; persistence performed elsewhere is reported as unobserved.",
    "Swift raw string literals (#\"…\"#) are not lexed specially; a string-scoped signature or artifact name inside one may be missed or mis-scoped.",
]
EXTERNAL_CATEGORIES = {
    "backend", "network", "ml-runtime", "on-device-engine", "platform-service",
    "platform-storage", "platform-framework", "third-party-api",
}
STORE_DECLARATION_RE = re.compile(
    r"(?m)^[ \t]*(?:(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^)\n]*\))?|public|package|internal|private|fileprivate|open|final|indirect|nonisolated)\s+)*"
    r"(class|struct|actor|enum)\s+([A-Z][A-Za-z0-9_]*(?:Store|Cache|Inventory|Ledger))\b[^\n{]*\{"
)
STORE_MECHANISM_RULES = [
    ("file", "swift.store.mechanism.file",
     re.compile(r"\.(?:applicationSupportDirectory|cachesDirectory|documentDirectory)\b")),
    ("defaults", "swift.store.mechanism.defaults", re.compile(r"\bUserDefaults\b|@AppStorage\b")),
    ("keychain", "swift.store.mechanism.keychain", re.compile(r"\bSecItem(?:Add|CopyMatching|Update|Delete)\s*\(")),
]
ARTIFACT_FILE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*\.(?:json|jsonl|log|db|sqlite|plist|txt|md)$")
ARTIFACT_DIRECTORY_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
TYPE_BLOCK_RE = re.compile(r"\b(class|struct|actor|enum|extension)\s+([A-Z][A-Za-z0-9_]*)[^\n{]*\{")

# Interplay graph taxonomy: which extracted resource/operation kinds feed the
# verbose connection-pool ⋈ on-device-LLM graph, and the seam protocol both
# network transports conform to.
INTERPLAY_TRANSPORT_KINDS = {"websocket", "url_session", "rpc_pool"}
INTERPLAY_ENGINE_KINDS = {"on_device_model", "speech_synth"}
INTERPLAY_SUPPORT_KINDS = {"lock"}
INTERPLAY_RESOURCE_KINDS = (
    INTERPLAY_TRANSPORT_KINDS | INTERPLAY_ENGINE_KINDS | INTERPLAY_SUPPORT_KINDS
)
INTERPLAY_OP_KINDS = {"model_load", "model_infer", "pool_register", "pool_resolve"}
SEAM_PROTOCOL = "AgentBackend"
# The load-bearing resources the curated overlay must explain: the connection
# pool and every on-device engine. Adding one of these to Swift source without a
# matching overlay entry (or leaving an entry whose resource was removed) fails
# the build — the bidirectional generation gate.
GATED_INTERPLAY_KINDS = {"rpc_pool", "on_device_model", "speech_synth"}
# The transport⋈app event bus (a Combine subject declared on the seam) and the
# request-leg constructions — JSON-RPC method endpoints and the SSE replay
# cursor. These are drawn and deep-linked but NOT gated: the curated overlay
# stays focused on the load-bearing pools/engines above, per design.
INTERPLAY_BUS_RESOURCE_KIND = "combine_subject"
# A JSON-RPC method invocation: `call("session.create", …)` / `callWithRetry("…")`.
RPC_METHOD_RE = re.compile(r"\bcall(?:WithRetry)?\s*\(\s*\"([a-z][A-Za-z0-9_.]*)\"")
# A REST query: an HTTP verb literal paired with the first path string literal in
# the same call — covers both `("GET", "api/workflows/runs?…")` and
# `("POST", sessionPath(threadKey, "/messages"))`.
HTTP_METHOD_RE = re.compile(
    r"\"(GET|POST|PUT|DELETE|PATCH)\"\s*,\s*[^\n]*?\"([^\"\n]+)\""
)


def rest_namespace(path: str) -> str:
    """Coarse namespace for a REST path literal: the first meaningful segment.

    `api/workflows/runs?limit=…` → `workflows`, `/messages` → `messages`. Kept
    deterministic and purely lexical so the endpoint rollup is byte-stable.
    """
    cleaned = path.strip("/").split("?")[0]
    segments = [seg for seg in cleaned.split("/") if seg and "\\(" not in seg]
    if not segments:
        return "session"
    if segments[0] == "api" and len(segments) > 1:
        return segments[1]
    return segments[0]


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


def enclosing_function_range(code: str, offset: int) -> tuple[int, int] | None:
    """Return the byte range of the innermost `func` body enclosing offset."""
    declaration_re = re.compile(r"\bfunc\s+[A-Za-z_][A-Za-z0-9_]*[^\n{]*\{")
    best: tuple[int, int] | None = None
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
        if match.start() <= offset < end and (best is None or match.start() > best[0]):
            best = (match.start(), end)
    return best


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
        r"(?m)^[ \t]*(?:(?:public|package|internal|private|fileprivate|open|final|nonisolated)\s+)*"
        r"actor\s+([A-Z][A-Za-z0-9_]*)\b"
    )
    for match in actor_re.finditer(code):
        if match.group(1) not in main_actor_names:
            domains.append(observed_item(
                "execution-domain", "actor", match.group(1), component,
                "swift.execution.actor", path, text, match.start()
            ))
    queue_re = re.compile(
        r"(?m)^[ \t]*(?:(?:public|package|internal|private|fileprivate)\s+)*"
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
            r"(?m)^[ \t]*(?:(?:public|package|internal|private|fileprivate|weak|unowned)\s+)*"
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
            rf"(?m)^[ \t]*(?:(?:public|package|internal|private|fileprivate|weak|unowned)\s+)*"
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
                r"(?m)^[ \t]*(?:(?:public|package|internal|private|fileprivate)\s+)*"
                r"(?:var|let)\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*"
                r"Async(?:Throwing)?Stream\s*<[^\n>]+>\s*\.\s*Continuation\s*(\?)?"
            ),
        ),
        (
            "lock",
            "swift.resource.lock.stored",
            re.compile(
                r"(?m)^[ \t]*(?:(?:public|package|internal|private|fileprivate)\s+)*"
                r"(?:var|let)\s+([A-Za-z_][A-Za-z0-9_]*)\s*"
                r"(?::\s*(?:NSLock|OSAllocatedUnfairLock)(?:\s*<[^\n>]+>)?\s*)?"
                r"=\s*(?:NSLock|OSAllocatedUnfairLock)\s*(?:<[^\n>]+>)?\s*\("
            ),
        ),
        (
            "timer",
            "swift.resource.timer.stored",
            re.compile(
                r"(?m)^[ \t]*(?:(?:public|package|internal|private|fileprivate)\s+)*"
                r"(?:var|let)\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*Timer\s*(\?)?"
            ),
        ),
        (
            "rpc_pool",
            "swift.resource.rpc_pool.stored",
            re.compile(
                r"(?m)^[ \t]*(?:(?:public|package|internal|private|fileprivate)\s+)*"
                r"(?:var|let)\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*"
                r"\[[^\]\n]*:\s*CheckedContinuation\s*<[^\n]*"
            ),
        ),
        (
            "on_device_model",
            "swift.resource.on_device_model.stored",
            re.compile(
                r"(?m)^[ \t]*(?:(?:public|package|internal|private|fileprivate)\s+)*"
                r"(?:var|let)\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*ModelContainer\s*(\?)?(?![A-Za-z0-9_])"
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
        r"(?m)^[ \t]*(?:(?:public|package|internal|private|fileprivate)\s+)*"
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

    for match in re.finditer(r"\bAVSpeechSynthesizer\s*\(", code):
        owner_type, _ = enclosing_context(code, match.start())
        resources.append(observed_item(
            "resource", "speech_synth", "AVSpeechSynthesizer", component,
            "swift.resource.speech_synth.instantiated", path, text, match.start(),
            owner_type=owner_type,
            cardinality="one on-device synthesizer per owner instance" if owner_type else "unresolved",
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
    # On-device model lifecycle: model load + inference, each flagged when it
    # runs inside a Task.detached closure (the MLX engines are @MainActor but
    # must move the heavy Metal work off the actor). The detached ranges are the
    # balanced-brace bodies of every Task.detached in the file.
    detached_closure_ranges: list[tuple[int, int]] = []
    for match in re.finditer(r"\bTask\s*\.\s*detached\s*(?:\([^)]*\)\s*)?\{", code):
        depth = 1
        cursor = match.end()
        while cursor < len(code) and depth:
            if code[cursor] == "{":
                depth += 1
            elif code[cursor] == "}":
                depth -= 1
            cursor += 1
        detached_closure_ranges.append((match.end(), cursor))

    def runs_detached(offset: int) -> bool:
        return any(start <= offset < end for start, end in detached_closure_ranges)

    model_resources = [item for item in resources if item["kind"] == "on_device_model"]
    if model_resources:
        model_resource = model_resources[0]
        model_operation_specs = [
            ("model_load", "swift.lifecycle.model_load",
             re.compile(r"\bLLMModelFactory[A-Za-z0-9_.]*\.\s*loadContainer\s*\("),
             "LLMModelFactory.loadContainer"),
            ("model_infer", "swift.lifecycle.model_infer",
             re.compile(r"\bChatSession\s*\("), "ChatSession.respond"),
        ]
        for kind, rule_id, pattern, label in model_operation_specs:
            for match in pattern.finditer(code):
                owner_type, enclosing_function = enclosing_context(code, match.start())
                operations.append(observed_item(
                    "lifecycle-operation", kind, label, component,
                    rule_id, path, text, match.start(),
                    resource_id=model_resource["id"], resource_label=model_resource["label"],
                    owner_type=owner_type, enclosing_function=enclosing_function,
                    detached_off_main=runs_detached(match.start()),
                ))

    for resource in (item for item in resources if item["kind"] == "rpc_pool"):
        register_re = re.compile(rf"\b{re.escape(resource['label'])}\s*\[[^\]\n]+\]\s*=(?!=)")
        for match in register_re.finditer(code):
            owner_type, enclosing_function = enclosing_context(code, match.start())
            operations.append(observed_item(
                "lifecycle-operation", "pool_register", f"{resource['label']}[…] =", component,
                "swift.lifecycle.pool_register", path, text, match.start(),
                resource_id=resource["id"], resource_label=resource["label"],
                owner_type=owner_type, enclosing_function=enclosing_function,
            ))
        # A `.resume(` is a pool resolve only when it settles a continuation
        # drawn from this pool — approximated deterministically as a resume whose
        # innermost enclosing function also references the pool field. This
        # excludes the unrelated AsyncStream/ping continuation resumes elsewhere
        # in the same file.
        pool_label_re = re.compile(rf"\b{re.escape(resource['label'])}\b")
        for match in re.finditer(r"\.\s*resume\s*\(", code):
            func_range = enclosing_function_range(code, match.start())
            if not func_range or not pool_label_re.search(code, func_range[0], func_range[1]):
                continue
            owner_type, enclosing_function = enclosing_context(code, match.start())
            operations.append(observed_item(
                "lifecycle-operation", "pool_resolve", "resume", component,
                "swift.lifecycle.pool_resolve", path, text, match.start(),
                resource_id=resource["id"], resource_label=resource["label"],
                owner_type=owner_type, enclosing_function=enclosing_function,
            ))

    resources.sort(key=lambda item: (item["evidence"]["path"], item["evidence"]["line"], item["id"]))
    operations.sort(key=lambda item: (item["evidence"]["path"], item["evidence"]["line"], item["id"]))
    return {"execution_domains": domains, "task_sites": task_sites,
            "resources": resources, "operations": operations}


def balanced_block_end(code: str, open_brace_end: int) -> int:
    """Return the offset just past the `}` that closes the block opened before open_brace_end."""
    depth = 1
    cursor = open_brace_end
    while cursor < len(code) and depth:
        if code[cursor] == "{":
            depth += 1
        elif code[cursor] == "}":
            depth -= 1
        cursor += 1
    return cursor if depth == 0 else len(code)


def swift_string_literals(text: str) -> list[tuple[int, int, str]]:
    """Return (content_start, content_end, content) for every string literal in code.

    Follows the same lexical states as strip_swift_noncode—literals inside comments
    are not reported, comment markers inside literals do not end them, and an
    unterminated single-line literal ends at the newline—but advances by token
    rather than by character.
    """
    token_re = re.compile(r'//|/\*|"""|"')
    block_re = re.compile(r"/\*|\*/")
    body_re = re.compile(r'(?:[^"\\\n]|\\.)*')
    literals: list[tuple[int, int, str]] = []
    length = len(text)
    index = 0
    while index < length:
        token = token_re.search(text, index)
        if token is None:
            break
        position = token.end()
        kind = token.group(0)
        if kind == "//":
            newline = text.find("\n", position)
            index = length if newline == -1 else newline
        elif kind == "/*":
            depth = 1
            while depth:
                marker = block_re.search(text, position)
                if marker is None:
                    position = length
                    break
                depth += 1 if marker.group(0) == "/*" else -1
                position = marker.end()
            index = position
        elif kind == '"""':
            close = text.find('"""', position)
            content_end = length if close == -1 else close
            literals.append((position, content_end, text[position:content_end]))
            index = length if close == -1 else close + 3
        else:
            body = body_re.match(text, position)
            content_end = body.end() if body else position
            if content_end < length and text[content_end] == '"':
                literals.append((position, content_end, text[position:content_end]))
                index = content_end + 1
            else:
                index = content_end
    return literals


def normalize_signature(signature: Any) -> tuple[str, str]:
    """Return (pattern, scope) for a configured external-system signature."""
    if isinstance(signature, str) and signature:
        return signature, "code"
    if isinstance(signature, dict) and isinstance(signature.get("pattern"), str) and signature["pattern"]:
        scope = signature.get("scope", "code")
        if scope in {"code", "strings"}:
            return signature["pattern"], str(scope)
    raise ArchitectureError(f"invalid external-system signature: {signature!r}")


def validate_external_systems(config: dict[str, Any]) -> None:
    systems = config.get("external_systems", [])
    if not isinstance(systems, list):
        raise ArchitectureError("config external_systems must be an array")
    components = {str(item["id"]): item for item in config["components"]}
    seen: set[str] = set()
    persistence_seen: set[str] = set()
    for system in systems:
        if not isinstance(system, dict):
            raise ArchitectureError("external system entries must be objects")
        for key in ("id", "label", "category", "description"):
            if not isinstance(system.get(key), str) or not system[key]:
                raise ArchitectureError(f"external system {system.get('id')!r} needs a non-empty {key}")
        if system["id"] in seen:
            raise ArchitectureError(f"duplicate external system id {system['id']}")
        seen.add(system["id"])
        if system["category"] not in EXTERNAL_CATEGORIES:
            raise ArchitectureError(f"external system {system['id']} has unknown category {system['category']}")
        component = system.get("component")
        if component is not None and not components.get(component, {}).get("external"):
            raise ArchitectureError(f"external system {system['id']} maps to a non-external component {component!r}")
        persistence = system.get("persistence")
        if persistence is not None:
            if persistence not in {"file", "defaults", "keychain"}:
                raise ArchitectureError(f"external system {system['id']} has unknown persistence {persistence!r}")
            if persistence in persistence_seen:
                raise ArchitectureError(f"persistence {persistence!r} is claimed by more than one external system")
            persistence_seen.add(persistence)
        signatures = system.get("signatures")
        if not isinstance(signatures, list) or not signatures:
            raise ArchitectureError(f"external system {system['id']} needs at least one signature")
        for signature in signatures:
            pattern, _ = normalize_signature(signature)
            try:
                re.compile(pattern, re.MULTILINE)
            except re.error as error:
                raise ArchitectureError(f"external system {system['id']} has an invalid signature {pattern!r}: {error}") from error


def masked_code(source: dict[str, Any]) -> str:
    """Comment/string-masked code for a read_sources() entry, computed once per file."""
    if "_code" not in source:
        source["_code"] = strip_swift_noncode(source["_text"])
    return source["_code"]


def compiled_signature_scans(systems: list[dict[str, Any]]) -> list[tuple[str, str, str, re.Pattern[str]]]:
    """Return (system_id, pattern, scope, compiled regex) for every configured signature."""
    scans: list[tuple[str, str, str, re.Pattern[str]]] = []
    for system in systems:
        for signature in system["signatures"]:
            pattern, scope = normalize_signature(signature)
            scans.append((str(system["id"]), pattern, scope, re.compile(pattern, re.MULTILINE)))
    return scans


def extract_external_usage(path: str, text: str, component: str | None,
                           systems: list[dict[str, Any]], code: str | None = None,
                           scans: list[tuple[str, str, str, re.Pattern[str]]] | None = None
                           ) -> list[dict[str, Any]]:
    """Match every configured external-system signature against one source file."""
    code = strip_swift_noncode(text) if code is None else code
    scans = compiled_signature_scans(systems) if scans is None else scans
    literals: list[tuple[int, int, str]] | None = None
    hits: list[dict[str, Any]] = []
    for system_id, pattern, scope, regex in scans:
        if scope == "code":
            for match in regex.finditer(code):
                hits.append(observed_item(
                    "external-usage", "signature", match.group(0).strip(), component,
                    "swift.boundary.external_signature", path, text, match.start(),
                    system=system_id, signature=pattern, scope=scope,
                ))
            continue
        if literals is None:
            literals = swift_string_literals(text)
        for start, _, content in literals:
            for match in regex.finditer(content):
                hits.append(observed_item(
                    "external-usage", "signature", match.group(0).strip(), component,
                    "swift.boundary.external_signature", path, text, start + match.start(),
                    system=system_id, signature=pattern, scope=scope,
                ))
    hits.sort(key=lambda item: (item["evidence"]["path"], item["evidence"]["line"], item["system"], item["id"]))
    return hits


def build_externals_model(files: list[dict[str, Any]], config: dict[str, Any]) -> dict[str, Any]:
    configured = config.get("external_systems", [])
    scans = compiled_signature_scans(configured)
    usage: list[dict[str, Any]] = []
    for source in files:
        usage.extend(extract_external_usage(
            source["path"], source["_text"], source["component"], configured,
            code=masked_code(source), scans=scans,
        ))
    by_system: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for hit in usage:
        by_system[hit["system"]].append(hit)

    systems: list[dict[str, Any]] = []
    edges: list[dict[str, Any]] = []
    for entry in configured:
        system_id = str(entry["id"])
        hits = by_system.get(system_id, [])
        if not hits:
            raise ArchitectureError(
                f"external system {system_id} matched no source signature; fix its signatures or remove it"
            )
        per_component: dict[str, list[dict[str, Any]]] = defaultdict(list)
        for hit in hits:
            per_component[hit["component"] or "unassigned"].append(hit)
        usage_summary: list[dict[str, Any]] = []
        for component_id, items in sorted(per_component.items()):
            paths = sorted({item["evidence"]["path"] for item in items})
            usage_summary.append({
                "component": component_id,
                "hit_count": len(items),
                "files": paths[:12],
                "evidence": [
                    {**item["evidence"], "rule_id": item["rule_id"], "signature": item["signature"], "scope": item["scope"]}
                    for item in items[:8]
                ],
            })
            if component_id != "unassigned":
                edges.append({
                    "source": component_id,
                    "target": system_id,
                    "type": "uses",
                    "authority": "observed",
                    "description": f"{len(items)} signature hit(s) across {len(paths)} file(s).",
                    "evidence": paths[:12],
                    "weight": len(items),
                })
        systems.append({
            "id": system_id,
            "label": str(entry["label"]),
            "category": str(entry["category"]),
            "description": str(entry["description"]),
            "description_authority": "specified",
            "protocol": entry.get("protocol"),
            "component": entry.get("component"),
            "persistence": entry.get("persistence"),
            "paths": sorted({hit["evidence"]["path"] for hit in hits}),
            "signatures": [
                {"pattern": pattern, "scope": scope}
                for pattern, scope in (normalize_signature(item) for item in entry["signatures"])
            ],
            "hit_count": len(hits),
            "file_count": len({hit["evidence"]["path"] for hit in hits}),
            "component_ids": sorted(key for key in per_component if key != "unassigned"),
            "usage": usage_summary,
            "authority": "observed",
            "evidence_class": "static_source",
        })
    return {"systems": systems, "edges": edges}


def extract_store_declarations(path: str, text: str, component: str | None,
                               code: str | None = None) -> list[dict[str, Any]]:
    """Recognise store/cache types and observe how each persists.

    Mechanisms and artifact names are looked for in the declaring type body, in
    same-file `extension <Name>` bodies, and in same-file helper types whose
    name starts with the store name (e.g. `SkillStoreDisk` for `SkillStore`).
    """
    code = strip_swift_noncode(text) if code is None else code
    declarations = list(STORE_DECLARATION_RE.finditer(code))
    if not declarations:
        return []
    literals = swift_string_literals(text)
    blocks = [
        (match.group(1), match.group(2), match.end(), balanced_block_end(code, match.end()))
        for match in TYPE_BLOCK_RE.finditer(code)
    ]
    stores: list[dict[str, Any]] = []
    for match in declarations:
        declaration_kind, name = match.group(1), match.group(2)
        body_start = match.end()
        body_end = balanced_block_end(code, body_start)
        ranges: list[tuple[int, int, str | None]] = [(body_start, body_end, None)]
        for block_kind, block_name, block_start, block_end in blocks:
            if block_start == body_start:
                continue
            if block_kind == "extension" and block_name == name:
                ranges.append((block_start, block_end, f"extension {name}"))
            elif block_kind != "extension" and block_name != name and block_name.startswith(name):
                ranges.append((block_start, block_end, f"helper {block_name}"))

        mechanisms: dict[str, dict[str, Any]] = {}
        artifacts: dict[str, dict[str, Any]] = {}
        for range_start, range_end, via in ranges:
            body = code[range_start:range_end]
            for mechanism_kind, rule_id, pattern in STORE_MECHANISM_RULES:
                for hit in pattern.finditer(body):
                    item = observed_item(
                        "store-mechanism", mechanism_kind, hit.group(0).strip(), component,
                        rule_id, path, text, range_start + hit.start(), store=name, via=via,
                    )
                    mechanisms.setdefault(item["id"], item)
            for start, end, content in literals:
                if start < range_start or end > range_end:
                    continue
                if ARTIFACT_FILE_RE.match(content):
                    artifact_kind = "file"
                elif ARTIFACT_DIRECTORY_RE.match(content) and re.match(
                    r"\s*,\s*isDirectory\s*:\s*true", code[end + 1:end + 40]
                ):
                    artifact_kind = "directory"
                else:
                    continue
                item = observed_item(
                    "store-artifact", artifact_kind, content, component,
                    "swift.store.artifact_literal", path, text, start - 1, store=name, via=via,
                )
                artifacts.setdefault(item["id"], item)

        mechanism_items = sorted(mechanisms.values(), key=lambda item: (item["evidence"]["line"], item["kind"], item["id"]))
        artifact_items = sorted(artifacts.values(), key=lambda item: (item["evidence"]["line"], item["label"], item["id"]))
        persistence = sorted({item["kind"] for item in mechanism_items}) or ["unobserved"]
        stores.append({
            **observed_item("store", declaration_kind, name, component,
                            "swift.store.declaration", path, text, match.start(1)),
            "type_name": name,
            "persistence": persistence,
            "mechanisms": mechanism_items,
            "artifacts": artifact_items,
            "scanned": [via or f"{declaration_kind} {name}" for _, _, via in ranges],
            "derivation": (
                "Persistence APIs and artifact names are observed in the declaring type body, its same-file "
                "extensions, and same-file helper types named after it; 'unobserved' means none of those contain "
                "a supported persistence API (in-memory, or delegated elsewhere)."
            ),
        })
    return stores


def build_stores_model(files: list[dict[str, Any]]) -> dict[str, Any]:
    items: list[dict[str, Any]] = []
    for source in files:
        items.extend(extract_store_declarations(
            source["path"], source["_text"], source["component"], code=masked_code(source)
        ))
    items.sort(key=lambda item: (item["evidence"]["path"], item["evidence"]["line"], item["id"]))
    by_persistence: dict[str, int] = defaultdict(int)
    for item in items:
        for kind in item["persistence"]:
            by_persistence[kind] += 1
    return {"items": items, "count": len(items), "by_persistence": dict(sorted(by_persistence.items()))}


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
    validate_external_systems(config)


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


def build_interplay_graph(
    files: list[dict[str, Any]], behavior: dict[str, Any]
) -> dict[str, Any]:
    """Deterministic connection-pool ⋈ on-device-LLM graph over extracted behavior.

    Nodes are owner types, the transport/engine resources they own, the lifecycle
    operations that drive those resources, the AgentBackend seam, and the hub type
    that wires a network transport to an on-device engine. Edges are `structure`
    (owns), `lifecycle` (operates / acts-on), and `interplay` (the cross-domain
    wiring). Everything is derived from source-backed evidence and sorted, so the
    graph is byte-stable for the invariants layered on top.
    """
    resources = [
        item
        for item in behavior["resources"]
        if item.get("owner_type") and item["kind"] in INTERPLAY_RESOURCE_KINDS
    ]
    operations = [
        item for item in behavior["operations"] if item["kind"] in INTERPLAY_OP_KINDS
    ]

    # Type-declaration index (name -> earliest source site) for deep-linking the
    # owner/seam/hub nodes to the type that declares them, and a file-by-type map
    # for reference-based interplay detection. Both anchor on the earliest source
    # site rather than first-seen so the result is order-independent.
    decl_index: dict[str, dict[str, Any]] = {}
    file_by_type: dict[str, dict[str, Any]] = {}
    for source in files:
        code = strip_swift_noncode(source["_text"])
        for match in DECLARATION_RE.finditer(code):
            name = match.group(1)
            line = code.count("\n", 0, match.start()) + 1
            entry = {"path": source["path"], "line": line, "component": source["component"]}
            current = decl_index.get(name)
            if current is None or (entry["path"], entry["line"]) < (current["path"], current["line"]):
                decl_index[name] = entry
        for name in source["declarations"]:
            existing = file_by_type.get(name)
            if existing is None or source["path"] < existing["path"]:
                file_by_type[name] = source

    candidate_transport_owners = {
        (item["component"], item["owner_type"])
        for item in resources
        if item["kind"] in INTERPLAY_TRANSPORT_KINDS
    }
    engine_owners = {
        (item["component"], item["owner_type"])
        for item in resources
        if item["kind"] in INTERPLAY_ENGINE_KINDS
    }
    engine_owner_types = {owner_type for _, owner_type in engine_owners}

    # A transport owner belongs to the interplay story only when it conforms to
    # the AgentBackend seam — that is what distinguishes an agent connection-pool
    # client (GatewayClient, CentaurClient, HermesStandardClient) from a one-shot
    # URLSession content fetcher. Support resources (locks) are kept only when
    # co-owned by an included transport/engine owner, so an unrelated cache lock
    # never enters the graph.
    transport_owners = {
        (component, owner_type)
        for component, owner_type in candidate_transport_owners
        if (source := file_by_type.get(owner_type)) is not None
        and SEAM_PROTOCOL in source["identifiers"]
    }
    transport_owner_types = {owner_type for _, owner_type in transport_owners}
    included_owner_keys = transport_owners | engine_owners

    def resource_included(item: dict[str, Any]) -> bool:
        return (item["component"], item["owner_type"]) in included_owner_keys

    resources = [item for item in resources if resource_included(item)]
    operations = [
        item
        for item in operations
        if (item["component"], item.get("owner_type")) in included_owner_keys
    ]

    nodes: dict[str, dict[str, Any]] = {}
    edges: set[tuple[str, str, str, str]] = set()

    def owner_node_id(component: str | None, owner_type: str) -> str:
        return f"owner:{component or 'unassigned'}:{owner_type}"

    def add_owner(component: str | None, owner_type: str, role: str) -> str:
        node_id = owner_node_id(component, owner_type)
        node = nodes.get(node_id)
        if node is None:
            decl = decl_index.get(owner_type)
            node = nodes[node_id] = {
                "id": node_id,
                "kind": "owner",
                "label": owner_type,
                "component": component,
                "path": decl["path"] if decl else None,
                "line": decl["line"] if decl else 0,
                "roles": set(),
            }
        node["roles"].add(role)
        return node_id

    def role_for_kind(kind: str) -> str:
        if kind in INTERPLAY_ENGINE_KINDS:
            return "engine"
        if kind in INTERPLAY_TRANSPORT_KINDS:
            return "transport"
        return "support"

    resource_node_by_id: dict[str, str] = {}
    for resource in resources:
        add_owner(resource["component"], resource["owner_type"], role_for_kind(resource["kind"]))
        node_id = f"resource:{resource['id']}"
        nodes[node_id] = {
            "id": node_id,
            "kind": "resource",
            "sub_kind": resource["kind"],
            "label": resource["label"],
            "component": resource["component"],
            "owner_type": resource.get("owner_type"),
            "path": resource["evidence"]["path"],
            "line": resource["evidence"]["line"],
        }
        resource_node_by_id[resource["id"]] = node_id
        edges.add((owner_node_id(resource["component"], resource["owner_type"]), node_id, "structure", "owns"))

    for operation in operations:
        node_id = f"operation:{operation['id']}"
        nodes[node_id] = {
            "id": node_id,
            "kind": "operation",
            "sub_kind": operation["kind"],
            "label": operation["label"],
            "component": operation["component"],
            "owner_type": operation.get("owner_type"),
            "resource_id": operation.get("resource_id"),
            "detached_off_main": operation.get("detached_off_main", False),
            "path": operation["evidence"]["path"],
            "line": operation["evidence"]["line"],
        }
        owner_type = operation.get("owner_type")
        if owner_type:
            role = "engine" if operation["kind"] in {"model_load", "model_infer"} else "transport"
            add_owner(operation["component"], owner_type, role)
            edges.add((owner_node_id(operation["component"], owner_type), node_id, "lifecycle", "operates"))
        target_resource = resource_node_by_id.get(operation.get("resource_id"))
        if target_resource:
            edges.add((node_id, target_resource, "lifecycle", operation["kind"]))

    seam_node_id: str | None = None
    seam_decl = decl_index.get(SEAM_PROTOCOL)
    if seam_decl is not None:
        seam_node_id = f"seam:{SEAM_PROTOCOL}"
        nodes[seam_node_id] = {
            "id": seam_node_id,
            "kind": "seam",
            "label": SEAM_PROTOCOL,
            "component": seam_decl["component"],
            "path": seam_decl["path"],
            "line": seam_decl["line"],
        }
        # A transport owner whose source references the seam protocol conforms to
        # it — the structural half of the interplay (both transports are backends).
        for component, owner_type in sorted(transport_owners):
            source = file_by_type.get(owner_type)
            if source and SEAM_PROTOCOL in source["identifiers"]:
                edges.add((owner_node_id(component, owner_type), seam_node_id, "interplay", "conforms"))

    # Hub detection: the construction that makes a network transport and an
    # on-device engine interplay. A hub is the specific type whose own body
    # references the AgentBackend seam AND an on-device engine owner, without
    # itself being one of those owners. Resolving to the enclosing type (via
    # balanced braces) rather than the file's first declaration keeps an unrelated
    # top-level enum or protocol in the same file from being mislabelled the hub.
    included_owner_types = transport_owner_types | engine_owner_types
    hub_reference_types = {SEAM_PROTOCOL} | engine_owner_types
    for source in sorted(files, key=lambda item: item["path"]):
        identifiers = set(source["identifiers"])
        if SEAM_PROTOCOL not in identifiers or not identifiers & engine_owner_types:
            continue
        code = strip_swift_noncode(source["_text"])
        for match in DECLARATION_RE.finditer(code):
            hub_type = match.group(1)
            if hub_type in included_owner_types:
                continue
            brace_start = code.find("{", match.end())
            if brace_start == -1:
                continue
            depth = 0
            cursor = brace_start
            while cursor < len(code):
                if code[cursor] == "{":
                    depth += 1
                elif code[cursor] == "}":
                    depth -= 1
                    if depth == 0:
                        cursor += 1
                        break
                cursor += 1
            body = code[match.start():cursor]
            body_refs = {token for token in hub_reference_types if re.search(rf"\b{re.escape(token)}\b", body)}
            if SEAM_PROTOCOL not in body_refs or not body_refs & engine_owner_types:
                continue
            hub_node_id = f"hub:{hub_type}"
            nodes[hub_node_id] = {
                "id": hub_node_id,
                "kind": "hub",
                "label": hub_type,
                "component": source["component"],
                "path": source["path"],
                "line": code.count("\n", 0, match.start()) + 1,
            }
            if seam_node_id:
                edges.add((hub_node_id, seam_node_id, "interplay", "binds"))
            for component, owner_type in sorted(transport_owners):
                if re.search(rf"\b{re.escape(owner_type)}\b", body):
                    edges.add((hub_node_id, owner_node_id(component, owner_type), "interplay", "drives-transport"))
            for component, owner_type in sorted(engine_owners):
                if owner_type in body_refs:
                    edges.add((hub_node_id, owner_node_id(component, owner_type), "interplay", "drives-engine"))

    # ── Request leg + push leg (the full-duplex construction over one socket).
    # The RPC `call(method:)` is the id-correlated request half, drawn as
    # namespace-rollup endpoints routed through the pool; the seam's
    # `eventStream` is the uncorrelated push half fanned out to subscribers. The
    # SSE replay cursor is the REST/SSE analog of the pool. None of this is gated.
    transport_owner_by_type = {owner_type: component for component, owner_type in transport_owners}
    special_types = {node["label"] for node in nodes.values() if node["kind"] in {"owner", "seam", "hub"}}

    # Event bus: anchored on the seam's `eventStream` member — the contract every
    # transport provides — with providers, publish operations, and subscribers.
    bus_node_id: str | None = None
    seam_source = file_by_type.get(SEAM_PROTOCOL)
    if seam_node_id is not None and seam_source is not None:
        seam_code = strip_swift_noncode(seam_source["_text"])
        bus_match = re.search(
            r"\bvar\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*"
            r"(?:PassthroughSubject|CurrentValueSubject)\s*<",
            seam_code,
        )
        if bus_match is not None:
            bus_field = bus_match.group(1)
            bus_node_id = f"bus:{SEAM_PROTOCOL}.{bus_field}"
            nodes[bus_node_id] = {
                "id": bus_node_id,
                "kind": "resource",
                "sub_kind": "event_bus",
                "label": bus_field,
                "component": seam_source["component"],
                "owner_type": SEAM_PROTOCOL,
                "path": seam_source["path"],
                "line": seam_code.count("\n", 0, bus_match.start()) + 1,
            }
            edges.add((seam_node_id, bus_node_id, "structure", "declares"))
            for component, owner_type in sorted(transport_owners):
                edges.add((owner_node_id(component, owner_type), bus_node_id, "structure", "provides"))
            for op in behavior["operations"]:
                if op["kind"] != "publish" or (op["component"], op.get("owner_type")) not in transport_owners:
                    continue
                pub_id = f"operation:{op['id']}"
                nodes[pub_id] = {
                    "id": pub_id, "kind": "operation", "sub_kind": "bus_publish",
                    "label": op["label"], "component": op["component"],
                    "owner_type": op.get("owner_type"),
                    "detached_off_main": op.get("detached_off_main", False),
                    "path": op["evidence"]["path"], "line": op["evidence"]["line"],
                }
                edges.add((owner_node_id(op["component"], op["owner_type"]), pub_id, "lifecycle", "operates"))
                edges.add((pub_id, bus_node_id, "lifecycle", "publish"))
            # Subscribers: every declared type whose body references `.eventStream`
            # and is neither a transport that provides one nor an owner/seam/hub.
            subscriber_types: dict[str, dict[str, Any]] = {}
            for source in sorted(files, key=lambda item: item["path"]):
                if ".eventStream" not in source["_text"]:
                    continue
                code = strip_swift_noncode(source["_text"])
                for match in re.finditer(r"\.\s*eventStream\b", code):
                    owner_type, _ = enclosing_context(code, match.start())
                    if not owner_type or owner_type in transport_owner_by_type or owner_type in special_types:
                        continue
                    if owner_type not in subscriber_types:
                        decl = decl_index.get(owner_type)
                        subscriber_types[owner_type] = {
                            "path": decl["path"] if decl else source["path"],
                            "line": decl["line"] if decl else code.count("\n", 0, match.start()) + 1,
                        }
            for sub_type in sorted(subscriber_types):
                info = subscriber_types[sub_type]
                sub_id = f"subscriber:{sub_type}"
                nodes[sub_id] = {
                    "id": sub_id, "kind": "subscriber", "label": sub_type,
                    "component": None, "owner_type": "Event subscribers",
                    "path": info["path"], "line": info["line"],
                }
                edges.add((bus_node_id, sub_id, "interplay", "notifies"))

    # RPC/HTTP endpoints (namespace rollup): group each transport's method calls
    # by namespace, keeping individual methods as attributes with source lines so
    # 40+ JSON-RPC methods stay legible as ~a dozen deep-linkable namespace nodes.
    endpoint_groups: dict[tuple[str, str, str, str], dict[str, Any]] = {}
    # A typed wrapper method (e.g. GatewayClient.promptBreakdown) is one whose body
    # issues call("ns.method"); mapping its name to the namespaces it reaches lets
    # us resolve a consumer's `client.promptBreakdown(...)` back to `session` below.
    wrapper_method_ns: dict[str, set[str]] = {}
    for source in sorted(files, key=lambda item: item["path"]):
        text = source["_text"]
        # The method/path names live inside string literals, which the stripped
        # `code` blanks — so match on the original text, then use `code` (same
        # offsets) to reject comment/string hits and resolve the enclosing type.
        code = strip_swift_noncode(text)
        for protocol, pattern in (("jsonrpc", RPC_METHOD_RE), ("rest", HTTP_METHOD_RE)):
            for match in pattern.finditer(text):
                # Reject comment/doc hits: real code keeps the `call` identifier
                # (jsonrpc) or the delimiter before the verb literal (rest);
                # strip_swift_noncode blanks both inside comments.
                if protocol == "jsonrpc" and code[match.start():match.start() + 4] != "call":
                    continue
                if protocol == "rest" and not code[max(0, match.start() - 1):match.start()].strip():
                    continue
                owner_type, enclosing_fn = enclosing_context(code, match.start())
                if owner_type not in transport_owner_by_type:
                    continue
                component = transport_owner_by_type[owner_type]
                if protocol == "jsonrpc":
                    method, namespace = match.group(1), match.group(1).split(".")[0]
                else:
                    namespace = rest_namespace(match.group(2))
                    method = f"{match.group(1)} {match.group(2)}"
                if enclosing_fn:
                    wrapper_method_ns.setdefault(enclosing_fn, set()).add(namespace)
                line = code.count("\n", 0, match.start()) + 1
                key = (component, owner_type, protocol, namespace)
                group = endpoint_groups.setdefault(
                    key, {"methods": {}, "files": {}, "path": source["path"], "line": line}
                )
                site = (source["path"], line)
                if method not in group["methods"] or site < group["methods"][method]:
                    group["methods"][method] = site
                if source["path"] not in group["files"] or line < group["files"][source["path"]]:
                    group["files"][source["path"]] = line
                if site < (group["path"], group["line"]):
                    group["path"], group["line"] = source["path"], line
    for (component, owner_type, protocol, namespace), group in sorted(endpoint_groups.items()):
        digest = hashlib.sha256("\0".join([owner_type, protocol, namespace]).encode("utf-8")).hexdigest()[:12]
        ep_id = f"endpoint:{digest}"
        add_owner(component, owner_type, "transport")
        nodes[ep_id] = {
            "id": ep_id, "kind": "endpoint",
            "sub_kind": "rpc_namespace" if protocol == "jsonrpc" else "http_endpoint",
            "label": namespace, "component": component, "owner_type": owner_type,
            "protocol": protocol, "method_count": len(group["methods"]),
            "methods": [
                {"method": method, "path": path, "line": line}
                for method, (path, line) in sorted(group["methods"].items())
            ],
            "files": sorted(group["files"]),
            "path": group["path"], "line": group["line"],
        }
        # Namespace → client extension file → core transport. A namespace whose
        # methods live in the transport's own file is called by the core directly;
        # one implemented in `GatewayClient+Wiki.swift` goes through a `client`
        # node for that file, which the core transport `extends`.
        core_path = file_by_type[owner_type]["path"] if owner_type in file_by_type else None
        for path, line in sorted(group["files"].items()):
            if path == core_path:
                edges.add((owner_node_id(component, owner_type), ep_id, "structure", "calls"))
                continue
            stem = Path(path).stem
            client_id = f"client:{component or 'unassigned'}:{stem}"
            client = nodes.get(client_id)
            if client is None:
                client = nodes[client_id] = {
                    "id": client_id, "kind": "client", "sub_kind": "client_extension",
                    "label": stem, "component": component, "owner_type": owner_type,
                    "namespaces": set(), "path": path, "line": line,
                }
            client["line"] = min(client["line"], line)
            client["namespaces"].add(namespace)
            edges.add((owner_node_id(component, owner_type), client_id, "structure", "extends"))
            edges.add((client_id, ep_id, "structure", "implements"))
        for pool in resources:
            if pool["kind"] == "rpc_pool" and pool["owner_type"] == owner_type and pool["component"] == component:
                edges.add((ep_id, resource_node_by_id[pool["id"]], "lifecycle", "correlates"))

    # Caller attribution: which product surface actually invokes each namespace.
    # Two hops, both receiver-qualified so a same-named method on an unrelated
    # object (a view model's own submitPrompt, a formatter's sessionTitle) never
    # masquerades as a gateway call: (a) a consumer that calls a typed wrapper
    # method through a client/seam-typed reference resolves to that wrapper's
    # namespaces; (b) a consumer that calls .call("ns.method") directly through
    # such a reference resolves to `ns`. Each caller becomes a node with an
    # `invokes` edge to every namespace endpoint it reaches, so the transport's
    # namespace fan finally records who queries it — not just that it is queried.
    endpoint_ids_by_namespace: dict[str, list[str]] = {}
    for node in nodes.values():
        if node["kind"] == "endpoint":
            endpoint_ids_by_namespace.setdefault(node["label"], []).append(node["id"])

    client_ref_pattern = "|".join(re.escape(name) for name in sorted(transport_owner_types | {SEAM_PROTOCOL}))
    client_var_re = re.compile(
        r"\b([a-z_][A-Za-z0-9_]*)\s*:\s*(?:any\s+|some\s+)?(?:" + client_ref_pattern + r")\b"
    )
    member_call_re = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*[?!]?\s*\.\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(")
    receiver_before_re = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)\s*[?!]?\s*\.\s*$")

    caller_namespaces: dict[str, dict[str, Any]] = {}

    def record_caller(caller_type: str | None, source: dict[str, Any], namespace: str, offset: int) -> None:
        if not caller_type or caller_type in transport_owner_types:
            return
        entry = caller_namespaces.setdefault(
            caller_type,
            {
                "component": source["component"],
                "namespaces": set(),
                "path": source["path"],
                "line": strip_swift_noncode(source["_text"]).count("\n", 0, offset) + 1,
            },
        )
        entry["namespaces"].add(namespace)

    for source in sorted(files, key=lambda item: item["path"]):
        code = strip_swift_noncode(source["_text"])
        client_vars = {match.group(1) for match in client_var_re.finditer(code)}
        if not client_vars:
            continue
        # (a) typed wrapper invocations, receiver must be a client-typed variable.
        for match in member_call_re.finditer(code):
            receiver, method = match.group(1), match.group(2)
            if receiver not in client_vars or method not in wrapper_method_ns:
                continue
            caller_type, _ = enclosing_context(code, match.start())
            for namespace in wrapper_method_ns[method]:
                record_caller(caller_type, source, namespace, match.start())
        # (b) direct call("ns.method") through a client-typed receiver.
        for match in RPC_METHOD_RE.finditer(source["_text"]):
            if code[match.start():match.start() + 4] != "call":
                continue
            preceding = receiver_before_re.search(code[max(0, match.start() - 48):match.start()])
            if preceding is None or preceding.group(1) not in client_vars:
                continue
            caller_type, _ = enclosing_context(code, match.start())
            record_caller(caller_type, source, match.group(1).split(".")[0], match.start())

    for caller_type, info in sorted(caller_namespaces.items()):
        namespaces = sorted(ns for ns in info["namespaces"] if ns in endpoint_ids_by_namespace)
        if not namespaces:
            continue
        decl = decl_index.get(caller_type)
        caller_id = f"caller:{info['component'] or 'unassigned'}:{caller_type}"
        nodes[caller_id] = {
            "id": caller_id, "kind": "caller", "sub_kind": "page",
            "label": caller_type, "component": info["component"], "namespaces": namespaces,
            "path": decl["path"] if decl else info["path"],
            "line": decl["line"] if decl else info["line"],
        }
        for namespace in namespaces:
            for ep_id in endpoint_ids_by_namespace[namespace]:
                edges.add((caller_id, ep_id, "usage", "invokes"))

    # SSE replay cursor: the REST/SSE transport's "where was I" construction — the
    # push-leg analog of the pool+socket, feeding replayed events back to the bus.
    # Recognized as a stored per-stream event-id field on a transport owner.
    cursor_re = re.compile(
        r"(?m)^[ \t]*(?:(?:public|package|internal|private|fileprivate)\s+)*"
        r"(?:var|let)\s+((?i:lastEventID|eventCursor|afterEventID)[A-Za-z0-9_]*)\s*:",
    )
    for owner_type, component in sorted(transport_owner_by_type.items()):
        source = file_by_type.get(owner_type)
        if source is None:
            continue
        code = strip_swift_noncode(source["_text"])
        match = cursor_re.search(code)
        if match is None:
            continue
        enclosing, _ = enclosing_context(code, match.start())
        if enclosing != owner_type:
            continue
        cur_id = f"cursor:{component}:{owner_type}"
        nodes[cur_id] = {
            "id": cur_id, "kind": "resource", "sub_kind": "stream_cursor",
            "label": match.group(1), "component": component, "owner_type": owner_type,
            "path": source["path"], "line": code.count("\n", 0, match.start()) + 1,
        }
        edges.add((owner_node_id(component, owner_type), cur_id, "structure", "owns"))
        if bus_node_id is not None:
            edges.add((cur_id, bus_node_id, "interplay", "replays-into"))

    # Cluster every node by (component, owner/type) — the columns of the view.
    clusters: dict[str, dict[str, Any]] = {}
    for node in nodes.values():
        if node["kind"] in {"owner", "seam", "hub"}:
            component, grouping = node["component"], node["label"]
        elif node["kind"] == "endpoint":
            # The many namespace endpoints get their own per-transport column so a
            # transport's structural resources stay legible beside them.
            component, grouping = node["component"], f"{node['owner_type']} · endpoints"
        elif node["kind"] == "caller":
            component, grouping = node["component"], "callers"
        elif node["kind"] == "client":
            component, grouping = node["component"], f"{node['owner_type']} · client files"
        else:
            component, grouping = node["component"], node.get("owner_type") or node["label"]
        digest = hashlib.sha256(
            "\0".join([component or "unassigned", grouping or "unresolved"]).encode("utf-8")
        ).hexdigest()[:12]
        cluster_id = f"interplay-cluster-{digest}"
        node["cluster"] = cluster_id
        cluster = clusters.get(cluster_id)
        if cluster is None:
            cluster = clusters[cluster_id] = {
                "id": cluster_id,
                "component": component,
                "owner_type": grouping,
                "node_ids": [],
            }
        cluster["node_ids"].append(node["id"])

    for node in nodes.values():
        if node["kind"] == "owner":
            node["roles"] = sorted(node["roles"])
        if node["kind"] == "client":
            node["namespaces"] = sorted(node["namespaces"])
    for cluster in clusters.values():
        cluster["node_ids"] = sorted(set(cluster["node_ids"]))

    node_list = sorted(
        nodes.values(),
        key=lambda item: (item.get("path") or "", item.get("line") or 0, item["id"]),
    )
    edge_list = [
        {"source": source, "target": target, "class": edge_class, "relation": relation}
        for source, target, edge_class, relation in sorted(edges)
    ]
    cluster_list = sorted(clusters.values(), key=lambda item: item["id"])
    return {"nodes": node_list, "edges": edge_list, "clusters": cluster_list}


BOUNDARY_RELATION_BY_CATEGORY = {
    "backend": "reaches",
    "network": "traverses",
    "ml-runtime": "runs-on",
    "on-device-engine": "runs-on",
    "platform-service": "uses",
    "platform-storage": "persists-to",
    "platform-framework": "renders-with",
    "third-party-api": "reaches",
}


def attach_externals_to_interplay(interplay: dict[str, Any], externals: dict[str, Any],
                                  stores: dict[str, Any]) -> None:
    """Fold the declared external systems into the interplay graph as boundary nodes.

    Every declared system that some interplay node links to becomes an `external`
    node in an "External systems" cluster. Links are same-file evidence, never
    inference: an owner, hub, seam,
    or subscriber node links to a system that has a signature hit in the file
    declaring that type; an endpoint links (`served-by`) to every backend system
    its transport owner reaches; a subscriber/owner that is a recognised store
    links (`persists-to`) to the storage system claiming its observed mechanism.
    """
    nodes = interplay["nodes"]
    systems = externals["systems"]
    if not systems:
        return
    existing = {(edge["source"], edge["target"], edge["class"], edge["relation"]) for edge in interplay["edges"]}
    new_edges: set[tuple[str, str, str, str]] = set()
    system_by_id = {system["id"]: system for system in systems}
    external_node_id = {system["id"]: f"external:{system['id']}" for system in systems}

    linkable = [node for node in nodes if node["kind"] in {"owner", "hub", "seam", "subscriber"} and node.get("path")]
    for system in systems:
        paths = set(system["paths"])
        relation = BOUNDARY_RELATION_BY_CATEGORY.get(system["category"], "uses")
        for node in linkable:
            if node["path"] in paths:
                new_edges.add((node["id"], external_node_id[system["id"]], "boundary", relation))

    owner_backends: dict[str, set[str]] = defaultdict(set)
    for source, target, _, relation in new_edges:
        system = system_by_id[target.split(":", 1)[1]]
        if source.startswith("owner:") and system["category"] == "backend":
            owner_backends[source].add(target)
    owner_id_by_key = {(node["component"], node["label"]): node["id"] for node in nodes if node["kind"] == "owner"}
    for node in nodes:
        if node["kind"] != "endpoint":
            continue
        owner_id = owner_id_by_key.get((node["component"], node["owner_type"]))
        for target in sorted(owner_backends.get(owner_id or "", ())):
            new_edges.add((node["id"], target, "boundary", "served-by"))

    storage_system = {system["persistence"]: system["id"] for system in systems if system.get("persistence")}
    store_by_type = {item["type_name"]: item for item in stores["items"]}
    for node in nodes:
        if node["kind"] not in {"subscriber", "owner", "hub"}:
            continue
        store = store_by_type.get(node["label"])
        if store is None:
            continue
        for mechanism in store["persistence"]:
            system_id = storage_system.get(mechanism)
            if system_id:
                new_edges.add((node["id"], external_node_id[system_id], "boundary", "persists-to"))

    linked_targets = {target for _, target, _, _ in new_edges}
    for system in systems:
        # Only systems some interplay node actually touches enter this graph; the
        # rest stay in the External systems view so no box floats unconnected.
        if external_node_id[system["id"]] not in linked_targets:
            continue
        evidence = sorted(
            (item for usage in system["usage"] for item in usage["evidence"]),
            key=lambda item: (item["path"], item["line"]),
        )
        first = evidence[0] if evidence else {"path": None, "line": 0}
        digest = hashlib.sha256("\0".join(["external", system["id"]]).encode("utf-8")).hexdigest()[:12]
        cluster_id = f"interplay-cluster-{digest}"
        nodes.append({
            "id": external_node_id[system["id"]],
            "kind": "external",
            "sub_kind": system["category"],
            "label": system["label"],
            "system_id": system["id"],
            "component": system.get("component"),
            "owner_type": "External systems",
            "protocol": system.get("protocol"),
            "description": system["description"],
            "description_authority": "specified",
            "hit_count": system["hit_count"],
            "file_count": system["file_count"],
            "usage": [{"component": usage["component"], "hit_count": usage["hit_count"]} for usage in system["usage"]],
            "path": first["path"],
            "line": first["line"],
            "cluster": cluster_id,
        })
        interplay["clusters"].append({
            "id": cluster_id,
            "component": system.get("component"),
            "owner_type": "External systems",
            "node_ids": [external_node_id[system["id"]]],
        })

    for source, target, edge_class, relation in sorted(new_edges - existing):
        interplay["edges"].append({"source": source, "target": target, "class": edge_class, "relation": relation})
    interplay["edges"].sort(key=lambda edge: (edge["source"], edge["target"], edge["class"], edge["relation"]))
    nodes.sort(key=lambda item: (item.get("path") or "", item.get("line") or 0, item["id"]))
    interplay["clusters"].sort(key=lambda item: item["id"])


def interplay_overlay_key(kind: str, owner_type: str | None, label: str) -> str:
    return f"{kind}:{owner_type}:{label}"


def validate_interplay(interplay: dict[str, Any], overlay: dict[str, Any]) -> None:
    """Bidirectional gate between extracted resources and the curated overlay.

    Fails the build when the source contains a load-bearing resource the overlay
    does not explain (unexplained source), and when the overlay carries prose for
    a resource the source no longer contains (stale prose). Each explanation must
    cite existing source files. The matched prose is folded onto the graph nodes
    so the renderer can surface it.
    """
    if overlay.get("schema_version") != "1.0.0" or not isinstance(overlay.get("entries"), list):
        raise ArchitectureError("architecture/interplay/overlay.json has an unsupported schema")

    gated_nodes: dict[str, dict[str, Any]] = {}
    for node in interplay["nodes"]:
        if node["kind"] == "resource" and node["sub_kind"] in GATED_INTERPLAY_KINDS:
            key = interplay_overlay_key(node["sub_kind"], node.get("owner_type"), node["label"])
            gated_nodes[key] = node

    entries: dict[str, dict[str, Any]] = {}
    for raw in overlay["entries"]:
        if not isinstance(raw, dict):
            raise ArchitectureError("interplay overlay entries must be objects")
        kind, owner_type, label = raw.get("kind"), raw.get("owner_type"), raw.get("label")
        if kind not in GATED_INTERPLAY_KINDS or not owner_type or not label:
            raise ArchitectureError(f"interplay overlay entry has an invalid kind/owner_type/label: {raw.get('id')!r}")
        expected_id = interplay_overlay_key(kind, owner_type, label)
        if raw.get("id") != expected_id:
            raise ArchitectureError(f"interplay overlay entry id {raw.get('id')!r} must equal {expected_id!r}")
        if not isinstance(raw.get("prose"), str) or not raw["prose"].strip():
            raise ArchitectureError(f"interplay overlay entry {expected_id} needs prose")
        if expected_id in entries:
            raise ArchitectureError(f"duplicate interplay overlay entry: {expected_id}")
        paths = [source.rsplit(":", 1)[0] if ":" in source else source
                 for source in raw.get("sources", [])]
        validate_evidence(paths, f"interplay overlay entry {expected_id}")
        entries[expected_id] = raw

    unexplained = sorted(key for key in gated_nodes if key not in entries)
    if unexplained:
        details = "; ".join(f"{key} at {gated_nodes[key]['path']}:{gated_nodes[key]['line']}" for key in unexplained)
        raise ArchitectureError(
            "interplay overlay does not explain extracted resource(s): "
            + details
            + "; add matching entries to architecture/interplay/overlay.json"
        )
    stale = sorted(key for key in entries if key not in gated_nodes)
    if stale:
        raise ArchitectureError(
            "interplay overlay has stale entr(ies) with no matching source: "
            + ", ".join(stale)
            + "; remove them from architecture/interplay/overlay.json"
        )

    for key, node in gated_nodes.items():
        node["overlay_prose"] = entries[key]["prose"]


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
    interplay = build_interplay_graph(files, behavior)
    validate_interplay(interplay, load_json(INTERPLAY_OVERLAY_PATH))
    externals = build_externals_model(files, config)
    stores = build_stores_model(files)
    attach_externals_to_interplay(interplay, externals, stores)
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
            "boundary_rules": dict(sorted(BOUNDARY_RULES.items())),
            "limitations": STATIC_SOURCE_LIMITATIONS + BOUNDARY_LIMITATIONS,
        },
        "behavior": behavior,
        "interplay": interplay,
        "externals": externals,
        "stores": stores,
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
