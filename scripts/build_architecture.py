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
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
CONFIG_PATH = ROOT / "architecture/config.json"
MODEL_PATH = ROOT / "architecture/model/model.json"
SITE_DATA_PATH = ROOT / "architecture/site/data.js"
SEMANTIC_PATH = ROOT / "architecture/semantic/components.json"
INTERPLAY_OVERLAY_PATH = ROOT / "architecture/interplay/overlay.json"
INTERPLAY_INVARIANTS_PATH = ROOT / "architecture/interplay/invariants.json"
CONSTRUCTS_PATH = ROOT / "architecture/semantic/constructs.json"
FLOWS_PATH = ROOT / "architecture/semantic/flows.json"

# Snapshot mode (`--snapshot`, used by scripts/build_architecture_history.py):
# today's extractor runs over an older checkout with today's curated files, so
# the curation gates record what they could not account for instead of failing.
# Strict is the default and the only mode `make architecture` and `--check` use.
LENIENT = False
FIDELITY: dict[str, list[str]] = defaultdict(list)


def gate(kind: str, message: str) -> None:
    """Fail in strict mode; in snapshot mode record the gap under ``kind``."""
    if LENIENT:
        FIDELITY[kind].append(message)
        return
    raise ArchitectureError(message)

DECLARATION_RE = re.compile(
    r"(?m)^[ \t]*(?:(?:public|package|internal|private|fileprivate|open|final|indirect|nonisolated)\s+)*"
    r"(?:class|struct|enum|protocol|actor)\s+([A-Z][A-Za-z0-9_]*)\b"
)
IDENTIFIER_RE = re.compile(r"\b[A-Z][A-Za-z0-9_]{3,}\b")

BEHAVIOR_RULES = {
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
    "swift.lifecycle.pool_remove": "removeValue(forKey:) or removeAll() invoked on a CheckedContinuation pool",
    "swift.resource.bus_subscription": "A binding to the seam's event bus, recording its collect(.byTimeOrCount) batching window or receive(on:) scheduler when present",
    "swift.trigger.surface_call": "A SwiftUI action (Button, onTapGesture, keyboardShortcut, onSubmit, swipeActions, refreshable, Toggle, Picker) or lifecycle hook (onAppear, task, onChange, onReceive, onDisappear) whose closure calls a method on a same-file property typed as a calling surface",
    "swift.trigger.launch_construction": "A @StateObject property of an App entry-point struct initialised with a type on the map: the object is constructed at launch, before any page exists",
    "swift.lifecycle.init_loads": "A recognised store type referenced inside a type's init body: the store is read while the object is constructed",
    "swift.usage.configures": "A launch-constructed type passed as a parameter to a method of a type that holds the transport core: it supplies what the transport connects with",
    "swift.state.machine": "A stored property of a type on the map whose type is an enum with two or more cases and which is assigned a case somewhere in the type: the object's lifecycle state",
    "swift.state.transition": "An assignment of an enum case to a machine property, attributed to the enclosing function; the from-state is read from an enclosing switch or if-case on the same property when there is one",
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
ARTIFACT_DIRECTORY_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*(?:/[A-Za-z0-9][A-Za-z0-9._-]*)*$")
# A UserDefaults key: the literal handed to `forKey:` or `@AppStorage(`.
DEFAULTS_KEY_RE = re.compile(r"^[A-Za-z][A-Za-z0-9._-]{2,}$")
DEFAULTS_KEY_CONTEXT_RE = re.compile(r"(?:forKey\s*:\s*|@AppStorage\s*\(\s*)$")
# `forKey: Self.storageKey` / `forKey: saveKey`: the literal is the constant's initialiser.
DEFAULTS_KEY_IDENTIFIER_RE = re.compile(r"forKey\s*:\s*(?:Self\.|self\.)?([A-Za-z_][A-Za-z0-9_]*)\b")
ARTIFACT_MECHANISM = {"file": "file", "directory": "file", "defaults_key": "defaults"}
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
INTERPLAY_OP_KINDS = {"model_load", "model_infer", "pool_register", "pool_resolve", "pool_remove"}
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


def header_open_brace(code: str, index: int) -> int | None:
    """Return the offset of the `{` that opens a declaration whose header starts at index.

    Skips a generic clause and a balanced parameter list, then any return-type,
    effects or inheritance text, so a signature that spans several lines still
    resolves. Gives up at a blank line or a `;` (a body-less requirement) so a
    declaration without a body never swallows the next one's brace.
    """
    length = len(code)
    cursor = index
    while cursor < length and code[cursor] in " \t":
        cursor += 1
    if cursor < length and code[cursor] == "<":
        depth = 0
        while cursor < length:
            if code[cursor] == "<":
                depth += 1
            elif code[cursor] == ">":
                depth -= 1
                if depth == 0:
                    cursor += 1
                    break
            cursor += 1
    while cursor < length and code[cursor] in " \t":
        cursor += 1
    if cursor < length and code[cursor] == "(":
        depth = 0
        while cursor < length:
            if code[cursor] == "(":
                depth += 1
            elif code[cursor] == ")":
                depth -= 1
                if depth == 0:
                    cursor += 1
                    break
            cursor += 1
    newlines = 0
    while cursor < length:
        char = code[cursor]
        if char == "{":
            return cursor
        if char == ";":
            return None
        if char == "\n":
            newlines += 1
            if newlines > 1 and code[index:cursor].rstrip(" \t").endswith("\n"):
                return None
        elif not char.isspace():
            newlines = 0
        cursor += 1
    return None


DECLARATION_HEADER_RE = re.compile(r"\b(class|struct|enum|actor|extension|func)\s+([A-Za-z_][A-Za-z0-9_]*)")


def declaration_blocks(code: str) -> list[tuple[int, int, str, str]]:
    """Every declaration with a body: (start, end, kind, name), bracket-aware headers."""
    blocks: list[tuple[int, int, str, str]] = []
    for match in DECLARATION_HEADER_RE.finditer(code):
        open_brace = header_open_brace(code, match.end())
        if open_brace is None:
            continue
        blocks.append((match.start(), balanced_block_end(code, open_brace + 1), match.group(1), match.group(2)))
    return blocks


def enclosing_context(code: str, offset: int) -> tuple[str | None, str | None]:
    """Return cheaply-derived enclosing type/function using balanced source braces."""
    enclosing_type = None
    enclosing_function = None
    for start, end, declaration_kind, name in declaration_blocks(code):
        if start > offset:
            break
        if not (start <= offset < end):
            continue
        if declaration_kind == "func":
            enclosing_function = name
        else:
            enclosing_type = name
    return enclosing_type, enclosing_function


def enclosing_function_range(code: str, offset: int) -> tuple[int, int] | None:
    """Return the byte range of the innermost `func` body enclosing offset."""
    best: tuple[int, int] | None = None
    for start, end, declaration_kind, _ in declaration_blocks(code):
        if start > offset:
            break
        if declaration_kind == "func" and start <= offset < end and (best is None or start > best[0]):
            best = (start, end)
    return best


def extract_behavioral_source(path: str, text: str, component: str | None) -> dict[str, list[dict[str, Any]]]:
    code = strip_swift_noncode(text)

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
        remove_re = re.compile(rf"\b{re.escape(resource['label'])}\s*\.\s*(removeValue|removeAll)\s*\(")
        for match in remove_re.finditer(code):
            owner_type, enclosing_function = enclosing_context(code, match.start())
            operations.append(observed_item(
                "lifecycle-operation", "pool_remove", f"{resource['label']}.{match.group(1)}", component,
                "swift.lifecycle.pool_remove", path, text, match.start(),
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
    return {"task_sites": task_sites,
            "resources": resources, "operations": operations}


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


def validate_external_groups(config: dict[str, Any]) -> None:
    """`external_groups` boxes external systems by category (platform storage, on-device
    inference). A group names categories, never systems, so a new system of a boxed
    category lands in the box without a config edit."""
    groups = config.get("external_groups", [])
    if not isinstance(groups, list):
        raise ArchitectureError("config external_groups must be an array")
    seen_ids: set[str] = set()
    seen_categories: set[str] = set()
    for group in groups:
        if not isinstance(group, dict):
            raise ArchitectureError("external group entries must be objects")
        for key in ("id", "label", "description"):
            if not isinstance(group.get(key), str) or not group[key]:
                raise ArchitectureError(f"external group {group.get('id')!r} needs a non-empty {key}")
        if group["id"] in seen_ids:
            raise ArchitectureError(f"duplicate external group id {group['id']}")
        seen_ids.add(group["id"])
        categories = group.get("categories")
        if not isinstance(categories, list) or not categories:
            raise ArchitectureError(f"external group {group['id']} needs at least one category")
        for category in categories:
            if category not in EXTERNAL_CATEGORIES:
                raise ArchitectureError(f"external group {group['id']} names unknown category {category!r}")
            if category in seen_categories:
                raise ArchitectureError(f"category {category!r} is boxed by more than one external group")
            seen_categories.add(category)


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


def validate_pages(config: dict[str, Any]) -> None:
    pages = config.get("pages")
    if pages is None:
        return
    if not isinstance(pages, dict) or not isinstance(pages.get("items"), list):
        raise ArchitectureError("config pages must be an object with an items array")
    shell = pages.get("shell", [])
    if not isinstance(shell, list) or not all(isinstance(item, str) and item for item in shell):
        raise ArchitectureError("config pages.shell must be an array of type names")
    seen: set[str] = set()
    for page in pages["items"]:
        if not isinstance(page, dict):
            raise ArchitectureError("page entries must be objects")
        for key in ("id", "label"):
            if not isinstance(page.get(key), str) or not page[key]:
                raise ArchitectureError(f"page {page.get('id')!r} needs a non-empty {key}")
        if page["id"] in seen:
            raise ArchitectureError(f"duplicate page id {page['id']}")
        seen.add(page["id"])
        roots = page.get("roots")
        if not isinstance(roots, list) or not roots or not all(isinstance(r, str) and r for r in roots):
            raise ArchitectureError(f"page {page['id']} needs at least one root type name")
        known_components = {str(item["id"]) for item in config["components"]}
        for key in ("namespaces", "components"):
            values = page.get(key, [])
            if not isinstance(values, list) or not all(isinstance(v, str) and v for v in values):
                raise ArchitectureError(f"page {page['id']} {key} must be an array of names")
            if key == "components" and not set(values) <= known_components:
                raise ArchitectureError(f"page {page['id']} names unknown components: {sorted(set(values) - known_components)}")


def assign_pages(files: list[dict[str, Any]], config: dict[str, Any]
                 ) -> tuple[dict[str, str], list[dict[str, Any]], dict[str, list[str]]]:
    """Map declared types to the navigation page whose view tree reaches them.

    Pages and their root view types are declared in config. From each page's
    roots, walk same-file identifier references between declared types, never
    entering another page's roots or the shell types. A type reached by exactly
    one page at the shortest distance belongs to that page; a type two pages reach
    at the same shortest distance is `shared`; a type a root references directly that at
    least half of all pages reach within one more hop is `shared` infrastructure; an
    unreached type is absent.
    """
    pages_cfg = config.get("pages") or {}
    items = pages_cfg.get("items", [])
    if not items:
        return {}, [], {}
    shell = set(pages_cfg.get("shell", []))
    declared: dict[str, dict[str, Any]] = {}
    for source in files:
        for name in source["declarations"]:
            current = declared.get(name)
            if current is None or source["path"] < current["path"]:
                declared[name] = source
    all_roots = {root for page in items for root in page["roots"]}
    missing = sorted(root for root in all_roots if root not in declared)
    for root in missing:
        gate("page_roots_missing", f"page root is not a declared type: {root}")

    depth_by_type: dict[str, dict[str, int]] = defaultdict(dict)
    for page in items:
        own_roots = set(page["roots"])
        stops = (all_roots - own_roots) | shell
        frontier = sorted(own_roots)
        depth = 0
        seen: set[str] = set()
        while frontier:
            next_frontier: set[str] = set()
            for name in frontier:
                if name in seen:
                    continue
                seen.add(name)
                depth_by_type[name][page["id"]] = depth
                source = declared.get(name)
                if source is None:
                    continue
                for identifier in source["identifiers"]:
                    if identifier in declared and identifier not in seen and identifier not in stops:
                        next_frontier.add(identifier)
            frontier = sorted(next_frontier)
            depth += 1

    page_of: dict[str, str] = {}
    ties: dict[str, list[str]] = {}
    for name, depths in depth_by_type.items():
        best = min(depths.values())
        winners = sorted(page for page, value in depths.items() if value == best)
        # Infrastructure guard: a type one root view references directly, and that
        # at least half of all pages reach within one more hop, is shared plumbing
        # (the transport, the seam) — not the property of the page that happens to
        # name it first.
        near = sum(1 for value in depths.values() if value <= best + 1)
        if best <= 1 and near >= 2 and near * 2 >= len(items):
            page_of[name] = "shared"
            # Still resolvable by declared ownership (namespaces, components); the
            # candidates are every page within one hop of the closest.
            ties[name] = sorted(page for page, value in depths.items() if value <= best + 1)
        elif len(winners) == 1:
            page_of[name] = winners[0]
        else:
            page_of[name] = "shared"
            ties[name] = winners
    summary = [
        {
            "id": page["id"],
            "label": page["label"],
            "roots": list(page["roots"]),
            "namespaces": sorted(page.get("namespaces", [])),
            "components": sorted(page.get("components", [])),
            "type_count": sum(1 for value in page_of.values() if value == page["id"]),
        }
        for page in items
    ]
    return page_of, summary, ties


def attach_stores_to_interplay(interplay: dict[str, Any], stores: dict[str, Any],
                               files: list[dict[str, Any]] | None = None) -> None:
    """Every recognised store is a construction on the map, with its relations.

    A store whose type already appears (a calling surface, a subscriber, an owner,
    the hub) is annotated in place; any other store becomes a `store` node with
    its observed persistence and artifact names. A calling surface, hub or
    subscriber whose declaring file names a store type gets a `uses` edge to it
    (same-file identifier evidence, the rule that places engines).
    """
    by_label: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for node in interplay["nodes"]:
        if node["kind"] in {"caller", "subscriber", "owner", "hub"}:
            by_label[node["label"]].append(node)
    for item in stores["items"]:
        summary = {
            "persistence": item["persistence"],
            "artifacts": [artifact["label"] for artifact in item["artifacts"]],
            "mechanism_count": len(item["mechanisms"]),
            "path": item["evidence"]["path"], "line": item["evidence"]["line"],
        }
        if item["type_name"] in by_label:
            for node in by_label[item["type_name"]]:
                node["store"] = summary
            continue
        node_id = f"store:{item['component'] or 'unassigned'}:{item['type_name']}"
        digest = hashlib.sha256("\0".join(["store", item["component"] or "unassigned", item["type_name"]]).encode("utf-8")).hexdigest()[:12]
        cluster_id = f"interplay-cluster-{digest}"
        interplay["nodes"].append({
            "id": node_id, "kind": "store", "sub_kind": item["kind"],
            "label": item["type_name"], "component": item["component"], "owner_type": None,
            "store": summary, "path": item["evidence"]["path"], "line": item["evidence"]["line"],
            "cluster": cluster_id,
        })
        interplay["clusters"].append({"id": cluster_id, "component": item["component"], "owner_type": "Data stores", "node_ids": [node_id]})
    # Relations: who reads or writes each store.
    if files:
        file_by_type: dict[str, dict[str, Any]] = {}
        for source in sorted(files, key=lambda item: item["path"]):
            for name in source["declarations"]:
                file_by_type.setdefault(name, source)
        store_nodes = [node for node in interplay["nodes"] if node.get("store")]
        existing = {(edge["source"], edge["target"], edge["relation"]) for edge in interplay["edges"]}
        for node in interplay["nodes"]:
            if node["kind"] not in {"caller", "hub", "subscriber"}:
                continue
            source = file_by_type.get(node["label"])
            if source is None:
                continue
            identifiers = set(source["identifiers"])
            for store in store_nodes:
                if store["label"] == node["label"] or store["label"] not in identifiers:
                    continue
                key = (node["id"], store["id"], "uses")
                if key not in existing:
                    existing.add(key)
                    interplay["edges"].append({"source": node["id"], "target": store["id"], "class": "usage", "relation": "uses"})
        interplay["edges"].sort(key=lambda edge: (edge["source"], edge["target"], edge["class"], edge["relation"]))
    interplay["nodes"].sort(key=lambda item: (item.get("path") or "", item.get("line") or 0, item["id"]))
    interplay["clusters"].sort(key=lambda item: item["id"])


def attach_triggers_to_interplay(interplay: dict[str, Any], files: list[dict[str, Any]]) -> None:
    """Triggers: the first hop from a view into the map.

    A SwiftUI action or lifecycle hook whose closure calls a method on a same-file
    property typed as a surface on the map (calling surface, subscriber, store,
    hub, engine owner) is a trigger of that surface; for calling surfaces the
    method resolves to the namespaces it reaches. Receiver-qualified, so
    `vm.refresh()` counts only when `vm` is declared with a surface type. Triggers
    that touch only local state are counted, not attributed. An action that only calls a same-file helper is followed one
    level into that helper.
    """
    surface_types = {node["label"] for node in interplay["nodes"] if node["kind"] in {"caller", "subscriber", "hub", "owner", "store"}}
    methods_by_type = {node["label"]: node.get("methods", {}) for node in interplay["nodes"] if node["kind"] == "caller"}
    triggers: list[dict[str, Any]] = []
    unattributed = 0
    for source in sorted(files, key=lambda item: item["path"]):
        code = masked_code(source)
        if "Button" not in code and ".on" not in code and ".task" not in code:
            continue
        var_types: dict[str, str] = {}
        for match in TRIGGER_PROPERTY_RE.finditer(code):
            type_name = match.group("annot") or match.group("init")
            if type_name in surface_types:
                var_types[match.group("name")] = type_name
        if not var_types:
            continue
        # Same-file helper functions: an action body that only calls `refresh()` is
        # followed one level into `func refresh()` in the same file, since that is
        # where the surface call usually lives. One level, no recursion.
        helper_bodies: dict[str, str] = {}
        for start, end, declaration_kind, name in declaration_blocks(code):
            if declaration_kind == "func" and name not in helper_bodies:
                helper_bodies[name] = code[start:end]
        for kind, api, pattern in TRIGGER_PATTERNS:
            for match in pattern.finditer(code):
                open_brace = code.find("{", match.end(), match.end() + 240)
                if open_brace == -1:
                    continue
                body = code[open_brace + 1:balanced_block_end(code, open_brace + 1) - 1]
                view_type, _ = enclosing_context(code, match.start())
                scan = [body]
                for helper in TRIGGER_HELPER_CALL_RE.finditer(body):
                    helper_body = helper_bodies.get(helper.group(1))
                    if helper_body:
                        scan.append(helper_body)
                hits: dict[tuple[str, str], None] = {}
                for text_chunk in scan:
                    for call in TRIGGER_CALL_RE.finditer(text_chunk):
                        surface = var_types.get(call.group(1))
                        if surface:
                            hits.setdefault((surface, call.group(2)), None)
                if not hits:
                    unattributed += 1
                    continue
                line = code.count("\n", 0, match.start()) + 1
                for surface, method in hits:
                    triggers.append({
                        "id": stable_behavior_id("trigger", source["path"], line, f"{api}:{surface}.{method}"),
                        "kind": kind, "api": api, "view": view_type, "surface": surface, "method": method,
                        "namespaces": sorted(methods_by_type.get(surface, {}).get(method, [])),
                        "path": source["path"], "line": line,
                        "authority": "observed", "evidence_class": "static_source",
                        "rule_id": "swift.trigger.surface_call",
                    })
    triggers.sort(key=lambda item: (item["path"], item["line"], item["surface"], item["method"]))
    counts: dict[str, dict[str, int]] = defaultdict(lambda: {"user_action": 0, "lifecycle": 0})
    for trigger in triggers:
        counts[trigger["surface"]][trigger["kind"]] += 1
    for node in interplay["nodes"]:
        if node["label"] in surface_types and node["kind"] in {"caller", "subscriber", "hub", "owner", "store"}:
            node["triggers"] = dict(counts.get(node["label"], {"user_action": 0, "lifecycle": 0}))
    interplay["triggers"] = triggers
    interplay["unattributed_triggers"] = unattributed


def attach_pages_to_interplay(interplay: dict[str, Any], page_of: dict[str, str],
                              pages: list[dict[str, Any]], ties: dict[str, list[str]],
                              config: dict[str, Any], files: list[dict[str, Any]]) -> None:
    """Tag type-labelled interplay nodes with the navigation page that owns them.

    Reachability decides first. A type two pages reach at the same distance, or
    that no page's view tree reaches (a background service the shell starts), is
    resolved by what the pages declare they own: first the RPC namespaces the type
    invokes, then the component its file belongs to. Each node records which rule
    placed it in `page_resolution`.
    """
    interplay["pages"] = pages
    items = (config.get("pages") or {}).get("items", [])
    page_namespaces = {page["id"]: set(page.get("namespaces", [])) for page in items}
    page_components = {page["id"]: set(page.get("components", [])) for page in items}
    all_pages = [page["id"] for page in items]

    type_component: dict[str, str | None] = {}
    for source in sorted(files, key=lambda item: item["path"]):
        for name in source["declarations"]:
            type_component.setdefault(name, source["component"])

    labelled = [node for node in interplay["nodes"] if node["kind"] in {"caller", "hub", "subscriber", "owner", "seam", "store"}]
    invoked: dict[str, set[str]] = defaultdict(set)
    for node in labelled:
        for namespace in node.get("namespaces") or []:
            invoked[node["label"]].add(namespace)

    resolved: dict[str, tuple[str | None, str]] = {}
    for node in labelled:
        label = node["label"]
        if label in resolved:
            continue
        page = page_of.get(label)
        if page not in (None, "shared"):
            resolved[label] = (page, "reachability")
            continue
        candidates = ties.get(label) if page == "shared" else (all_pages if page is None else [])
        if not candidates:
            resolved[label] = (page, "shared" if page == "shared" else "unreached")
            continue
        by_namespace = sorted(p for p in candidates if page_namespaces[p] & invoked.get(label, set()))
        if len(by_namespace) == 1:
            resolved[label] = (by_namespace[0], "namespace")
            continue
        component = type_component.get(label)
        by_component = sorted(p for p in candidates if component and component in page_components[p])
        if len(by_component) == 1:
            resolved[label] = (by_component[0], "component")
            continue
        resolved[label] = (page, "shared" if page == "shared" else "unreached")

    # Reference tie-break: a type still shared or unreached takes the single page of
    # the surfaces whose files reference it (`uses` edges), if there is exactly one.
    by_id = {node["id"]: node for node in interplay["nodes"]}
    referencing_pages: dict[str, set[str]] = defaultdict(set)
    for edge in interplay["edges"]:
        if edge["relation"] != "uses":
            continue
        source = by_id.get(edge["source"])
        target = by_id.get(edge["target"])
        if source is None or target is None:
            continue
        page, _ = resolved.get(source["label"], (None, ""))
        if page not in (None, "shared"):
            referencing_pages[target["label"]].add(page)
    for label, (page, rule) in list(resolved.items()):
        if page in (None, "shared") and len(referencing_pages.get(label, set())) == 1:
            resolved[label] = (next(iter(referencing_pages[label])), "reference")
    for node in labelled:
        page, rule = resolved[node["label"]]
        node["page"] = page
        node["page_resolution"] = rule
    # A trigger belongs to the page whose view tree reaches the view it sits in.
    for trigger in interplay.get("triggers", []):
        view_page = page_of.get(trigger.get("view") or "")
        trigger["page"] = view_page if view_page not in (None, "shared") else None


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
            gate("externals_unmatched",
                 f"external system {system_id} matched no source signature; fix its signatures or remove it")
            continue
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
    return {"systems": systems, "edges": edges, "groups": [dict(group) for group in config.get("external_groups", [])]}


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
        key_constants = {
            match.group(1)
            for range_start, range_end, _ in ranges
            for match in DEFAULTS_KEY_IDENTIFIER_RE.finditer(code[range_start:range_end])
        }
        constant_context = re.compile(
            r"(?:let|var)\s+(" + "|".join(sorted(map(re.escape, key_constants))) + r")\s*(?::\s*String)?\s*=\s*$"
        ) if key_constants else None
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
                rule_id = "swift.store.artifact_literal"
                if ARTIFACT_FILE_RE.match(content):
                    artifact_kind = "file"
                elif ARTIFACT_DIRECTORY_RE.match(content) and re.match(
                    r"\s*,\s*isDirectory\s*:\s*true", code[end + 1:end + 40]
                ):
                    artifact_kind = "directory"
                elif DEFAULTS_KEY_RE.match(content) and (
                    DEFAULTS_KEY_CONTEXT_RE.search(code[max(0, start - 40):start - 1])
                    or (constant_context is not None and constant_context.search(code[max(0, start - 80):start - 1]))
                ):
                    artifact_kind = "defaults_key"
                    rule_id = "swift.store.defaults_key_literal"
                else:
                    continue
                item = observed_item(
                    "store-artifact", artifact_kind, content, component,
                    rule_id, path, text, start - 1, store=name, via=via,
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
    validate_external_groups(config)
    validate_pages(config)


def validate_evidence(evidence: Any, owner: str) -> list[str]:
    if not isinstance(evidence, list) or not evidence:
        raise ArchitectureError(f"{owner} must cite at least one evidence path")
    normalized: list[str] = []
    for item in evidence:
        if not isinstance(item, str) or item.startswith("/") or ".." in Path(item).parts:
            raise ArchitectureError(f"{owner} has an invalid evidence path: {item!r}")
        if not (ROOT / item).is_file():
            gate("evidence_missing", f"{owner} cites missing file: {item}")
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


def build_behavior_model(files: list[dict[str, Any]]) -> dict[str, Any]:
    collections: dict[str, list[dict[str, Any]]] = {
        "task_sites": [], "resources": [], "operations": []
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

    return {**collections, "pockets": pockets}


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
    # An owner of a continuation pool that does not conform to the seam (a download
    # manager, say) is still an in-memory construction with shared mutable state;
    # it enters the graph with the `pool` role rather than `transport`.
    pool_owners = {
        (item["component"], item["owner_type"])
        for item in resources
        if item["kind"] == "rpc_pool" and (item["component"], item["owner_type"]) not in transport_owners
    }
    included_owner_keys = transport_owners | engine_owners | pool_owners

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

    def role_for(component: str | None, owner_type: str, kind: str) -> str:
        role = role_for_kind(kind)
        if role == "transport" and (component, owner_type) in pool_owners:
            return "pool"
        return role

    resource_node_by_id: dict[str, str] = {}
    for resource in resources:
        add_owner(resource["component"], resource["owner_type"], role_for(resource["component"], resource["owner_type"], resource["kind"]))
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

    # Critical sections: for every function on an included owner that acquires a
    # lock, the ordered operations in that function become one `section` node
    # (lock → register → unlock → send …). Steps between an acquire and the next
    # release are `guarded`. Only operation kinds the extractor already recognises
    # participate; the raw pool operations a section covers are not drawn twice.
    sectioned_operation_ids: set[str] = set()
    grouped: dict[tuple[str | None, str, str], list[dict[str, Any]]] = defaultdict(list)
    for op in behavior["operations"]:
        if (op["component"], op.get("owner_type")) not in included_owner_keys or not op.get("enclosing_function"):
            continue
        grouped[(op["component"], op["owner_type"], op["enclosing_function"])].append(op)
    for (component, owner_type, function), ops in sorted(grouped.items(), key=lambda kv: (kv[0][0] or "", kv[0][1], kv[0][2])):
        ops.sort(key=lambda op: (op["evidence"]["line"], op["id"]))
        if not any(op["kind"] == "acquire" for op in ops):
            continue
        held: set[str] = set()
        steps: list[dict[str, Any]] = []
        lock_labels: set[str] = set()
        guarded_resources: set[str] = set()
        for op in ops:
            resource = op.get("resource_label")
            if op["kind"] == "acquire" and resource:
                held.add(resource)
                lock_labels.add(resource)
            guarded = bool(held) and op["kind"] not in {"acquire", "release"}
            if guarded and resource:
                guarded_resources.add(resource)
            steps.append({
                "kind": op["kind"], "label": op["label"], "line": op["evidence"]["line"],
                "resource_label": resource, "guarded": guarded,
            })
            if op["kind"] == "release" and resource:
                held.discard(resource)
            if op["kind"] in INTERPLAY_OP_KINDS:
                sectioned_operation_ids.add(op["id"])
        section_id = f"section:{component or 'unassigned'}:{owner_type}:{function}"
        add_owner(component, owner_type, "support")
        nodes[section_id] = {
            "id": section_id, "kind": "section", "sub_kind": "critical_section",
            "label": function, "component": component, "owner_type": owner_type,
            "lock_labels": sorted(lock_labels), "guarded_resources": sorted(guarded_resources),
            "steps": steps, "path": ops[0]["evidence"]["path"], "line": ops[0]["evidence"]["line"],
        }
        edges.add((owner_node_id(component, owner_type), section_id, "lifecycle", "operates"))
        for op in ops:
            target = resource_node_by_id.get(op.get("resource_id"))
            if target is None:
                continue
            if op["kind"] == "acquire":
                edges.add((section_id, target, "lifecycle", "locks"))
            elif op["kind"] != "release":
                edges.add((section_id, target, "lifecycle", op["kind"]))

    for operation in operations:
        if operation["id"] in sectioned_operation_ids:
            continue
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
            role = "engine" if operation["kind"] in {"model_load", "model_infer"} else role_for(operation["component"], owner_type, "rpc_pool")
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
                    if not owner_type or owner_type in transport_owner_by_type:
                        continue
                    subscription = parse_bus_subscription(code, match.end())
                    subscription["path"] = source["path"]
                    subscription["line"] = code.count("\n", 0, match.start()) + 1
                    if owner_type in special_types:
                        # A hub that binds the bus is notified like any subscriber; it keeps
                        # its hub node rather than gaining a second box.
                        hub_id = f"hub:{owner_type}"
                        if hub_id in nodes:
                            edges.add((bus_node_id, hub_id, "interplay", "notifies"))
                            nodes[hub_id].setdefault("subscription", subscription)
                        continue
                    if owner_type not in subscriber_types:
                        decl = decl_index.get(owner_type)
                        subscriber_types[owner_type] = {
                            "path": decl["path"] if decl else source["path"],
                            "line": decl["line"] if decl else code.count("\n", 0, match.start()) + 1,
                            "subscription": subscription,
                        }
            for sub_type in sorted(subscriber_types):
                info = subscriber_types[sub_type]
                sub_id = f"subscriber:{sub_type}"
                nodes[sub_id] = {
                    "id": sub_id, "kind": "subscriber", "label": sub_type,
                    "component": None, "owner_type": "Event subscribers",
                    "subscription": info["subscription"],
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
        # The core transport dispatches every namespace it serves, whichever file
        # hosts the wrapper: one object owns the pool and the socket the call rides.
        edges.add((owner_node_id(component, owner_type), ep_id, "structure", "dispatches"))
        for path, line in sorted(group["files"].items()):
            if path == core_path:
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
            client.setdefault("endpoint_ids", set()).add(ep_id)
            # An extension file is a facade: its wrappers route through the core.
            edges.add((client_id, owner_node_id(component, owner_type), "structure", "routes-through"))
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
        code = masked_code(source)
        entry = caller_namespaces.setdefault(
            caller_type,
            {
                "component": source["component"],
                "namespaces": set(),
                "methods": defaultdict(set),
                "path": source["path"],
                "line": code.count("\n", 0, offset) + 1,
            },
        )
        entry["namespaces"].add(namespace)
        _, method = enclosing_context(code, offset)
        if method:
            entry["methods"][method].add(namespace)

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
            "methods": {method: sorted(ns) for method, ns in sorted(info["methods"].items())},
            "path": decl["path"] if decl else info["path"],
            "line": decl["line"] if decl else info["line"],
        }
        for namespace in namespaces:
            for ep_id in endpoint_ids_by_namespace[namespace]:
                edges.add((caller_id, ep_id, "usage", "invokes"))
        # The surface calls the extension file whose wrappers cover the namespace.
        for namespace in namespaces:
            for client in nodes.values():
                if client["kind"] == "client" and namespace in client["namespaces"]:
                    edges.add((caller_id, client["id"], "usage", "calls"))
        # The surface holds a reference to the one shared client (or to the seam it
        # is typed against): every page competes for the same pool and socket.
        caller_source = file_by_type.get(caller_type)
        caller_identifiers = set(caller_source["identifiers"]) if caller_source else set()
        for owner_type, component in sorted(transport_owner_by_type.items()):
            if owner_type in caller_identifiers:
                edges.add((caller_id, owner_node_id(component, owner_type), "usage", "holds"))
        if seam_node_id is not None and SEAM_PROTOCOL in caller_identifiers:
            edges.add((caller_id, seam_node_id, "usage", "holds"))

    # Owner references: which callers, hubs, and subscribers name a non-transport
    # owner type (an on-device engine, a speech engine, a support owner) in their
    # declaring file. Same-file identifier evidence only. The site uses these
    # `uses` edges to place a single-feature engine — and the resources and
    # operations it owns — inside that feature's zone instead of the shared core.
    owner_nodes = [node for node in nodes.values() if node["kind"] == "owner"]
    for node in list(nodes.values()):
        if node["kind"] not in {"caller", "hub", "subscriber"}:
            continue
        source = file_by_type.get(node["label"])
        if source is None:
            continue
        identifiers = set(source["identifiers"])
        for owner in owner_nodes:
            if owner["label"] in transport_owner_types or owner["label"] == node["label"]:
                continue
            if owner["label"] in identifiers:
                edges.add((node["id"], owner["id"], "usage", "uses"))

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
            node["endpoint_ids"] = sorted(node.get("endpoint_ids", set()))
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


def store_leaf_artifacts(store: dict[str, Any]) -> list[dict[str, Any]]:
    """The artifacts a store is drawn writing: its files, its directories that hold
    no named file, and its defaults keys. When one directory literal accompanies
    file literals it is the folder those files live in, so the files are named
    `folder/file` and the folder itself is not a leaf."""
    artifacts = store.get("artifacts", [])
    files = [item for item in artifacts if item["kind"] == "file"]
    directories = [item for item in artifacts if item["kind"] == "directory"]
    keys = [item for item in artifacts if item["kind"] == "defaults_key"]
    leaves: list[dict[str, Any]] = []
    folder = directories[0]["label"] if len(directories) == 1 and files else None
    for item in files:
        label = f"{folder}/{item['label']}" if folder else item["label"]
        leaves.append({"kind": "file", "label": label, "evidence": item["evidence"]})
    if not folder:
        if not files and len(directories) > 1 and "/" not in directories[0]["label"]:
            # `.appendingPathComponent("portal").appendingPathComponent("wiki-graph-cache")`:
            # the first, single-segment directory is the folder the others nest in.
            parent = directories[0]["label"]
            for item in directories[1:]:
                leaves.append({"kind": "directory", "label": f"{parent}/{item['label']}", "evidence": item["evidence"]})
        else:
            for item in directories:
                leaves.append({"kind": "directory", "label": item["label"], "evidence": item["evidence"]})
    for item in keys:
        leaves.append({"kind": "defaults_key", "label": item["label"], "evidence": item["evidence"]})
    seen: set[tuple[str, str]] = set()
    unique: list[dict[str, Any]] = []
    for leaf in leaves:
        key = (leaf["kind"], leaf["label"])
        if key not in seen:
            seen.add(key)
            unique.append(leaf)
    return unique


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

    # A store persists to the artifacts its body names (files, directories, defaults
    # keys), each drawn inside the storage system that owns the mechanism; a
    # mechanism with no named artifact links the store to the system itself.
    storage_system = {system["persistence"]: system["id"] for system in systems if system.get("persistence")}
    store_by_type = {item["type_name"]: item for item in stores["items"]}
    artifact_nodes: dict[str, dict[str, Any]] = {}
    for node in nodes:
        if node["kind"] not in {"subscriber", "owner", "hub", "store", "caller"}:
            continue
        store = store_by_type.get(node["label"])
        if store is None:
            continue
        leaves = store_leaf_artifacts(store)
        covered = {ARTIFACT_MECHANISM[leaf["kind"]] for leaf in leaves}
        for leaf in leaves:
            system_id = storage_system.get(ARTIFACT_MECHANISM[leaf["kind"]])
            if not system_id:
                continue
            artifact_id = f"artifact:{system_id}:{leaf['label']}"
            record = artifact_nodes.get(artifact_id)
            if record is None:
                record = artifact_nodes[artifact_id] = {
                    "id": artifact_id,
                    "kind": "artifact",
                    "sub_kind": leaf["kind"],
                    "label": leaf["label"],
                    "system_id": system_id,
                    "component": system_by_id[system_id].get("component"),
                    "owner_type": "External systems",
                    "stores": [],
                    "evidence": [],
                    "path": leaf["evidence"]["path"],
                    "line": leaf["evidence"]["line"],
                }
            if node["label"] not in record["stores"]:
                record["stores"].append(node["label"])
            if leaf["evidence"] not in record["evidence"]:
                record["evidence"].append(leaf["evidence"])
            new_edges.add((node["id"], artifact_id, "boundary", "persists-to"))
            new_edges.add((artifact_id, external_node_id[system_id], "boundary", "stored-in"))
        for mechanism in store["persistence"]:
            system_id = storage_system.get(mechanism)
            if system_id and mechanism not in covered:
                new_edges.add((node["id"], external_node_id[system_id], "boundary", "persists-to"))

    covered_systems = {
        (source, external_node_id[artifact_nodes[target]["system_id"]])
        for source, target, _, relation in new_edges if relation == "persists-to" and target in artifact_nodes
    }
    new_edges = {
        edge for edge in new_edges
        if not (edge[3] == "persists-to" and not edge[1].startswith("artifact:") and (edge[0], edge[1]) in covered_systems)
    }
    linked_targets = {target for _, target, _, _ in new_edges}
    groups = {group["id"]: group for group in externals.get("groups", [])}
    group_of_category = {category: group["id"] for group in groups.values() for category in group["categories"]}
    for artifact in artifact_nodes.values():
        artifact["stores"].sort()
        artifact["evidence"].sort(key=lambda item: (item["path"], item["line"]))
        artifact["cluster"] = f"interplay-cluster-{hashlib.sha256(chr(0).join(['external', artifact['system_id']]).encode('utf-8')).hexdigest()[:12]}"
        nodes.append(artifact)
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
            "boundary_group": group_of_category.get(system["category"]),
        })
        interplay["clusters"].append({
            "id": cluster_id,
            "component": system.get("component"),
            "owner_type": "External systems",
            "node_ids": [external_node_id[system["id"]]] + sorted(
                artifact["id"] for artifact in artifact_nodes.values() if artifact["system_id"] == system["id"]
            ),
        })
    drawn_externals = {node["id"]: node for node in nodes if node["kind"] == "external"}
    interplay["boundary_groups"] = []
    for group in sorted(groups.values(), key=lambda item: item["id"]):
        members = sorted(node["id"] for node in drawn_externals.values() if node.get("boundary_group") == group["id"])
        if not members:
            gate("externals_ungrouped", f"external group {group['id']} boxes no drawn external system")
        interplay["boundary_groups"].append({
            "id": group["id"], "label": group["label"], "description": group["description"],
            "categories": list(group["categories"]), "members": members,
        })

    for source, target, edge_class, relation in sorted(new_edges - existing):
        interplay["edges"].append({"source": source, "target": target, "class": edge_class, "relation": relation})
    interplay["edges"].sort(key=lambda edge: (edge["source"], edge["target"], edge["class"], edge["relation"]))
    nodes.sort(key=lambda item: (item.get("path") or "", item.get("line") or 0, item["id"]))
    interplay["clusters"].sort(key=lambda item: item["id"])


INVARIANT_KINDS = {
    "single_transport", "surfaces_hold_transport", "pool_guarded_by_lock", "pool_lifecycle_observed",
    "operations_resolve_scope", "endpoints_dispatched_by_transport", "pages_populated",
    "stores_mapped", "triggers_observed", "launch_zoned", "flows_traceable", "machines_complete",
}


def validate_interplay_invariants(interplay: dict[str, Any], behavior: dict[str, Any],
                                  invariants: dict[str, Any], stores: dict[str, Any] | None = None) -> list[dict[str, Any]]:
    """Check the declared constructions the interplay graph assumes against the extracted model.

    Each invariant names the shape a rendering relies on (one transport, every
    surface holding it, pool mutations under the lock, resolves outside it, …).
    A violation fails the build with the invariant's id, the evidence, and the
    declared reason, so a source change that drifts from the assumption is
    caught here rather than silently degrading the graph.
    """
    if invariants.get("schema_version") != "1.0.0" or not isinstance(invariants.get("entries", invariants.get("invariants")), list):
        raise ArchitectureError("architecture/interplay/invariants.json has an unsupported schema")
    entries = invariants.get("invariants", [])
    nodes = interplay["nodes"]
    edges = interplay["edges"]
    by_id = {node["id"]: node for node in nodes}
    violations: list[str] = []
    results: list[dict[str, Any]] = []
    seen_ids: set[str] = set()

    def owners_with_role(role: str) -> list[dict[str, Any]]:
        return [node for node in nodes if node["kind"] == "owner" and role in node.get("roles", [])]

    def resource(owner: str, label: str) -> dict[str, Any] | None:
        return next((n for n in nodes if n["kind"] == "resource" and n.get("owner_type") == owner and n["label"] == label), None)

    def site(op: dict[str, Any]) -> str:
        return f"{op['evidence']['path']}:{op['evidence']['line']}"

    for entry in entries:
        if not isinstance(entry, dict) or not isinstance(entry.get("id"), str) or entry.get("kind") not in INVARIANT_KINDS:
            raise ArchitectureError(f"interplay invariant has an invalid id/kind: {entry!r}")
        if entry["id"] in seen_ids:
            raise ArchitectureError(f"duplicate interplay invariant id {entry['id']}")
        seen_ids.add(entry["id"])
        if not isinstance(entry.get("why"), str) or not entry["why"].strip():
            raise ArchitectureError(f"interplay invariant {entry['id']} needs a why")
        kind = entry["kind"]
        problems: list[str] = []
        checked = 0

        if kind == "single_transport":
            transports = sorted(node["label"] for node in owners_with_role("transport"))
            checked = len(transports)
            if transports != sorted(entry.get("transports", [])):
                problems.append(f"transport owners are {transports}, declared {sorted(entry.get('transports', []))}")
            if not any(node["kind"] == "seam" and node["label"] == entry.get("seam") for node in nodes):
                problems.append(f"seam {entry.get('seam')!r} not found")

        elif kind == "surfaces_hold_transport":
            transport = next((n for n in owners_with_role("transport") if n["label"] == entry.get("transport")), None)
            seam_ids = {n["id"] for n in nodes if n["kind"] == "seam"}
            if transport is None:
                problems.append(f"transport {entry.get('transport')!r} not found")
            else:
                holds = {e["source"] for e in edges if e["relation"] == "holds" and (e["target"] == transport["id"] or e["target"] in seam_ids)}
                callers = [n for n in nodes if n["kind"] == "caller"]
                checked = len(callers)
                missing = sorted(n["label"] for n in callers if n["id"] not in holds)
                if missing:
                    problems.append(f"surfaces without a reference to the core or the seam: {missing}")

        elif kind == "pool_guarded_by_lock":
            owner, pool, lock = entry.get("owner"), entry.get("pool"), entry.get("lock")
            if resource(owner, pool) is None or resource(owner, lock) is None:
                problems.append(f"pool {pool!r} or lock {lock!r} not observed on {owner!r}")
            else:
                sections = {n["label"]: n for n in nodes if n["kind"] == "section" and n.get("owner_type") == owner}
                pool_ops = [op for op in behavior["operations"] if op.get("owner_type") == owner and op.get("resource_label") == pool]
                checked = len(pool_ops)

                def step_for(op: dict[str, Any]) -> dict[str, Any] | None:
                    section = sections.get(op.get("enclosing_function") or "")
                    if section is None:
                        return None
                    return next((st for st in section["steps"] if st["line"] == op["evidence"]["line"] and st["kind"] == op["kind"]), None)

                for op in pool_ops:
                    step = step_for(op)
                    if op["kind"] in {"pool_register", "pool_remove"}:
                        section = sections.get(op.get("enclosing_function") or "")
                        if step is None or not step["guarded"] or section is None or lock not in section["lock_labels"]:
                            problems.append(f"pool mutation {op['kind']} outside {lock} at {site(op)}")
                    elif op["kind"] == "pool_resolve" and entry.get("resolve_outside_lock", True):
                        if step is not None and step["guarded"]:
                            problems.append(f"continuation resumed while holding {lock} at {site(op)}")
                if entry.get("send_outside_lock", True):
                    registering = {op.get("enclosing_function") for op in pool_ops if op["kind"] == "pool_register"}
                    for op in behavior["operations"]:
                        if op.get("owner_type") == owner and op["kind"] == "send" and op.get("enclosing_function") in registering:
                            step = step_for(op)
                            if step is not None and step["guarded"]:
                                problems.append(f"socket write while holding {lock} at {site(op)}")

        elif kind == "pool_lifecycle_observed":
            owner, pool = entry.get("owner"), entry.get("pool")
            counts: dict[str, int] = defaultdict(int)
            for op in behavior["operations"]:
                if op.get("owner_type") == owner and op.get("resource_label") == pool:
                    counts[op["kind"]] += 1
            checked = sum(counts.values())
            for op_kind, minimum in (entry.get("min") or {}).items():
                if counts.get(op_kind, 0) < int(minimum):
                    problems.append(f"{op_kind} observed {counts.get(op_kind, 0)}× on {owner}.{pool}, need ≥ {minimum}")

        elif kind == "operations_resolve_scope":
            unresolved = [op for op in behavior["operations"] if not op.get("enclosing_function")]
            checked = len(behavior["operations"])
            if unresolved:
                problems.append("operations with no enclosing function: " + ", ".join(site(op) for op in unresolved[:6]))

        elif kind == "endpoints_dispatched_by_transport":
            transport_ids = {n["id"] for n in owners_with_role("transport")}
            dispatched = {e["target"] for e in edges if e["relation"] == "dispatches" and e["source"] in transport_ids}
            endpoints = [n for n in nodes if n["kind"] == "endpoint"]
            checked = len(endpoints)
            missing = sorted(n["label"] for n in endpoints if n["id"] not in dispatched)
            if missing:
                problems.append(f"namespaces not dispatched by a transport core: {missing}")

        elif kind == "stores_mapped":
            labels = {node["label"] for node in nodes}
            items = (stores or {}).get("items", [])
            checked = len(items)
            missing = sorted(item["type_name"] for item in items if item["type_name"] not in labels)
            if missing:
                problems.append(f"stores extracted but absent from the map: {missing}")

        elif kind == "triggers_observed":
            allow_empty = set(entry.get("allow_empty", []))
            pages = interplay.get("pages", [])
            triggered: dict[str, int] = defaultdict(int)
            for trigger in interplay.get("triggers", []):
                if trigger.get("page"):
                    triggered[trigger["page"]] += 1
            checked = len(interplay.get("triggers", []))
            silent = sorted(p["id"] for p in pages if triggered.get(p["id"], 0) == 0 and p["id"] not in allow_empty)
            if silent:
                problems.append(f"pages whose views trigger no surface: {silent}")
            if checked < int(entry.get("min", 1)):
                problems.append(f"only {checked} attributed trigger(s) observed, need ≥ {entry.get('min', 1)}")

        elif kind == "launch_zoned":
            launch_triggers = [t for t in interplay.get("triggers", []) if t.get("kind") == "launch"]
            checked = len(launch_triggers)
            if checked < int(entry.get("min", 1)):
                problems.append(f"only {checked} launch construction(s) observed in the App entry points, need ≥ {entry.get('min', 1)}")
            if not any(p["id"] == LAUNCH_PAGE_ID for p in interplay.get("pages", [])):
                problems.append("no App launch zone on the map")
            launch_ids = {n["id"] for n in nodes if n.get("page") == LAUNCH_PAGE_ID}
            used = {e["target"] for e in edges if e["relation"] == "uses"}
            for e in edges:
                if e["relation"] == "loads" and e["source"] in launch_ids and e["target"] not in used:
                    target = by_id[e["target"]]
                    if target["kind"] == "store" and target.get("page") != LAUNCH_PAGE_ID:
                        problems.append(f"{target['label']} is read only at launch but sits in {target.get('page')}")
            for n in nodes:
                if n["kind"] == "provider" and not any(e["source"] == n["id"] and e["relation"] == "loads" for e in edges):
                    problems.append(f"provider {n['label']} loads nothing; it should not be on the map")
            for entry_name in entry.get("configures", []):
                provider = next((n for n in nodes if n["label"] == entry_name and n.get("page") == LAUNCH_PAGE_ID), None)
                if provider is None or not any(e["source"] == provider["id"] and e["relation"] == "configures" for e in edges):
                    problems.append(f"{entry_name} does not configure the transport core")

        elif kind == "machines_complete":
            machines = [n for n in nodes if n["kind"] == "machine"]
            checked = len(machines)
            if checked < int(entry.get("min", 0)):
                problems.append(f"only {checked} state machine(s) extracted, need ≥ {entry.get('min', 0)}")
            declared = entry.get("declared", {})
            by_label = {m["label"]: m for m in machines}
            for label, states in declared.items():
                machine = by_label.get(label)
                if machine is None:
                    problems.append(f"declared machine {label} was not extracted")
                    continue
                actual = sorted(case["name"] for case in machine["machine"]["states"])
                if actual != sorted(states):
                    problems.append(f"{label} has states {actual}, declared {sorted(states)}")
            allow_dead = entry.get("allow_dead", {})
            for machine in machines:
                dead = [s for s in machine["machine"]["dead_states"] if s not in set(allow_dead.get(machine["label"], []))]
                if dead:
                    problems.append(f"{machine['label']}: state(s) never entered by any transition: {dead}")

        elif kind == "flows_traceable":
            flows = interplay.get("flows", [])
            checked = sum(len(flow["steps"]) for flow in flows)
            for flow in flows:
                for problem in flow.get("problems", []):
                    problems.append(f"flow {flow['id']}: {problem}")
            if len(flows) < int(entry.get("min", 0)):
                problems.append(f"only {len(flows)} flow(s) declared, need ≥ {entry.get('min', 0)}")

        elif kind == "pages_populated":
            allow_empty = set(entry.get("allow_empty", []))
            owned: dict[str, int] = defaultdict(int)
            for node in nodes:
                if node.get("page"):
                    owned[node["page"]] += 1
            pages = interplay.get("pages", [])
            checked = len(pages)
            empty = sorted(p["id"] for p in pages if owned.get(p["id"], 0) == 0 and p["id"] not in allow_empty)
            if empty:
                problems.append(f"pages that own no construct: {empty}")

        results.append({"id": entry["id"], "kind": kind, "status": "violated" if problems else "holds",
                        "checked": checked, "why": entry["why"]})
        for problem in problems:
            violations.append(f"{entry['id']}: {problem} (why: {entry['why']})")

    if violations and not LENIENT:
        raise ArchitectureError("interplay invariants violated:\n - " + "\n - ".join(violations))
    for violation in violations:
        gate("invariants_violated", violation)
    return results


TRIGGER_PROPERTY_RE = re.compile(
    r"@(?:StateObject|ObservedObject|EnvironmentObject|Bindable|State)\s+(?:(?:private|internal|fileprivate)\s+)?"
    r"var\s+(?P<name>[a-z_][A-Za-z0-9_]*)\s*(?::\s*(?P<annot>[A-Z][A-Za-z0-9_]*))?(?:\s*=\s*(?P<init>[A-Z][A-Za-z0-9_]*)\s*(?:\(|\.))?"
)
TRIGGER_PATTERNS = [
    ("user_action", "Button", re.compile(r"\bButton\s*(?:\(|\{)")),
    ("user_action", "onTapGesture", re.compile(r"\.onTapGesture\b")),
    ("user_action", "keyboardShortcut", re.compile(r"\.keyboardShortcut\s*\(")),
    ("user_action", "onSubmit", re.compile(r"\.onSubmit\b")),
    ("user_action", "swipeActions", re.compile(r"\.swipeActions\b")),
    ("user_action", "refreshable", re.compile(r"\.refreshable\b")),
    ("user_action", "Toggle", re.compile(r"\bToggle\s*\(")),
    ("user_action", "Picker", re.compile(r"\bPicker\s*\(")),
    ("lifecycle", "onAppear", re.compile(r"\.onAppear\b")),
    ("lifecycle", "task", re.compile(r"\.task\s*(?:\(|\{)")),
    ("lifecycle", "onChange", re.compile(r"\.onChange\s*\(")),
    ("lifecycle", "onReceive", re.compile(r"\.onReceive\s*\(")),
    ("lifecycle", "onDisappear", re.compile(r"\.onDisappear\b")),
]
TRIGGER_CALL_RE = re.compile(r"\b([a-z_][A-Za-z0-9_]*)\s*[?!]?\s*\.\s*([a-z_][A-Za-z0-9_]*)\s*\(")
# A bare call to a same-file function from inside an action body: `refresh()`, `await confirmDelete()`.
TRIGGER_HELPER_CALL_RE = re.compile(r"(?<![.\w])([a-z_][A-Za-z0-9_]*)\s*\(")

# Launch: the App entry points (`struct PortalAppMac: App`) own the objects that
# exist before any page does, as @StateObject properties initialised in place.
APP_STRUCT_RE = re.compile(r"\bstruct\s+([A-Z][A-Za-z0-9_]*)\s*:\s*[^{\n]*\bApp\b[^{\n]*\{")
LAUNCH_PROPERTY_RE = re.compile(
    r"@StateObject\s+(?:(?:private|internal|fileprivate)\s+)?var\s+(?P<name>[a-z_][A-Za-z0-9_]*)\s*"
    r"(?::\s*[A-Z][A-Za-z0-9_]*)?\s*=\s*(?P<type>[A-Z][A-Za-z0-9_]*)\s*(?:\(|\.shared\b)"
)
INIT_HEADER_RE = re.compile(r"\binit\s*\(")

BUS_BATCH_RE = re.compile(
    r"\.\s*collect\s*\(\s*\.byTimeOrCount\s*\(\s*([A-Za-z_.]+)\s*,\s*\.milliseconds\s*\(\s*(\d+)\s*\)\s*,\s*(\d+)\s*\)"
)
BUS_RECEIVE_RE = re.compile(r"\.\s*receive\s*\(\s*on\s*:\s*([A-Za-z_.]+)")


def parse_bus_subscription(code: str, offset: int) -> dict[str, Any]:
    """Describe how a `.eventStream` binding is scheduled, from the operators that follow it.

    Looks at the operator chain immediately after the binding (up to the sink or
    the next statement) for a `collect(.byTimeOrCount(scheduler, .milliseconds(N), M))`
    batching window or a `receive(on:)` scheduler. Absent both, the delivery is
    direct on the publishing thread.
    """
    window = code[offset:offset + 400]
    cut = re.search(r"\.\s*sink\b|\n\s*\n|;", window)
    chain = window[:cut.end()] if cut else window
    batch = BUS_BATCH_RE.search(chain)
    if batch:
        return {"mode": "batched", "scheduler": batch.group(1), "batch_ms": int(batch.group(2)),
                "batch_count": int(batch.group(3)), "rule_id": "swift.resource.bus_subscription"}
    receive = BUS_RECEIVE_RE.search(chain)
    if receive:
        return {"mode": "direct", "scheduler": receive.group(1), "rule_id": "swift.resource.bus_subscription"}
    return {"mode": "direct", "scheduler": None, "rule_id": "swift.resource.bus_subscription"}


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
        gate(
            "overlay_unexplained",
            "interplay overlay does not explain extracted resource(s): "
            + details
            + "; add matching entries to architecture/interplay/overlay.json",
        )
    stale = sorted(key for key in entries if key not in gated_nodes)
    if stale:
        gate(
            "overlay_stale",
            "interplay overlay has stale entr(ies) with no matching source: "
            + ", ".join(stale)
            + "; remove them from architecture/interplay/overlay.json",
        )

    for key, node in gated_nodes.items():
        if key in entries:
            node["overlay_prose"] = entries[key]["prose"]


# ---------------------------------------------------------------------------
# Launch: what exists before any page.
#
# The pages are zones because the app is navigated; the shared core is what more
# than one page reaches. Neither describes the objects the App entry points
# construct at launch, before ContentView appears: the settings object that reads
# the keychain in its initialiser and later supplies the gateway's URL and key,
# the client wrapper, the stores that are loaded on construction. Those get one
# more zone, "App launch", fed by the same mechanics as the pages: a launch
# trigger per @StateObject construction (the first hop, like a Button), a
# `loads` edge per store read in an initialiser, and a `configures` edge from a
# launch-constructed type to the transport core it is handed to.
# ---------------------------------------------------------------------------
LAUNCH_PAGE_ID = "launch"


def validate_launch(config: dict[str, Any]) -> dict[str, Any] | None:
    launch = config.get("launch")
    if launch is None:
        return None
    if not isinstance(launch, dict) or not isinstance(launch.get("label"), str) or not launch["label"]:
        raise ArchitectureError("config launch must be an object with a label")
    roots = launch.get("roots")
    if not isinstance(roots, list) or not roots or not all(isinstance(root, str) and root for root in roots):
        raise ArchitectureError("config launch.roots must be a non-empty array of directories")
    for root in roots:
        if root.startswith("/") or ".." in Path(root).parts:
            raise ArchitectureError(f"config launch root is not a repository-relative directory: {root!r}")
    return launch


def read_launch_sources(config: dict[str, Any]) -> tuple[list[dict[str, Any]], str]:
    """Swift files under the launch roots (the App entry points), outside the
    component tree, hashed into the source tree so `--check` sees them drift."""
    launch = validate_launch(config)
    files: list[dict[str, Any]] = []
    digest = hashlib.sha256()
    if launch is None:
        return files, digest.hexdigest()
    for root in launch["roots"]:
        directory = ROOT / root
        if not directory.is_dir():
            gate("launch_roots_missing", f"config launch root {root!r} is not a directory")
            continue
        for path in sorted(directory.rglob("*.swift")):
            text = path.read_text(encoding="utf-8")
            repo_path = relative(path)
            digest.update(repo_path.encode("utf-8"))
            digest.update(b"\0")
            digest.update(text.encode("utf-8"))
            digest.update(b"\0")
            files.append({"path": repo_path, "source_path": path.relative_to(directory).as_posix(), "component": None,
                          "declarations": sorted(set(DECLARATION_RE.findall(text))), "line_count": len(text.splitlines()),
                          "identifiers": sorted(set(IDENTIFIER_RE.findall(text))), "_text": text})
    return files, digest.hexdigest()


def extract_launch_constructions(launch_files: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Every @StateObject an App struct initialises in place: (app, property, type)."""
    constructions: list[dict[str, Any]] = []
    for source in sorted(launch_files, key=lambda item: item["path"]):
        code = masked_code(source)
        for match in APP_STRUCT_RE.finditer(code):
            open_brace = code.index("{", match.start())
            body_end = balanced_block_end(code, open_brace + 1)
            body = code[open_brace + 1:body_end - 1]
            for prop in LAUNCH_PROPERTY_RE.finditer(body):
                line = code.count("\n", 0, open_brace + 1 + prop.start()) + 1
                constructions.append({
                    "app": match.group(1), "property": prop.group("name"), "type": prop.group("type"),
                    "path": source["path"], "line": line,
                })
    constructions.sort(key=lambda item: (item["path"], item["line"]))
    return constructions


def init_bodies(code: str, type_name: str) -> list[str]:
    """The bodies of every `init(` declared inside ``type_name``'s blocks (type and same-file extensions)."""
    bodies: list[str] = []
    for match in TYPE_BLOCK_RE.finditer(code):
        if match.group(2) != type_name:
            continue
        open_brace = code.index("{", match.start())
        end = balanced_block_end(code, open_brace + 1)
        block = code[open_brace + 1:end - 1]
        for header in INIT_HEADER_RE.finditer(block):
            init_brace = header_open_brace(block, header.end() - 1)
            if init_brace is None:
                continue
            bodies.append(block[init_brace + 1:balanced_block_end(block, init_brace + 1) - 1])
    return bodies


def attach_launch_to_interplay(interplay: dict[str, Any], constructions: list[dict[str, Any]],
                               files: list[dict[str, Any]], config: dict[str, Any]) -> None:
    """The App launch zone: launch triggers, init-time `loads` edges, admitted
    providers, `configures` edges to the transport core, and the re-zoning of
    stores that are only ever read at launch."""
    launch = validate_launch(config)
    if launch is None:
        interplay["launch"] = {"constructions": [], "unmapped": []}
        return
    nodes = interplay["nodes"]
    edges = interplay["edges"]
    file_by_type: dict[str, dict[str, Any]] = {}
    for source in sorted(files, key=lambda item: item["path"]):
        for name in source["declarations"]:
            file_by_type.setdefault(name, source)
    surface_kinds = {"caller", "subscriber", "hub", "owner", "store", "provider"}
    node_by_label: dict[str, dict[str, Any]] = {}
    for node in nodes:
        if node["kind"] in surface_kinds:
            node_by_label.setdefault(node["label"], node)
    store_by_label = {node["label"]: node for node in nodes if node.get("store")}
    core = next((node for node in nodes if node["kind"] == "owner" and "transport" in node.get("roles", [])), None)
    existing = {(edge["source"], edge["target"], edge["relation"]) for edge in edges}

    def add_edge(source: str, target: str, edge_class: str, relation: str) -> None:
        if (source, target, relation) not in existing:
            existing.add((source, target, relation))
            edges.append({"source": source, "target": target, "class": edge_class, "relation": relation})

    triggers: list[dict[str, Any]] = []
    unmapped: list[dict[str, Any]] = []
    summaries: list[dict[str, Any]] = []
    for construction in constructions:
        type_name = construction["type"]
        source = file_by_type.get(type_name)
        loaded: set[str] = set()
        if source is not None:
            code = masked_code(source)
            for body in init_bodies(code, type_name):
                for label in store_by_label:
                    if label != type_name and re.search(rf"\b{re.escape(label)}\b", body):
                        loaded.add(label)
        node = node_by_label.get(type_name)
        if node is None and loaded and source is not None:
            decl_line = next((code.count("\n", 0, m.start()) + 1 for m in TYPE_BLOCK_RE.finditer(code) if m.group(2) == type_name), 0)
            node = {
                "id": f"provider:{source['component'] or 'unassigned'}:{type_name}", "kind": "provider", "label": type_name,
                "component": source["component"], "owner_type": None, "path": source["path"], "line": decl_line,
                "page": LAUNCH_PAGE_ID, "page_resolution": "launch", "loads": sorted(loaded), "configures": [],
            }
            nodes.append(node)
            node_by_label[type_name] = node
        if node is None:
            unmapped.append(dict(construction))
            continue
        triggers.append({
            "id": stable_behavior_id("trigger", construction["path"], construction["line"], f"StateObject:{type_name}.init"),
            "kind": "launch", "api": "StateObject", "view": construction["app"], "surface": type_name, "method": "init",
            "namespaces": [], "page": LAUNCH_PAGE_ID, "path": construction["path"], "line": construction["line"],
            "authority": "observed", "evidence_class": "static_source", "rule_id": "swift.trigger.launch_construction",
        })
        for label in sorted(loaded):
            add_edge(node["id"], store_by_label[label]["id"], "lifecycle", "loads")
        if node["kind"] != "provider" and loaded:
            node["loads"] = sorted(set(node.get("loads", [])) | loaded)
        # configures: the type is handed to a method of a type that holds the core.
        if core is not None:
            holder_re = re.compile(rf"\bvar\s+[a-z_][A-Za-z0-9_]*\s*:\s*{re.escape(core['label'])}\b")
            param_re = re.compile(rf"\bfunc\s+([a-z_][A-Za-z0-9_]*)\s*\([^)]*:\s*{re.escape(type_name)}\b")
            for other in sorted(files, key=lambda item: item["path"]):
                other_code = masked_code(other)
                if not holder_re.search(other_code):
                    continue
                for match in param_re.finditer(other_code):
                    holder_type, _ = enclosing_context(other_code, match.start())
                    add_edge(node["id"], core["id"], "usage", "configures")
                    node.setdefault("configures", []).append({
                        "via": holder_type, "method": match.group(1), "path": other["path"],
                        "line": other_code.count("\n", 0, match.start()) + 1,
                    })
        summaries.append({**construction, "node": node["id"], "loads": sorted(loaded)})
    # Stores that are only ever read at launch belong to the launch zone.
    launch_ids = {node["id"] for node in nodes if node.get("page") == LAUNCH_PAGE_ID}
    used = {edge["target"] for edge in edges if edge["relation"] == "uses"}
    for edge in edges:
        if edge["relation"] != "loads" or edge["source"] not in launch_ids or edge["target"] in used:
            continue
        store = next(node for node in nodes if node["id"] == edge["target"])
        if store["kind"] == "store":
            store["page"] = LAUNCH_PAGE_ID
            store["page_resolution"] = "launch"
    if triggers:
        page = {
            "id": LAUNCH_PAGE_ID, "label": launch["label"], "roots": sorted({c["app"] for c in constructions}),
            "namespaces": [], "components": [],
            "type_count": sum(1 for node in nodes if node.get("page") == LAUNCH_PAGE_ID),
        }
        interplay["pages"] = [page] + [p for p in interplay.get("pages", []) if p["id"] != LAUNCH_PAGE_ID]
        interplay["triggers"] = sorted(interplay.get("triggers", []) + triggers,
                                       key=lambda item: (item["path"], item["line"], item["surface"], item["method"]))
        launch_counts: dict[str, int] = defaultdict(int)
        for trigger in triggers:
            launch_counts[trigger["surface"]] += 1
        for node in nodes:
            if node["label"] in launch_counts and node["kind"] in surface_kinds:
                counts = dict(node.get("triggers") or {"user_action": 0, "lifecycle": 0})
                counts["launch"] = launch_counts[node["label"]]
                node["triggers"] = counts
    interplay["launch"] = {"constructions": summaries, "unmapped": unmapped}
    edges.sort(key=lambda edge: (edge["source"], edge["target"], edge["class"], edge["relation"]))
    nodes.sort(key=lambda item: (item.get("path") or "", item.get("line") or 0, item["id"]))


# ---------------------------------------------------------------------------
# State machines: an object's lifecycle as the source declares it.
#
# A machine is a stored property typed as an enum with two or more cases that the
# owning type assigns a case to somewhere. Each assignment is a transition into
# the case it names, attributed to the enclosing function; the state it leaves is
# read from an enclosing `switch property { case .x: … }` or `if/guard case .x =
# property` when there is one, and left unknown otherwise rather than guessed.
# A derived state (a computed property switching on other fields) is not a
# machine and is not drawn as one.
# ---------------------------------------------------------------------------
MACHINE_KINDS = {"owner", "caller", "subscriber", "hub", "provider"}
MACHINE_PROPERTY_RE = re.compile(
    r"(?m)^[ \t]*(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^)\n]*\))?\s+)*(?:(?:public|internal|private|fileprivate|open|final|nonisolated|static|weak)\s*(?:\(set\))?\s+)*"
    r"var\s+(?P<name>[a-z_][A-Za-z0-9_]*)\s*:\s*(?P<type>[A-Z][A-Za-z0-9_.]*)\??[ \t]*(?:=[ \t]*\.(?P<init>[a-z_][A-Za-z0-9_]*))?"
)
ENUM_BLOCK_RE = re.compile(r"\b(?:indirect\s+)?enum\s+([A-Z][A-Za-z0-9_]*)\b[^{\n]*\{")
ENUM_CASE_LINE_RE = re.compile(r"(?m)^[ \t]*case\s+([a-z_][^\n]*)$")


def enum_cases(code: str, enum_name: str) -> tuple[list[dict[str, Any]], int] | None:
    """The cases of ``enum_name`` declared in ``code`` (first declaration), and its line."""
    for match in ENUM_BLOCK_RE.finditer(code):
        if match.group(1) != enum_name:
            continue
        open_brace = code.index("{", match.start())
        body = code[open_brace + 1:balanced_block_end(code, open_brace + 1) - 1]
        # Only this enum's own members: drop nested blocks (computed properties, nested types).
        flat: list[str] = []
        depth = 0
        for char in body:
            if char == "{":
                depth += 1
            elif char == "}":
                depth -= 1
            elif depth == 0:
                flat.append(char)
        cases: list[dict[str, Any]] = []
        for line in ENUM_CASE_LINE_RE.finditer("".join(flat)):
            text = line.group(1)
            depth = 0
            item = ""
            items: list[str] = []
            for char in text:
                if char == "(":
                    depth += 1
                elif char == ")":
                    depth -= 1
                if char == "," and depth == 0:
                    items.append(item)
                    item = ""
                else:
                    item += char
            items.append(item)
            for raw in items:
                raw = raw.strip()
                if not raw:
                    continue
                name = re.match(r"([a-z_][A-Za-z0-9_]*)", raw)
                if name:
                    cases.append({"name": name.group(1), "payload": "(" in raw})
        return cases, code.count("\n", 0, match.start()) + 1
    return None


def type_block_ranges(code: str, type_name: str) -> list[tuple[int, int]]:
    """The body ranges of ``type_name``'s declaration and its same-file extensions."""
    ranges: list[tuple[int, int]] = []
    for match in TYPE_BLOCK_RE.finditer(code):
        if match.group(2) != type_name:
            continue
        open_brace = code.index("{", match.start())
        ranges.append((open_brace + 1, balanced_block_end(code, open_brace + 1) - 1))
    return ranges


def transition_from_states(code: str, property_name: str, offset: int, function_range: tuple[int, int] | None,
                           known: set[str]) -> list[str] | None:
    """The state(s) an assignment at ``offset`` leaves, from an enclosing switch or
    if/guard case on the same property inside the same function; None when unknown."""
    if function_range is None:
        return None
    start, end = function_range
    body = code[start:end]
    local = offset - start
    prop = re.escape(property_name)
    # switch property { case .a, .b: … }
    for match in re.finditer(rf"\bswitch\s+(?:self\.)?{prop}\s*\{{", body):
        open_brace = body.index("{", match.start())
        close = balanced_block_end(body, open_brace + 1)
        if not (open_brace < local < close):
            continue
        labels = list(re.finditer(r"(?m)^[ \t]*(case\s+[^:\n]+|default)\s*:", body[open_brace:local]))
        if not labels:
            return None
        label = labels[-1].group(1)
        if label == "default":
            return None
        states = [name for name in re.findall(r"\.([a-z_][A-Za-z0-9_]*)", label) if name in known]
        return states or None
    # if case .a = property { … } / if property == .a { … }
    for match in re.finditer(rf"\bif\s+(?:case\s+\.([a-z_][A-Za-z0-9_]*)(?:\([^)]*\))?\s*=\s*(?:self\.)?{prop}|(?:self\.)?{prop}\s*==\s*\.([a-z_][A-Za-z0-9_]*))\b[^{{\n]*\{{", body):
        open_brace = body.index("{", match.start())
        close = balanced_block_end(body, open_brace + 1)
        state = match.group(1) or match.group(2)
        if open_brace < local < close and state in known:
            return [state]
    # guard case .a = property else { … } — the rest of the function is in state a.
    for match in re.finditer(rf"\bguard\s+case\s+\.([a-z_][A-Za-z0-9_]*)(?:\([^)]*\))?\s*=\s*(?:self\.)?{prop}\b[^{{\n]*\{{", body):
        open_brace = body.index("{", match.start())
        close = balanced_block_end(body, open_brace + 1)
        if local > close and match.group(1) in known:
            return [match.group(1)]
    return None


def extract_state_machines(interplay: dict[str, Any], files: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Every machine owned by a type on the map, with its states and transitions."""
    file_by_type: dict[str, dict[str, Any]] = {}
    for source in sorted(files, key=lambda item: item["path"]):
        for name in source["declarations"]:
            file_by_type.setdefault(name, source)
    machines: list[dict[str, Any]] = []
    seen_owner_props: set[tuple[str, str]] = set()
    for node in interplay["nodes"]:
        if node["kind"] not in MACHINE_KINDS:
            continue
        owner = node["label"]
        source = file_by_type.get(owner)
        if source is None or (owner, node.get("component")) in seen_owner_props:
            continue
        code = masked_code(source)
        ranges = type_block_ranges(code, owner)
        if not ranges:
            continue
        for start, end in ranges:
            for prop in MACHINE_PROPERTY_RE.finditer(code, start, end):
                enclosing_type, enclosing_function = enclosing_context(code, prop.start())
                if enclosing_function is not None or enclosing_type != owner:
                    continue
                enum_name = prop.group("type").split(".")[-1]
                declared = enum_cases(code, enum_name)
                enum_path = source["path"]
                if declared is None:
                    other = file_by_type.get(enum_name)
                    if other is None:
                        continue
                    declared = enum_cases(masked_code(other), enum_name)
                    enum_path = other["path"]
                if declared is None or len(declared[0]) < 2:
                    continue
                cases, enum_line = declared
                known = {case["name"] for case in cases}
                name = prop.group("name")
                transitions: list[dict[str, Any]] = []
                assign_re = re.compile(rf"(?<![A-Za-z0-9_.])(?:self\.)?{re.escape(name)}\s*=(?!=)\s*([^\n]+)")
                for r_start, r_end in ranges:
                    for match in assign_re.finditer(code, r_start, r_end):
                        targets = [state for state in re.findall(r"\.([a-z_][A-Za-z0-9_]*)", match.group(1)) if state in known]
                        if not targets:
                            continue
                        _type, function = enclosing_context(code, match.start())
                        function_range = enclosing_function_range(code, match.start())
                        from_states = transition_from_states(code, name, match.start(), function_range, known)
                        line = code.count("\n", 0, match.start()) + 1
                        for target in dict.fromkeys(targets):
                            transitions.append({"from": from_states, "to": target, "function": function or "init",
                                                "path": source["path"], "line": line, "rule_id": "swift.state.transition"})
                if not transitions:
                    continue
                entered = {t["to"] for t in transitions}
                initial = prop.group("init") if prop.group("init") in known else None
                component = node.get("component") or source.get("component")
                machine_id = f"machine:{component or 'unassigned'}:{owner}.{name}"
                machines.append({
                    "id": machine_id, "kind": "machine", "sub_kind": "state_machine", "label": f"{owner}.{name}",
                    "component": component, "owner_type": owner, "owner_id": node["id"], "page": node.get("page"),
                    "path": source["path"], "line": code.count("\n", 0, prop.start()) + 1,
                    "machine": {
                        "property": name, "enum": enum_name, "enum_path": enum_path, "enum_line": enum_line, "initial": initial,
                        "states": cases, "transitions": transitions,
                        "dead_states": sorted(case["name"] for case in cases if case["name"] not in entered and case["name"] != initial),
                        "unknown_from": sum(1 for t in transitions if t["from"] is None),
                    },
                    "rule_id": "swift.state.machine", "authority": "observed", "evidence_class": "static_source",
                })
                seen_owner_props.add((owner, node.get("component")))
    machines.sort(key=lambda item: item["id"])
    return machines


def attach_state_machines(interplay: dict[str, Any], files: list[dict[str, Any]]) -> None:
    machines = extract_state_machines(interplay, files)
    existing = {(e["source"], e["target"], e["relation"]) for e in interplay["edges"]}
    for machine in machines:
        owner_id = machine.pop("owner_id")
        interplay["nodes"].append(machine)
        owner = next(n for n in interplay["nodes"] if n["id"] == owner_id)
        owner.setdefault("machines", []).append(machine["id"])
        if (owner_id, machine["id"], "drives") not in existing:
            interplay["edges"].append({"source": owner_id, "target": machine["id"], "class": "structure", "relation": "drives"})
    interplay["machines"] = {"count": len(machines), "transitions": sum(len(m["machine"]["transitions"]) for m in machines)}
    interplay["edges"].sort(key=lambda edge: (edge["source"], edge["target"], edge["class"], edge["relation"]))
    interplay["nodes"].sort(key=lambda item: (item.get("path") or "", item.get("line") or 0, item["id"]))


# ---------------------------------------------------------------------------
# Semantic enrichment: constrained text on the mechanical map.
#
# Two LLM-written layers, both validated here so the compiler can reject them
# (see architecture/SEMANTIC_ENRICHMENT_PLAN.md). Construct records describe one
# construction each in a kind-specific schema whose identifiers must exist in the
# model; flows are paths whose every step is an edge the map already draws.
# Enrichment never adds a node or an edge: it is folded onto nodes as `semantic`
# and onto the interplay as `flows`, and nothing below is read by placement,
# edge or invariant logic except the `flows_traceable` invariant, which only
# reports what load_flows found.
# ---------------------------------------------------------------------------
SEMANTIC_SUMMARY_MAX = 400
SEMANTIC_NOTE_MAX = 120
STORE_MEDIA = ("json_file", "plist_file", "sqlite", "user_defaults", "keychain", "in_memory", "mixed")
# The mechanical persistence a medium must be compatible with.
STORE_MEDIUM_OF_PERSISTENCE = {
    "file": {"json_file", "plist_file", "sqlite", "mixed"},
    "defaults": {"user_defaults", "mixed"},
    "keychain": {"keychain", "mixed"},
    "unobserved": {"in_memory", "mixed"},
}
# Field specs: ("enum", values) | ("list_enum", values) | ("str", max) | ("list_str", max)
# | ("bool",) | ("int",) | ("keys", {relations}, direction) — node keys that must share an
# edge of one of those relations with the record's node ("in": edge.target is the node,
# "out": edge.source is the node, "any") | ("types",) declared Swift type names
# | ("endpoints",) endpoint labels on the map | ("triggers",) trigger ids | ("pages",) page ids.
CONSTRUCT_SCHEMAS: dict[str, dict[str, tuple[Any, ...]]] = {
    "store": {
        "medium": ("enum", STORE_MEDIA),
        "location": ("str", 120),
        "record_type": ("types",),
        "keyed_by": ("str", 80),
        "written_when": ("list_enum", ("on_change", "debounced", "on_background", "on_launch", "explicit_save", "never")),
        "read_when": ("list_enum", ("on_launch", "on_page_appear", "on_demand", "on_event")),
        "readers": ("keys", {"uses", "loads"}, "in"),
        "writers": ("keys", {"uses", "loads"}, "in"),
        "retention": ("enum", ("forever", "bounded_count", "bounded_age", "session")),
        "failure_mode": ("enum", ("throws", "logs_and_continues", "silent", "resets_store")),
        "sensitive": ("bool",),
    },
    "external": {
        "protocol": ("enum", ("websocket_jsonrpc", "https_rest", "https_sse", "framework_api", "os_service", "on_device_library", "file_system")),
        "auth": ("enum", ("none", "api_key", "oauth", "device_token", "entitlement", "user_consent")),
        "direction": ("enum", ("outbound", "inbound", "both")),
        "failure_visible_as": ("str", 120),
        "namespaces_or_apis": ("list_str", 60),
    },
    "transport": {
        "concurrency_model": ("enum", ("main_actor", "actor", "lock_guarded", "queue_confined", "mixed")),
        "reconnect_policy": ("str", 160),
        "backpressure": ("enum", ("none", "batched_delivery", "bounded_queue", "drop_oldest", "await_ack")),
        "shared_by": ("pages",),
    },
    "pool": {
        "concurrency_model": ("enum", ("main_actor", "actor", "lock_guarded", "queue_confined", "mixed")),
        "settles_by": ("str", 120),
        "cancellation": ("str", 120),
    },
    "engine": {
        "runtime": ("keys", {"runs-on"}, "out"),
        "model_ids": ("list_str", 80),
        "memory_floor_gb": ("int",),
        "loaded_when": ("enum", ("on_launch", "on_first_use", "on_setting_change", "on_page_appear")),
        "unloaded_when": ("enum", ("never", "on_memory_pressure", "on_setting_change", "on_page_disappear", "explicit")),
    },
    "provider": {
        "supplies": ("list_str", 60),
        "configures": ("keys", {"configures"}, "out"),
        "loads": ("keys", {"loads"}, "out"),
    },
    "client": {
        "wraps": ("keys", {"implements"}, "out"),
        "error_mapping": ("str", 160),
    },
    "endpoint": {
        "purpose": ("str", 200),
        "request_shape": ("str", 120),
        "response_shape": ("str", 120),
        "idempotent": ("bool",),
        "streams": ("bool",),
    },
    "page": {
        "purpose": ("str", 200),
        "entry_triggers": ("triggers",),
        "owns_state_in": ("page_nodes",),
    },
    "surface": {
        "purpose": ("str", 200),
        "state": ("list_str", 80),
        "reacts_to": ("list_str", 60),
    },
    "seam": {
        "purpose": ("str", 200),
        "conformers": ("keys", {"conforms", "implements"}, "in"),
    },
}
SURFACE_KINDS = {"caller", "subscriber", "hub"}


def construct_kind(node: dict[str, Any]) -> str | None:
    """The schema a node is described with, or None for kinds that carry no record."""
    kind = node["kind"]
    if kind == "owner":
        roles = set(node.get("roles") or [])
        if "transport" in roles:
            return "transport"
        if "engine" in roles:
            return "engine"
        if "pool" in roles:
            return "pool"
        return "surface"
    if kind in SURFACE_KINDS:
        return "surface"
    if kind in CONSTRUCT_SCHEMAS:
        return kind
    return None


def bounded_files(node: dict[str, Any], interplay: dict[str, Any], by_id: dict[str, dict[str, Any]],
                  externals: dict[str, Any] | None = None) -> set[str]:
    """The files a record about ``node`` may cite: its own, its neighbours', and for an
    external system the files its signatures matched."""
    paths: set[str] = set()
    if node.get("path"):
        paths.add(node["path"])
    for edge in interplay["edges"]:
        other = None
        if edge["source"] == node["id"]:
            other = by_id.get(edge["target"])
        elif edge["target"] == node["id"]:
            other = by_id.get(edge["source"])
        if other and other.get("path"):
            paths.add(other["path"])
    if node["kind"] == "external" and externals:
        for system in externals.get("systems", []):
            if system["id"] == node.get("system_id"):
                for path in system.get("paths", []) or []:
                    if isinstance(path, str):
                        paths.add(path)
                for hit in system.get("usage", []) or []:
                    for path in (hit.get("files") or []) if isinstance(hit, dict) else []:
                        if isinstance(path, str):
                            paths.add(path)
    return paths


def page_files(page_id: str, interplay: dict[str, Any], files: list[dict[str, Any]] | None = None) -> set[str]:
    """A page record may cite the files of the page's constructs and of its root views."""
    paths = {node["path"] for node in interplay["nodes"] if node.get("page") == page_id and node.get("path")}
    page = next((p for p in interplay.get("pages", []) if p["id"] == page_id), None)
    if page and files:
        roots = set(page.get("roots", []))
        for item in files:
            if roots & set(item["declarations"]):
                paths.add(item["path"])
    return paths


def validate_evidence_sites(raw: Any, allowed: set[str], line_counts: dict[str, int], owner: str) -> list[dict[str, Any]]:
    if not isinstance(raw, list) or not raw:
        raise ArchitectureError(f"{owner} needs at least one evidence site")
    sites: list[dict[str, Any]] = []
    for item in raw:
        if not isinstance(item, dict) or not isinstance(item.get("path"), str):
            raise ArchitectureError(f"{owner} evidence entries must be objects with a path")
        path = item["path"]
        if path not in allowed:
            raise ArchitectureError(f"{owner} cites {path}, outside its bounded file set")
        line = item.get("line", 1)
        if not isinstance(line, int) or line < 1 or (path in line_counts and line > line_counts[path]):
            raise ArchitectureError(f"{owner} cites {path}:{line}, which is not a line of that file")
        sites.append({"path": path, "line": line})
    return sorted({(site["path"], site["line"]): site for site in sites}.values(), key=lambda s: (s["path"], s["line"]))


def cited_hash(paths: set[str], text_by_path: dict[str, str]) -> str:
    digest = hashlib.sha256()
    for path in sorted(paths):
        digest.update(path.encode("utf-8"))
        digest.update(b"\0")
        digest.update(text_by_path.get(path, "").encode("utf-8"))
        digest.update(b"\0")
    return digest.hexdigest()


def validate_construct_record(raw: dict[str, Any], interplay: dict[str, Any], files: list[dict[str, Any]],
                              externals: dict[str, Any] | None = None) -> dict[str, Any]:
    """Validate one record against the model; returns the normalised record.

    Raises ArchitectureError naming the field, so the agent can report exactly why
    a model response was rejected and the build can refuse a hand edit that drifts.
    """
    by_id = {node["id"]: node for node in interplay["nodes"]}
    by_key = {node["history_key"]: node for node in interplay["nodes"] if node["kind"] != "operation"}
    page_labels = {page["id"] for page in interplay.get("pages", [])}
    text_by_path = {item["path"]: item["_text"] for item in files if "_text" in item}
    line_counts = {item["path"]: item["line_count"] for item in files}
    declared_types = {name for item in files for name in item["declarations"]}
    key = raw.get("key")
    if not isinstance(key, str) or not key:
        raise ArchitectureError("construct record needs a key")
    owner = f"construct {key}"
    if key.startswith("page:"):
        page_id = key.split(":", 1)[1]
        if page_id not in page_labels:
            raise ArchitectureError(f"{owner} names a page that is not on the map")
        node = None
        expected_kind = "page"
        allowed = page_files(page_id, interplay, files)
    else:
        node = by_key.get(key)
        if node is None:
            raise ArchitectureError(f"{owner} is not a construct on the map; remove or re-key it")
        expected_kind = construct_kind(node)
        if expected_kind is None:
            raise ArchitectureError(f"{owner} is a {node['kind']}, which carries no record")
        allowed = bounded_files(node, interplay, by_id, externals)
    if raw.get("kind") != expected_kind:
        raise ArchitectureError(f"{owner} must have kind {expected_kind!r}, not {raw.get('kind')!r}")
    summary = raw.get("summary")
    if not isinstance(summary, str) or not summary.strip():
        raise ArchitectureError(f"{owner} needs a summary")
    if len(summary) > SEMANTIC_SUMMARY_MAX:
        raise ArchitectureError(f"{owner} summary exceeds {SEMANTIC_SUMMARY_MAX} characters")
    schema = CONSTRUCT_SCHEMAS[expected_kind]
    body: dict[str, Any] = {}
    fields = raw.get("fields")
    if fields is None:
        fields = {}
    if not isinstance(fields, dict):
        raise ArchitectureError(f"{owner} fields must be an object")
    for name, value in fields.items():
        spec = schema.get(name)
        if spec is None:
            raise ArchitectureError(f"{owner} has a field {name!r} that the {expected_kind} schema does not define")
        body[name] = validate_construct_field(name, value, spec, node, interplay, by_key, declared_types, page_labels, owner)
    # Cross-field mechanics the model may refine but not contradict.
    if expected_kind == "store" and node is not None:
        persistence = (node.get("store") or {}).get("persistence") or ["unobserved"]
        medium = body.get("medium")
        if medium:
            compatible = set().union(*(STORE_MEDIUM_OF_PERSISTENCE.get(p, set()) for p in persistence))
            if medium not in compatible and medium != "mixed":
                raise ArchitectureError(f"{owner} claims medium {medium!r} but the source shows {', '.join(persistence)}")
        if "keychain" in persistence and body.get("sensitive") is False:
            raise ArchitectureError(f"{owner} is keychain-backed; sensitive cannot be false")
    evidence = validate_evidence_sites(raw.get("evidence"), allowed, line_counts, owner)
    open_questions = normalized_strings(raw.get("open_questions", []))
    for question in open_questions:
        if len(question) > 200:
            raise ArchitectureError(f"{owner} has an open question over 200 characters")
    cited = {site["path"] for site in evidence}
    current_hash = cited_hash(cited, text_by_path)
    recorded_hash = raw.get("cited_hash")
    return {
        "key": key, "kind": expected_kind, "summary": summary.strip(), "fields": body,
        "open_questions": open_questions, "evidence": evidence,
        "source_revision": str(raw.get("source_revision", "unknown")), "model": str(raw.get("model", "unknown")),
        "cited_hash": current_hash if recorded_hash is None else str(recorded_hash),
        "stale": bool(recorded_hash is not None and recorded_hash != current_hash),
        "authority": "synthesized",
    }


def validate_construct_field(name: str, value: Any, spec: tuple[Any, ...], node: dict[str, Any] | None,
                             interplay: dict[str, Any], by_key: dict[str, dict[str, Any]], declared_types: set[str],
                             page_labels: set[str], owner: str) -> Any:
    kind = spec[0]
    if kind == "enum":
        if value not in spec[1]:
            raise ArchitectureError(f"{owner}.{name} must be one of {', '.join(spec[1])}; got {value!r}")
        return value
    if kind == "list_enum":
        if not isinstance(value, list) or not all(item in spec[1] for item in value):
            raise ArchitectureError(f"{owner}.{name} must be a list drawn from {', '.join(spec[1])}")
        return sorted(set(value))
    if kind == "str":
        if not isinstance(value, str) or len(value) > spec[1]:
            raise ArchitectureError(f"{owner}.{name} must be a string of at most {spec[1]} characters")
        return value.strip()
    if kind == "list_str":
        if not isinstance(value, list) or not all(isinstance(item, str) and len(item) <= spec[1] for item in value):
            raise ArchitectureError(f"{owner}.{name} must be a list of strings of at most {spec[1]} characters")
        return sorted({item.strip() for item in value if item.strip()})
    if kind == "bool":
        if not isinstance(value, bool):
            raise ArchitectureError(f"{owner}.{name} must be true or false")
        return value
    if kind == "int":
        if not isinstance(value, int) or isinstance(value, bool) or value < 0:
            raise ArchitectureError(f"{owner}.{name} must be a non-negative integer")
        return value
    if kind == "types":
        if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
            raise ArchitectureError(f"{owner}.{name} must be a list of type names")
        unknown = sorted(item for item in value if item not in declared_types)
        if unknown:
            raise ArchitectureError(f"{owner}.{name} names types not declared in the source tree: {', '.join(unknown)}")
        return sorted(set(value))
    if kind == "keys":
        relations, direction = spec[1], spec[2]
        if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
            raise ArchitectureError(f"{owner}.{name} must be a list of construct keys")
        if node is None:
            raise ArchitectureError(f"{owner}.{name} cannot be validated without a node")
        for item in value:
            other = by_key.get(item)
            if other is None:
                raise ArchitectureError(f"{owner}.{name} names {item!r}, which is not on the map")
            linked = any(
                edge["relation"] in relations and (
                    (direction in ("in", "any") and edge["source"] == other["id"] and edge["target"] == node["id"]) or
                    (direction in ("out", "any") and edge["source"] == node["id"] and edge["target"] == other["id"])
                )
                for edge in interplay["edges"]
            )
            if not linked:
                raise ArchitectureError(f"{owner}.{name} names {item!r} but no {'/'.join(sorted(relations))} edge links them")
        return sorted(set(value))
    if kind == "endpoints":
        labels = {n["label"] for n in interplay["nodes"] if n["kind"] == "endpoint"}
        if not isinstance(value, list) or not all(item in labels for item in value):
            raise ArchitectureError(f"{owner}.{name} must name endpoint namespaces on the map")
        return sorted(set(value))
    if kind == "triggers":
        ids = {t["id"] for t in interplay.get("triggers", [])}
        if not isinstance(value, list) or not all(item in ids for item in value):
            raise ArchitectureError(f"{owner}.{name} must be trigger ids from the map")
        return sorted(set(value))
    if kind == "pages":
        if not isinstance(value, list) or not all(item in page_labels for item in value):
            raise ArchitectureError(f"{owner}.{name} must be page ids from the map")
        return sorted(set(value))
    if kind == "page_nodes":
        page_id = owner.split("page:", 1)[1] if "page:" in owner else None
        if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
            raise ArchitectureError(f"{owner}.{name} must be a list of construct keys")
        for item in value:
            other = by_key.get(item)
            if other is None or other.get("page") != page_id:
                raise ArchitectureError(f"{owner}.{name} names {item!r}, which is not a construct of that page")
        return sorted(set(value))
    raise ArchitectureError(f"unknown field spec {kind!r}")


def load_constructs(interplay: dict[str, Any], files: list[dict[str, Any]], externals: dict[str, Any] | None = None) -> list[dict[str, Any]]:
    """Read, validate and fold the construct records onto their nodes as `semantic`."""
    if not CONSTRUCTS_PATH.is_file():
        interplay["constructs"] = {"described": 0, "stale": 0}
        return []
    raw = load_json(CONSTRUCTS_PATH)
    if raw.get("schema_version") != "1.0.0" or not isinstance(raw.get("records"), list):
        raise ArchitectureError("architecture/semantic/constructs.json has an unsupported schema")
    records: list[dict[str, Any]] = []
    seen: set[str] = set()
    for entry in raw["records"]:
        if not isinstance(entry, dict):
            raise ArchitectureError("construct records must be objects")
        try:
            record = validate_construct_record(entry, interplay, files, externals)
        except ArchitectureError as exc:
            gate("constructs_invalid", str(exc))
            continue
        if record["key"] in seen:
            gate("constructs_invalid", f"duplicate construct record {record['key']}")
            continue
        seen.add(record["key"])
        records.append(record)
    by_key = {node["history_key"]: node for node in interplay["nodes"]}
    for record in records:
        node = by_key.get(record["key"])
        if node is not None:
            node["semantic"] = {k: v for k, v in record.items() if k != "key"}
    for page in interplay.get("pages", []):
        record = next((r for r in records if r["key"] == f"page:{page['id']}"), None)
        if record is not None:
            page["semantic"] = {k: v for k, v in record.items() if k != "key"}
    interplay["constructs"] = {"described": len(records), "stale": sum(1 for r in records if r["stale"])}
    return records


FLOW_ID_RE = re.compile(r"^[a-z][a-z0-9-]{2,60}$")
FLOW_MIN_STEPS, FLOW_MAX_STEPS = 3, 12
# A flow belongs to one user journey: starting the app, doing a chat turn, or
# entering and using one navigation page. The site orders and groups by this.
FLOW_JOURNEYS = ("launch", "chat_turn", "page")


def validate_flow(raw: dict[str, Any], interplay: dict[str, Any], files: list[dict[str, Any]]) -> dict[str, Any]:
    """Validate one flow: a path over edges the map draws. Returns the flow with
    ``status`` traceable and no problems, or raises for schema errors. A step over
    an edge that no longer exists is not a schema error: it is recorded as a problem
    so the `flows_traceable` invariant can fail the build with the step named."""
    by_key = {node["history_key"]: node for node in interplay["nodes"] if node["kind"] != "operation"}
    key_of = {node["id"]: node["history_key"] for node in interplay["nodes"]}
    page_labels = {page["id"]: page["label"] for page in interplay.get("pages", [])}
    edges = {(key_of[e["source"]], key_of[e["target"]], e["relation"]) for e in interplay["edges"] if e["source"] in key_of and e["target"] in key_of}
    triggers = {t["id"]: t for t in interplay.get("triggers", [])}
    for trigger in triggers.values():
        surface = surface_node_for(interplay["nodes"], trigger["surface"])
        if surface is not None and trigger.get("page"):
            edges.add((f"page:{trigger['page']}", surface["history_key"], "triggers"))
    flow_id = raw.get("id")
    if not isinstance(flow_id, str) or not FLOW_ID_RE.match(flow_id):
        raise ArchitectureError(f"flow id {flow_id!r} must be a kebab-case slug")
    owner = f"flow {flow_id}"
    title = raw.get("title")
    if not isinstance(title, str) or not title.strip() or len(title) > 80:
        raise ArchitectureError(f"{owner} needs a title of at most 80 characters")
    summary = raw.get("summary")
    if not isinstance(summary, str) or not summary.strip() or len(summary) > SEMANTIC_SUMMARY_MAX:
        raise ArchitectureError(f"{owner} needs a summary of at most {SEMANTIC_SUMMARY_MAX} characters")
    steps = raw.get("steps")
    if not isinstance(steps, list) or not (FLOW_MIN_STEPS <= len(steps) <= FLOW_MAX_STEPS):
        raise ArchitectureError(f"{owner} needs between {FLOW_MIN_STEPS} and {FLOW_MAX_STEPS} steps")
    problems: list[str] = []
    visited: set[str] = set()
    normalized_steps: list[dict[str, Any]] = []
    for index, step in enumerate(steps, start=1):
        if not isinstance(step, dict) or not all(isinstance(step.get(k), str) for k in ("from", "to", "relation")):
            raise ArchitectureError(f"{owner} step {index} needs from, to and relation strings")
        source, target, relation = step["from"], step["to"], step["relation"]
        for key in (source, target):
            if not (key in by_key or (key.startswith("page:") and key.split(":", 1)[1] in page_labels)):
                raise ArchitectureError(f"{owner} step {index} names {key!r}, which is not on the map")
        note = step.get("note", "")
        if not isinstance(note, str) or len(note) > SEMANTIC_NOTE_MAX:
            raise ArchitectureError(f"{owner} step {index} note must be a string of at most {SEMANTIC_NOTE_MAX} characters")
        if index > 1 and source not in visited:
            raise ArchitectureError(f"{owner} step {index} starts at {source!r}, which no earlier step reached")
        if (source, target, relation) not in edges:
            problems.append(f"step {index}: no {relation} edge from {source} to {target} on the map")
        visited.update({source, target})
        normalized_steps.append({"from": source, "to": target, "relation": relation, "note": note.strip()})
    trigger_id = raw.get("trigger")
    if trigger_id is not None:
        trigger = triggers.get(trigger_id)
        if trigger is None:
            problems.append(f"trigger {trigger_id} is not on the map")
        else:
            first = normalized_steps[0]["from"]
            first_label = by_key[first]["label"] if first in by_key else first
            if first_label != trigger["surface"] and first != f"page:{trigger.get('page')}":
                raise ArchitectureError(f"{owner} starts at {first!r} but its trigger fires {trigger['surface']}")
    outcome = raw.get("outcome", "")
    if not isinstance(outcome, str) or len(outcome) > 200:
        raise ArchitectureError(f"{owner} outcome must be a string of at most 200 characters")
    journey = raw.get("journey")
    if journey not in FLOW_JOURNEYS:
        raise ArchitectureError(f"{owner} journey must be one of {', '.join(FLOW_JOURNEYS)}")
    page_id = raw.get("page")
    if journey == "page":
        if page_id not in page_labels or page_id in (LAUNCH_PAGE_ID, "chat"):
            raise ArchitectureError(f"{owner} is a page journey and must name a navigation page other than launch or chat")
    else:
        page_id = LAUNCH_PAGE_ID if journey == "launch" else "chat"
    if trigger_id is not None and trigger_id in triggers and triggers[trigger_id].get("page") != page_id:
        raise ArchitectureError(f"{owner} is on {page_id} but its trigger fires on {triggers[trigger_id].get('page')}")
    interaction = raw.get("interaction", "")
    if not isinstance(interaction, str) or len(interaction) > 80:
        raise ArchitectureError(f"{owner} interaction must be a string of at most 80 characters")
    allowed: set[str] = set()
    for step in normalized_steps:
        for key in (step["from"], step["to"]):
            node = by_key.get(key)
            if node and node.get("path"):
                allowed.add(node["path"])
            if key.startswith("page:"):
                allowed |= page_files(key.split(":", 1)[1], interplay, files)
    # The views that hold the journey's triggers are where a flow starts; they may be cited too.
    allowed |= {t["path"] for t in triggers.values() if t.get("page") == page_id and t.get("path")}
    line_counts = {item["path"]: item["line_count"] for item in files}
    evidence = validate_evidence_sites(raw.get("evidence"), allowed, line_counts, owner)
    return {
        "id": flow_id, "title": title.strip(), "summary": summary.strip(), "trigger": trigger_id,
        "journey": journey, "page": page_id, "interaction": interaction.strip(),
        "steps": normalized_steps, "outcome": outcome.strip(), "evidence": evidence,
        "source_revision": str(raw.get("source_revision", "unknown")), "model": str(raw.get("model", "unknown")),
        "status": "broken" if problems else "traceable", "problems": problems, "authority": "synthesized",
    }


def load_flows(interplay: dict[str, Any], files: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Read and validate the flows; fold them onto the interplay and cross-link nodes."""
    interplay["flows"] = []
    if not FLOWS_PATH.is_file():
        return []
    raw = load_json(FLOWS_PATH)
    if raw.get("schema_version") != "1.0.0" or not isinstance(raw.get("flows"), list):
        raise ArchitectureError("architecture/semantic/flows.json has an unsupported schema")
    flows: list[dict[str, Any]] = []
    seen: set[str] = set()
    for entry in raw["flows"]:
        if not isinstance(entry, dict):
            raise ArchitectureError("flows must be objects")
        try:
            flow = validate_flow(entry, interplay, files)
        except ArchitectureError as exc:
            gate("flows_invalid", str(exc))
            continue
        if flow["id"] in seen:
            gate("flows_invalid", f"duplicate flow id {flow['id']}")
            continue
        seen.add(flow["id"])
        flows.append(flow)
    page_order = {page["id"]: index for index, page in enumerate(interplay.get("pages", []))}
    flows.sort(key=lambda item: (FLOW_JOURNEYS.index(item["journey"]), page_order.get(item["page"], 99), item["id"]))
    by_key = {node["history_key"]: node for node in interplay["nodes"]}
    for flow in flows:
        for step in flow["steps"]:
            for key in (step["from"], step["to"]):
                node = by_key.get(key)
                if node is not None:
                    node.setdefault("flows", [])
                    if flow["id"] not in node["flows"]:
                        node["flows"].append(flow["id"])
    interplay["flows"] = flows
    return flows


# ---------------------------------------------------------------------------
# History keys and the snapshot shape.
#
# The history walk (scripts/build_architecture_history.py) derives the System
# map at many commits and diffs consecutive points, so every drawn node needs a
# key that survives unrelated edits. Interplay ids are stable for everything
# except resources and operations, whose ids hash the declaring line. A resource
# is re-keyed by what it is (component, owning type, kind, field name); an
# operation keeps its id because operations are actions, never drawn as boxes,
# and stay out of the shape.
# ---------------------------------------------------------------------------
SHAPE_NODE_FIELDS = (
    "kind", "label", "page", "component", "owner_type", "sub_kind", "roles", "protocol",
    "namespaces", "system_id", "method_count", "file_count", "hit_count", "lock_labels",
)
SURFACE_KIND_ORDER = ("caller", "subscriber", "hub", "store", "owner")


def history_key(node: dict[str, Any]) -> str:
    if node["kind"] == "resource":
        return ":".join([
            "resource", str(node.get("component") or "unassigned"), str(node.get("owner_type") or ""),
            str(node.get("sub_kind") or ""), str(node["label"]),
        ])
    if node["kind"] == "endpoint":
        # An endpoint id hashes the owning transport's type name; the namespace a
        # renamed transport serves is the same namespace, so the key names only
        # the protocol and the namespace.
        return f"endpoint:{node.get('protocol') or ''}:{node['label']}"
    return str(node["id"])


def assign_history_keys(interplay: dict[str, Any]) -> None:
    """Key every node for diffing across commits. Two drawn nodes sharing a key is a
    build error today (the map would be ambiguous) and a recorded gap in snapshot
    mode, where an older tree may have had, say, two transports serving one namespace."""
    seen: dict[str, str] = {}
    for node in interplay["nodes"]:
        key = history_key(node)
        node["history_key"] = key
        if node["kind"] == "operation":
            continue
        if key in seen and seen[key] != node["id"]:
            gate("history_key_collision", f"history key {key!r} is shared by {seen[key]} and {node['id']}")
        seen[key] = node["id"]


def surface_node_for(nodes: list[dict[str, Any]], label: str) -> dict[str, Any] | None:
    """The drawn node a trigger lands on: the same choice the site makes."""
    candidates = [node for node in nodes if node.get("label") == label and node["kind"] in SURFACE_KIND_ORDER]
    candidates.sort(key=lambda node: SURFACE_KIND_ORDER.index(node["kind"]))
    return candidates[0] if candidates else None


def shape_of(model: dict[str, Any]) -> dict[str, Any]:
    """One point on the timeline: the drawn nodes and edges, keyed for diffing.

    Trigger edges are aggregated the way the map draws them (one page → surface
    edge per pair); their page sources are carried as ``page`` pseudo-nodes so
    the union table can index them. Fidelity carries what today's curation could
    not account for at this commit, as counts, so the page can say so.
    """
    interplay = model["interplay"]
    keyed: dict[str, dict[str, Any]] = {}
    for node in interplay["nodes"]:
        if node["kind"] == "operation":
            continue
        meta: dict[str, Any] = {"k": node["history_key"]}
        for field in SHAPE_NODE_FIELDS:
            value = node.get(field)
            if value not in (None, [], {}, ""):
                meta[field] = sorted(value) if isinstance(value, set) else value
        store = node.get("store")
        if isinstance(store, dict):
            meta["store"] = {"persistence": store.get("persistence", []), "artifacts": store.get("artifacts", [])}
        keyed[meta["k"]] = meta
    key_of = {node["id"]: node["history_key"] for node in interplay["nodes"]}
    edges: set[tuple[str, str, str, str]] = set()
    for edge in interplay["edges"]:
        source = key_of.get(edge["source"])
        target = key_of.get(edge["target"])
        if source in keyed and target in keyed:
            edges.add((source, target, str(edge["relation"]), str(edge.get("class") or "")))
    page_labels = {page["id"]: page["label"] for page in interplay.get("pages", [])}
    for trigger in interplay.get("triggers", []):
        page = trigger.get("page")
        if page not in page_labels:
            continue
        surface = surface_node_for(interplay["nodes"], str(trigger.get("surface") or ""))
        if surface is None:
            continue
        page_key = f"page:{page}"
        keyed.setdefault(page_key, {"k": page_key, "kind": "page", "label": page_labels[page], "page": page})
        edges.add((page_key, surface["history_key"], "triggers", "trigger"))
    invariants = interplay.get("invariants", [])
    return {
        "tree": model["source_tree_sha256"],
        "nodes": sorted(keyed.values(), key=lambda meta: meta["k"]),
        "edges": [list(edge) for edge in sorted(edges)],
        "fidelity": {kind: len(messages) for kind, messages in sorted(FIDELITY.items())},
        "invariants": {
            "holds": sum(1 for item in invariants if item.get("status") == "holds"),
            "violated": sorted(item["id"] for item in invariants if item.get("status") != "holds"),
        },
    }


# ───────────────────────────── CI gates ──────────────────────────────────────
# The pipeline plane: every GitHub Actions workflow is read deterministically,
# its jobs become gate nodes, `needs` and artifact hand-offs become wires, and
# the jobs that run on pull requests feed one AND gate — the merge. Beneath the
# graph the model separates the RATCHETS (metric floors read from the committed
# baselines), the ARCHITECTURAL checks (SwiftLint custom rules, ArchitectureTests,
# System-map invariants) and the STATIC compiler checks (the `--check` steps that
# recompile generated artifacts and fail on drift). Which workflow belongs to
# which family, and what each ratchet measures, is declared in
# architecture/config.json under `ci`; the compiler fails when a declaration
# names a job that no workflow defines, or a posture job exists that nothing
# declares, so the picture cannot quietly diverge from the pipeline.

WORKFLOWS_DIR = ROOT / ".github/workflows"
SWIFTLINT_CONFIG_PATH = ROOT / ".swiftlint.yml"
SWIFTLINT_BASELINE_PATH = ROOT / ".swiftlint-baseline"
GITLEAKS_IGNORE_PATH = ROOT / ".gitleaksignore"
METRICS_BASELINE_PATH = ROOT / "metrics-baseline.json"
PERF_BASELINE_PATH = ROOT / "perf-baseline.json"

CI_FAMILIES = {
    "behavior": "Does it work?",
    "posture": "Did a tracked metric get worse?",
    "build": "Does it build on every platform?",
    "publication": "Do the generated artifacts match the tree, and does the site deploy?",
    "release": "Can a signed build ship?",
    "maintenance": "Manual upkeep of committed artifacts.",
}
CI_RATCHET_SOURCES = {"metrics", "perf", "swiftlint_baseline", "gitleaks_ignore"}
CI_TRIGGER_EVENTS = ("pull_request", "push", "workflow_dispatch", "schedule")
SCRIPT_REFERENCE_RE = re.compile(r"(?<![\w/.-])((?:scripts|\.github/scripts)/[A-Za-z0-9_./-]+\.(?:py|sh|rb))\b")
TOOL_PIN_RE = re.compile(r"^([A-Z][A-Z0-9_]*_VERSION)$")
ARCHITECTURE_TEST_RE = re.compile(r'@Test\(\s*"((?:[^"\\]|\\.)*)"')
CI_LIMITATIONS = [
    "Workflow structure is read from the YAML in .github/workflows; it does not prove a job ran, passed, or is required by branch protection.",
    "A job is drawn as a pull-request gate when its workflow listens to pull_request and its condition does not exclude that event; GitHub's required-checks list is repository configuration and is not read here.",
    "Ratchet values are the committed baselines CI compares against, not a fresh measurement of this tree.",
]


class YamlMap(dict):
    """A mapping that remembers the 1-based line each key was declared on."""

    def __init__(self) -> None:
        super().__init__()
        self.lines: dict[str, int] = {}


class YamlSubsetError(ArchitectureError):
    pass


def _yaml_split_key(content: str) -> tuple[str, str] | None:
    """Split ``key: rest`` at the first unquoted ``:`` followed by space or end."""
    quote: str | None = None
    for index, char in enumerate(content):
        if quote:
            if char == quote:
                quote = None
            continue
        if char in "\"'" and index == 0:
            quote = char
            continue
        if char == ":" and (index + 1 == len(content) or content[index + 1] in " \t"):
            key = content[:index].strip()
            if key.startswith(("'", '"')) and key.endswith(key[0]) and len(key) >= 2:
                key = key[1:-1]
            if not key or "{" in key or "[" in key:
                return None
            return key, content[index + 1:]
    return None


def _yaml_strip_comment(content: str) -> str:
    quote: str | None = None
    for index, char in enumerate(content):
        if quote:
            if char == quote:
                quote = None
            continue
        if char in "\"'":
            quote = char
        elif char == "#" and (index == 0 or content[index - 1] in " \t"):
            return content[:index].rstrip()
    return content.rstrip()


def _yaml_scalar(text: str) -> Any:
    text = text.strip()
    if text == "":
        return None
    if text[0] == '"' and text.endswith('"') and len(text) >= 2:
        body = text[1:-1]
        return re.sub(r'\\(["\\/])', r"\1", body).replace("\\n", "\n").replace("\\t", "\t")
    if text[0] == "'" and text.endswith("'") and len(text) >= 2:
        return text[1:-1].replace("''", "'")
    if text[0] == "[" and text.endswith("]"):
        inner = text[1:-1].strip()
        if not inner:
            return []
        items: list[str] = []
        quote: str | None = None
        current = ""
        for char in inner:
            if quote:
                current += char
                if char == quote:
                    quote = None
            elif char in "\"'":
                quote = char
                current += char
            elif char == ",":
                items.append(current)
                current = ""
            else:
                current += char
        items.append(current)
        return [_yaml_scalar(item) for item in items]
    if text == "{}":
        return YamlMap()
    if text in ("~", "null"):
        return None
    return text


class _YamlSubsetParser:
    """A deterministic parser for the YAML the workflows and lint config use:
    block mappings and sequences, literal/folded block scalars, flow sequences,
    quoted and plain scalars, comments. Everything is a string, a list, a
    YamlMap or None — no implicit typing, so ``on`` stays ``on`` and ``0.65.0``
    stays a version."""

    def __init__(self, text: str) -> None:
        self.raw = text.splitlines()
        # [indent, content, line_number]; content has comments stripped.
        self.lines: list[list[Any]] = []
        for number, raw in enumerate(self.raw, start=1):
            stripped = raw.lstrip(" ")
            if stripped.startswith("\t") or "\t" in raw[: len(raw) - len(stripped)]:
                raise YamlSubsetError(f"tab indentation at line {number}")
            content = _yaml_strip_comment(stripped)
            if not content or content == "---":
                self.lines.append([None, "", number])
                continue
            self.lines.append([len(raw) - len(stripped), content, number])
        self.position = 0

    def peek(self) -> list[Any] | None:
        while self.position < len(self.lines) and self.lines[self.position][0] is None:
            self.position += 1
        return self.lines[self.position] if self.position < len(self.lines) else None

    def advance(self) -> None:
        self.position += 1

    def parse_document(self) -> Any:
        first = self.peek()
        if first is None:
            return YamlMap()
        value = self.parse_node(first[0])
        trailing = self.peek()
        if trailing is not None:
            raise YamlSubsetError(f"unexpected content at line {trailing[2]}")
        return value

    def parse_node(self, indent: int) -> Any:
        line = self.peek()
        if line is None or line[0] < indent:
            return None
        if line[1] == "-" or line[1].startswith("- "):
            return self.parse_sequence(line[0])
        return self.parse_mapping(line[0])

    def parse_mapping(self, indent: int) -> YamlMap:
        result = YamlMap()
        while True:
            line = self.peek()
            if line is None or line[0] < indent:
                break
            if line[0] > indent:
                raise YamlSubsetError(f"unexpected indentation at line {line[2]}")
            if line[1] == "-" or line[1].startswith("- "):
                break
            split = _yaml_split_key(line[1])
            if split is None:
                raise YamlSubsetError(f"expected a mapping entry at line {line[2]}")
            key, rest = split
            self.advance()
            result.lines[key] = line[2]
            rest = rest.strip()
            if rest == "":
                following = self.peek()
                if following is not None and following[0] > indent:
                    result[key] = self.parse_node(following[0])
                elif following is not None and following[0] == indent and (following[1] == "-" or following[1].startswith("- ")):
                    result[key] = self.parse_sequence(indent)
                else:
                    result[key] = None
            elif rest[0] in "|>":
                result[key] = self.parse_block_scalar(indent, rest)
            else:
                result[key] = _yaml_scalar(rest)
        return result

    def parse_sequence(self, indent: int) -> list[Any]:
        items: list[Any] = []
        while True:
            line = self.peek()
            if line is None or line[0] < indent:
                break
            if line[0] > indent:
                raise YamlSubsetError(f"unexpected indentation at line {line[2]}")
            if not (line[1] == "-" or line[1].startswith("- ")):
                break
            rest = line[1][1:].strip()
            if rest == "":
                self.advance()
                following = self.peek()
                items.append(self.parse_node(following[0]) if following is not None and following[0] > indent else None)
            elif rest[0] in "|>":
                self.advance()
                items.append(self.parse_block_scalar(indent, rest))
            elif rest[0] not in "\"'[{" and _yaml_split_key(rest) is not None:
                # `- key: value` opens a mapping whose remaining entries sit two
                # columns in; re-anchor this line there and let the mapping parser
                # consume it with its siblings.
                line[0] = indent + 2
                line[1] = rest
                items.append(self.parse_mapping(indent + 2))
            else:
                self.advance()
                items.append(_yaml_scalar(rest))
        return items

    def parse_block_scalar(self, indent: int, header: str) -> str:
        style = header[0]
        chomp = "clip"
        if "-" in header[1:]:
            chomp = "strip"
        elif "+" in header[1:]:
            chomp = "keep"
        start = self.position
        block: list[str] = []
        block_indent: int | None = None
        while self.position < len(self.raw):
            raw = self.raw[self.position]
            stripped = raw.lstrip(" ")
            if stripped == "":
                block.append("")
                self.position += 1
                continue
            current_indent = len(raw) - len(stripped)
            if current_indent <= indent:
                break
            if block_indent is None:
                block_indent = current_indent
            if current_indent < block_indent:
                break
            block.append(raw[block_indent:])
            self.position += 1
        if self.position == start:
            return ""
        while block and block[-1] == "":
            block.pop()
        if style == "|":
            text = "\n".join(block)
        else:
            # Folded: adjacent lines join with a space, a blank line is a newline.
            paragraphs: list[list[str]] = [[]]
            for line in block:
                if line == "":
                    paragraphs.append([])
                else:
                    paragraphs[-1].append(line)
            text = "\n".join(" ".join(paragraph) for paragraph in paragraphs)
        if chomp == "strip":
            return text
        return text + "\n"


def parse_yaml_subset(text: str) -> Any:
    return _YamlSubsetParser(text).parse_document()


def _as_list(value: Any) -> list[Any]:
    if value is None:
        return []
    if isinstance(value, list):
        return value
    return [value]


SHELL_PREAMBLE_RE = re.compile(
    r"^(?:set\s|export\s|cd\s|mkdir\s|echo\s|if\s|for\s|while\s|fi$|done$|then$|else$|\.\s|[A-Z_][A-Z0-9_]*=)"
)
URL_LINE_RE = re.compile(r"://")


def _first_command_line(run: Any) -> str:
    """The first line of a run block that is a command rather than shell preamble
    (option setting, directory changes, variable assignment, control flow)."""
    fallback = ""
    for line in str(run or "").splitlines():
        candidate = line.strip()
        if not candidate or candidate.startswith("#"):
            continue
        if not fallback:
            fallback = candidate
        if not SHELL_PREAMBLE_RE.match(candidate):
            return candidate.rstrip("\\").strip()[:160]
    return fallback.rstrip("\\").strip()[:160]


def _tool_pins(env: Any, run: Any) -> list[dict[str, str]]:
    """`X_VERSION` env values that the same step interpolates into a download URL."""
    if not isinstance(env, dict):
        return []
    url_lines = [line for line in str(run or "").splitlines() if URL_LINE_RE.search(line)]
    pins: list[dict[str, str]] = []
    for name in sorted(env):
        if not TOOL_PIN_RE.match(str(name)):
            continue
        if any(f"${{{name}}}" in line or f"${name}" in line for line in url_lines):
            pins.append({"name": str(name), "value": str(env[name])})
    return pins


def _job_condition_excludes_pull_requests(condition: str | None) -> bool:
    """`if: github.event_name != 'pull_request'` (the deploy shape) keeps a job off PRs."""
    if not condition:
        return False
    compact = condition.replace(" ", "")
    return "pull_request" in compact and "!=" in compact


def _normalize_triggers(raw: Any, workflow: str) -> list[dict[str, Any]]:
    if raw is None:
        raise ArchitectureError(f"workflow {workflow} declares no triggers")
    if isinstance(raw, str):
        raw = {raw: None}
    if isinstance(raw, list):
        raw = {str(item): None for item in raw}
    triggers: list[dict[str, Any]] = []
    for event in sorted(raw):
        detail = raw[event] if isinstance(raw[event], dict) else {}
        record: dict[str, Any] = {"event": str(event)}
        for field in ("branches", "tags", "paths", "types"):
            values = [str(item) for item in _as_list(detail.get(field))]
            if values:
                record[field] = values
        if event == "workflow_dispatch" and isinstance(detail.get("inputs"), dict):
            record["inputs"] = sorted(str(name) for name in detail["inputs"])
        if event == "schedule":
            record["cron"] = [str(item.get("cron")) for item in _as_list(raw[event]) if isinstance(item, dict)]
        triggers.append(record)
    return triggers


def read_workflows() -> list[dict[str, Any]]:
    """Every workflow file, parsed into workflow and job records with line provenance."""
    if not WORKFLOWS_DIR.is_dir():
        gate("ci", f"{relative(WORKFLOWS_DIR)} is missing; the CI plane is empty")
        return []
    workflows: list[dict[str, Any]] = []
    for path in sorted(WORKFLOWS_DIR.glob("*.yml")) + sorted(WORKFLOWS_DIR.glob("*.yaml")):
        text = path.read_text(encoding="utf-8")
        try:
            document = parse_yaml_subset(text)
        except YamlSubsetError as exc:
            raise ArchitectureError(f"{relative(path)}: {exc}") from exc
        if not isinstance(document, dict):
            raise ArchitectureError(f"{relative(path)} is not a workflow mapping")
        workflow_id = path.stem
        jobs_raw = document.get("jobs")
        if not isinstance(jobs_raw, dict) or not jobs_raw:
            raise ArchitectureError(f"{relative(path)} declares no jobs")
        triggers = _normalize_triggers(document.get("on"), workflow_id)
        events = {trigger["event"] for trigger in triggers}
        jobs: list[dict[str, Any]] = []
        for key in jobs_raw:
            job = jobs_raw[key]
            if not isinstance(job, dict):
                raise ArchitectureError(f"{relative(path)}: job {key} is not a mapping")
            condition = job.get("if")
            condition_text = str(condition).strip() if condition is not None else None
            steps: list[dict[str, Any]] = []
            artifacts_out: list[str] = []
            artifacts_in: list[str] = []
            scripts: set[str] = set()
            pins: list[dict[str, str]] = []
            for step in _as_list(job.get("steps")):
                if not isinstance(step, dict):
                    continue
                uses = step.get("uses")
                run = step.get("run")
                step_scripts = sorted(set(SCRIPT_REFERENCE_RE.findall(str(run or ""))))
                scripts.update(step_scripts)
                with_block = step.get("with") if isinstance(step.get("with"), dict) else {}
                if isinstance(uses, str) and uses.startswith("actions/upload-artifact") and with_block.get("name"):
                    artifacts_out.append(str(with_block["name"]))
                if isinstance(uses, str) and uses.startswith("actions/download-artifact") and with_block.get("name"):
                    artifacts_in.append(str(with_block["name"]))
                pins.extend(_tool_pins(step.get("env"), run))
                first_line = None
                for candidate in ("name", "uses", "run", "id", "if", "with", "env", "working-directory"):
                    if candidate in getattr(step, "lines", {}):
                        first_line = step.lines[candidate] if first_line is None else min(first_line, step.lines[candidate])
                if first_line is None:
                    first_line = job.lines.get("steps", 1) if isinstance(job, YamlMap) else 1
                record: dict[str, Any] = {
                    "name": str(step.get("name") or uses or _first_command_line(run) or "step"),
                    "line": first_line,
                }
                if isinstance(uses, str):
                    record["uses"] = uses
                if run is not None:
                    record["command"] = _first_command_line(run)
                    record["command_lines"] = len([line for line in str(run).splitlines() if line.strip() and not line.strip().startswith("#")])
                if step_scripts:
                    record["scripts"] = step_scripts
                if step.get("if") is not None:
                    record["condition"] = str(step["if"]).strip()
                steps.append(record)
            needs = [f"{workflow_id}/{item}" for item in _as_list(job.get("needs"))]
            disabled = condition_text is not None and condition_text.lower() in ("false", "${{ false }}")
            if disabled:
                role = "disabled"
            elif "pull_request" in events and not _job_condition_excludes_pull_requests(condition_text):
                role = "gate"
            elif "push" in events or "schedule" in events:
                role = "post-merge"
            else:
                role = "manual"
            jobs.append({
                "id": f"{workflow_id}/{key}",
                "workflow": workflow_id,
                "key": str(key),
                "name": str(job.get("name") or key),
                "runs_on": str(job.get("runs-on") or ""),
                "needs": needs,
                "condition": condition_text,
                "role": role,
                "steps": steps,
                "step_count": len(steps),
                "scripts": sorted(scripts),
                "pins": pins,
                "artifacts_out": artifacts_out,
                "artifacts_in": artifacts_in,
                "evidence": {"path": relative(path), "line": jobs_raw.lines.get(key, 1) if isinstance(jobs_raw, YamlMap) else 1},
            })
        workflows.append({
            "id": workflow_id,
            "name": str(document.get("name") or workflow_id),
            "path": relative(path),
            "triggers": triggers,
            "events": sorted(events),
            "jobs": [job["id"] for job in jobs],
            "_jobs": jobs,
        })
    return workflows


def _ratchet_current(source: dict[str, Any], ratchet_id: str) -> dict[str, Any]:
    kind = source.get("kind")
    if kind == "metrics":
        if not METRICS_BASELINE_PATH.is_file():
            gate("ci", f"ratchet {ratchet_id}: {relative(METRICS_BASELINE_PATH)} is missing")
            return {}
        metrics = load_json(METRICS_BASELINE_PATH)
        key = str(source.get("key"))
        if key not in metrics:
            raise ArchitectureError(f"ratchet {ratchet_id} names metrics key {key!r} which {relative(METRICS_BASELINE_PATH)} lacks")
        block = metrics[key]
        if key == "coverage":
            return {
                "kind": "coverage",
                "percent": block["testable_pct"],
                "covered": block["testable_covered"],
                "count": block["testable_count"],
                "layers": {name: {"percent": item["pct"], "covered": item["covered"], "count": item["count"]}
                           for name, item in sorted(block.get("layers", {}).items())} if isinstance(block.get("layers"), dict) else {},
                "uncovered_files": len(block.get("uncovered", {})),
            }
        return {
            "kind": "count",
            "total": block["total"],
            "counts": dict(sorted(block.get("counts", {}).items())),
            "sites": len(block.get("sites", [])),
        }
    if kind == "perf":
        if not PERF_BASELINE_PATH.is_file():
            gate("ci", f"ratchet {ratchet_id}: {relative(PERF_BASELINE_PATH)} is missing")
            return {}
        return {"kind": "counters", "counts": dict(sorted(load_json(PERF_BASELINE_PATH)["counts"].items()))}
    if kind == "swiftlint_baseline":
        if not SWIFTLINT_BASELINE_PATH.is_file():
            gate("ci", f"ratchet {ratchet_id}: {relative(SWIFTLINT_BASELINE_PATH)} is missing")
            return {}
        entries = json.loads(SWIFTLINT_BASELINE_PATH.read_text(encoding="utf-8"))
        by_rule = Counter(str(entry["violation"]["ruleIdentifier"]) for entry in entries)
        return {"kind": "count", "total": len(entries), "counts": dict(sorted(by_rule.items())), "sites": len(entries)}
    if kind == "gitleaks_ignore":
        if not GITLEAKS_IGNORE_PATH.is_file():
            gate("ci", f"ratchet {ratchet_id}: {relative(GITLEAKS_IGNORE_PATH)} is missing")
            return {}
        fingerprints = [line for line in GITLEAKS_IGNORE_PATH.read_text(encoding="utf-8").splitlines()
                        if line.strip() and not line.lstrip().startswith("#")]
        return {"kind": "count", "total": len(fingerprints), "counts": {}, "sites": len(fingerprints)}
    raise ArchitectureError(f"ratchet {ratchet_id} has unknown source kind {kind!r}")


def read_lint_rules(path: Path) -> list[dict[str, Any]]:
    if not path.is_file():
        gate("ci", f"{relative(path)} is missing; no custom lint rules")
        return []
    try:
        document = parse_yaml_subset(path.read_text(encoding="utf-8"))
    except YamlSubsetError as exc:
        raise ArchitectureError(f"{relative(path)}: {exc}") from exc
    custom = document.get("custom_rules") if isinstance(document, dict) else None
    if not isinstance(custom, dict):
        raise ArchitectureError(f"{relative(path)} has no custom_rules mapping")
    baselined: Counter[str] = Counter()
    if SWIFTLINT_BASELINE_PATH.is_file():
        for entry in json.loads(SWIFTLINT_BASELINE_PATH.read_text(encoding="utf-8")):
            baselined[str(entry["violation"]["ruleIdentifier"])] += 1
    rules: list[dict[str, Any]] = []
    for rule_id in custom:
        body = custom[rule_id] if isinstance(custom[rule_id], dict) else {}
        message = " ".join(str(body.get("message") or "").split())
        rules.append({
            "id": str(rule_id),
            "severity": str(body.get("severity") or "warning"),
            "message": message,
            "included": [str(item) for item in _as_list(body.get("included"))],
            "excluded_count": len(_as_list(body.get("excluded"))),
            "baselined": baselined.get(str(rule_id), 0),
            "evidence": {"path": relative(path), "line": custom.lines.get(rule_id, 1) if isinstance(custom, YamlMap) else 1},
        })
    return rules


def read_architecture_tests(path: Path) -> list[dict[str, Any]]:
    if not path.is_file():
        gate("ci", f"{relative(path)} is missing; no architecture tests")
        return []
    text = path.read_text(encoding="utf-8")
    tests: list[dict[str, Any]] = []
    for match in ARCHITECTURE_TEST_RE.finditer(text):
        tests.append({
            "title": match.group(1).replace('\\"', '"'),
            "evidence": {"path": relative(path), "line": text.count("\n", 0, match.start()) + 1},
        })
    return tests


def validate_ci_config(config: dict[str, Any]) -> dict[str, Any]:
    ci = config.get("ci")
    if not isinstance(ci, dict):
        raise ArchitectureError("architecture/config.json must declare a `ci` block")
    declared = ci.get("workflows")
    if not isinstance(declared, dict) or not declared:
        raise ArchitectureError("config ci.workflows must map each workflow file stem to its family")
    for workflow_id, entry in declared.items():
        if not isinstance(entry, dict) or entry.get("family") not in CI_FAMILIES:
            raise ArchitectureError(f"config ci.workflows[{workflow_id}] must declare a family in {sorted(CI_FAMILIES)}")
        if not entry.get("label"):
            raise ArchitectureError(f"config ci.workflows[{workflow_id}] needs a label")
    ratchets = ci.get("ratchets")
    if not isinstance(ratchets, list) or not ratchets:
        raise ArchitectureError("config ci.ratchets must be a non-empty array")
    seen: set[str] = set()
    for ratchet in ratchets:
        for field in ("id", "title", "job", "source", "measures", "floor"):
            if field not in ratchet:
                raise ArchitectureError(f"config ci.ratchets entry {ratchet.get('id')!r} lacks {field}")
        if ratchet["id"] in seen:
            raise ArchitectureError(f"config ci.ratchets declares {ratchet['id']!r} twice")
        seen.add(ratchet["id"])
        if not isinstance(ratchet["source"], dict) or ratchet["source"].get("kind") not in CI_RATCHET_SOURCES:
            raise ArchitectureError(f"ratchet {ratchet['id']} source.kind must be one of {sorted(CI_RATCHET_SOURCES)}")
        if "patch" not in ratchet:
            raise ArchitectureError(f"ratchet {ratchet['id']} must state its patch rule (null when floor-only)")
    architectural = ci.get("architectural")
    if not isinstance(architectural, dict):
        raise ArchitectureError("config ci.architectural must be an object")
    for field in ("lint_config", "tests", "runs_in"):
        if field not in architectural:
            raise ArchitectureError(f"config ci.architectural lacks {field}")
    static_checks = ci.get("static_checks")
    if not isinstance(static_checks, dict) or not isinstance(static_checks.get("jobs"), list):
        raise ArchitectureError("config ci.static_checks.jobs must be an array of job ids")
    return ci


def empty_ci_model() -> dict[str, Any]:
    return {
        "families": {family: {"question": question} for family, question in CI_FAMILIES.items()},
        "workflows": [], "jobs": [], "edges": [], "triggers": [],
        "merge": {"id": "merge:main", "label": "Merge to main", "inputs": []},
        "ratchets": [],
        "architectural": {"lint_rules": [], "tests": [], "invariants": [], "runs_in": [], "lint_config": "", "tests_path": ""},
        "static_checks": [], "limitations": CI_LIMITATIONS,
        "summary": {"workflows": 0, "jobs": 0, "gates": 0, "ratchets": 0, "lint_rules": 0, "architecture_tests": 0, "invariants": 0, "static_checks": 0},
    }


def build_ci_model(config: dict[str, Any], interplay: dict[str, Any]) -> dict[str, Any]:
    if LENIENT:
        # Snapshot mode walks past checkouts for the System map's history; the
        # scratch tree has no workflows or baselines and the CI plane is not part
        # of the map's shape, so it is neither compiled nor counted as a gap.
        return empty_ci_model()
    ci_config = validate_ci_config(config)
    workflows = read_workflows()
    declared = ci_config["workflows"]
    jobs: list[dict[str, Any]] = []
    for workflow in workflows:
        entry = declared.get(workflow["id"])
        if entry is None:
            raise ArchitectureError(
                f"{workflow['path']} has no entry under config ci.workflows; declare its family so the CI plane stays complete"
            )
        workflow["family"] = entry["family"]
        workflow["label"] = str(entry["label"])
        workflow["question"] = str(entry.get("question") or CI_FAMILIES[entry["family"]])
        for job in workflow.pop("_jobs"):
            job["family"] = entry["family"]
            jobs.append(job)
    present = {workflow["id"] for workflow in workflows}
    if workflows:
        for workflow_id in declared:
            if workflow_id not in present:
                raise ArchitectureError(f"config ci.workflows declares {workflow_id!r} but .github/workflows/{workflow_id}.yml does not exist")
    job_by_id = {job["id"]: job for job in jobs}
    for job in jobs:
        for dependency in job["needs"]:
            if dependency not in job_by_id:
                raise ArchitectureError(f"{job['id']} needs {dependency}, which no workflow defines")

    edges: list[dict[str, Any]] = []
    for job in jobs:
        for dependency in job["needs"]:
            edges.append({"source": dependency, "target": job["id"], "kind": "needs"})
        producers = [other for other in jobs if other["workflow"] == job["workflow"] and other["id"] != job["id"]]
        for artifact in job["artifacts_in"]:
            for producer in producers:
                if artifact in producer["artifacts_out"]:
                    edges.append({"source": producer["id"], "target": job["id"], "kind": "artifact", "label": artifact})
    for job in jobs:
        if job["needs"]:
            continue
        if job["role"] == "gate":
            edges.append({"source": "trigger:pull_request", "target": job["id"], "kind": "trigger"})
        elif job["role"] == "manual":
            edges.append({"source": "trigger:workflow_dispatch", "target": job["id"], "kind": "trigger"})
        elif job["role"] == "post-merge":
            edges.append({"source": "merge:main", "target": job["id"], "kind": "release"})
    for job in jobs:
        if job["role"] == "gate":
            edges.append({"source": job["id"], "target": "merge:main", "kind": "gates"})
        elif job["role"] == "post-merge" and job["needs"]:
            edges.append({"source": "merge:main", "target": job["id"], "kind": "release"})
    edges.sort(key=lambda edge: (edge["kind"], edge["source"], edge["target"], edge.get("label", "")))

    trigger_workflows: dict[str, list[str]] = defaultdict(list)
    for workflow in workflows:
        for trigger in workflow["triggers"]:
            trigger_workflows[trigger["event"]].append(workflow["id"])
    triggers = [
        {"id": f"trigger:{event}", "event": event, "workflows": sorted(trigger_workflows[event])}
        for event in CI_TRIGGER_EVENTS if trigger_workflows.get(event)
    ]

    ratchets: list[dict[str, Any]] = []
    ratchet_jobs: set[str] = set()
    for declared_ratchet in ci_config["ratchets"]:
        job_id = str(declared_ratchet["job"])
        if workflows and job_id not in job_by_id:
            raise ArchitectureError(f"ratchet {declared_ratchet['id']} names job {job_id}, which no workflow defines")
        if workflows and job_by_id[job_id]["family"] != "posture":
            raise ArchitectureError(f"ratchet {declared_ratchet['id']} names {job_id}, but that job's workflow is not the posture family")
        ratchet_jobs.add(job_id)
        ratchets.append({
            "id": str(declared_ratchet["id"]),
            "title": str(declared_ratchet["title"]),
            "job": job_id,
            "source": dict(declared_ratchet["source"]),
            "source_path": str(declared_ratchet["source"].get("path", "")),
            "measures": str(declared_ratchet["measures"]),
            "floor": str(declared_ratchet["floor"]),
            "patch": str(declared_ratchet["patch"]) if declared_ratchet.get("patch") else None,
            "current": _ratchet_current(declared_ratchet["source"], str(declared_ratchet["id"])),
        })
    dependents: dict[str, set[str]] = defaultdict(set)
    for job in jobs:
        for dependency in job["needs"]:
            dependents[dependency].add(job["id"])
    for job in jobs:
        if job["family"] == "posture" and job["id"] not in ratchet_jobs and not dependents.get(job["id"]):
            raise ArchitectureError(
                f"{job['id']} is a posture job that no ratchet declares and no other job needs; "
                "declare it under config ci.ratchets (one concern per job) or make it a shared measurement"
            )

    architectural_config = ci_config["architectural"]
    runs_in = [str(item) for item in architectural_config["runs_in"]]
    for job_id in runs_in:
        if workflows and job_id not in job_by_id:
            raise ArchitectureError(f"config ci.architectural.runs_in names {job_id}, which no workflow defines")
    lint_rules = read_lint_rules(ROOT / str(architectural_config["lint_config"]))
    tests = read_architecture_tests(ROOT / str(architectural_config["tests"]))
    invariants = [
        {"id": item["id"], "kind": item["kind"], "status": item["status"], "why": item.get("why", "")}
        for item in interplay.get("invariants", [])
    ]

    static_checks: list[dict[str, Any]] = []
    for job_id in ci_config["static_checks"]["jobs"]:
        job_id = str(job_id)
        if workflows and job_id not in job_by_id:
            raise ArchitectureError(f"config ci.static_checks.jobs names {job_id}, which no workflow defines")
        if job_id not in job_by_id:
            continue
        for step in job_by_id[job_id]["steps"]:
            # A check recompiles or verifies: it runs a repository script or a
            # `--check`. Tree assembly and uploads in the same job are not checks.
            if "command" in step and (step.get("scripts") or "--check" in step["command"]):
                static_checks.append({
                    "job": job_id,
                    "name": step["name"],
                    "command": step["command"],
                    "scripts": step.get("scripts", []),
                    "evidence": {"path": job_by_id[job_id]["evidence"]["path"], "line": step["line"]},
                })

    return {
        "families": {family: {"question": question} for family, question in CI_FAMILIES.items()},
        "workflows": workflows,
        "jobs": jobs,
        "edges": edges,
        "triggers": triggers,
        "merge": {"id": "merge:main", "label": "Merge to main", "inputs": sorted(job["id"] for job in jobs if job["role"] == "gate")},
        "ratchets": ratchets,
        "architectural": {
            "lint_rules": lint_rules,
            "tests": tests,
            "invariants": invariants,
            "runs_in": runs_in,
            "lint_config": str(architectural_config["lint_config"]),
            "tests_path": str(architectural_config["tests"]),
        },
        "static_checks": static_checks,
        "limitations": CI_LIMITATIONS,
        "summary": {
            "workflows": len(workflows),
            "jobs": len(jobs),
            "gates": sum(1 for job in jobs if job["role"] == "gate"),
            "ratchets": len(ratchets),
            "lint_rules": len(lint_rules),
            "architecture_tests": len(tests),
            "invariants": len(invariants),
            "static_checks": len(static_checks),
        },
    }


def compile_architecture() -> tuple[dict[str, Any], dict[str, Any]]:
    config = load_json(CONFIG_PATH)
    validate_config(config)
    files, source_hash = read_sources(config)
    launch_files, launch_hash = read_launch_sources(config)
    if launch_files:
        source_hash = hashlib.sha256(f"{source_hash}\0{launch_hash}".encode("utf-8")).hexdigest()
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
    attach_stores_to_interplay(interplay, stores, files)
    attach_externals_to_interplay(interplay, externals, stores)
    attach_triggers_to_interplay(interplay, files)
    page_of_type, pages, page_ties = assign_pages(files, config)
    attach_pages_to_interplay(interplay, page_of_type, pages, page_ties, config, files)
    attach_launch_to_interplay(interplay, extract_launch_constructions(launch_files), files, config)
    attach_state_machines(interplay, files)
    assign_history_keys(interplay)
    # Records may cite the launch roots too: they are part of the analysed tree.
    load_constructs(interplay, files + launch_files, externals)
    load_flows(interplay, files + launch_files)
    interplay["invariants"] = validate_interplay_invariants(interplay, behavior, load_json(INTERPLAY_INVARIANTS_PATH), stores)
    ci = build_ci_model(config, interplay)
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
        "ci": ci,
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
    site_data = {"model": model}
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
    parser.add_argument(
        "--snapshot", action="store_true",
        help="compile leniently and print the System map's shape as JSON (used by the history walk)",
    )
    args = parser.parse_args()
    try:
        if args.snapshot:
            global LENIENT
            LENIENT = True
            model, _site_data = compile_architecture()
            print(json.dumps(shape_of(model), sort_keys=True, separators=(",", ":")))
            return 0
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
