#!/usr/bin/env python3
"""Count SwiftUI lazy stacks that have no scroll viewport to be lazy in.

A `LazyVStack`/`LazyHStack` only earns its keep inside a `ScrollView` that
scrolls along the stack's axis. Anywhere else it has no viewport: it measures
every child at an unbounded size, misses its own estimates, and re-arms layout
through `LazyLayoutViewCache.signalPrefetch → NSHostingView.requestUpdate` —
the self-rescheduling relayout loop that beachballed the chat canvas (#249)
and the model artifact surface (#606). Both were lazy stacks with no viewport.

Two shapes are flagged, each one *site* (file + line + kind):

    lazy_stack_cross_axis_scroll   the nearest enclosing ScrollView scrolls the
                                   other axis (a LazyVStack inside a
                                   horizontal-only ScrollView: every row must be
                                   realised to know the height, so nothing is
                                   ever skipped)
    lazy_stack_without_viewport    no ScrollView encloses the stack anywhere in
                                   its type — the stack relies on some other
                                   file's scroll view, or on none at all (a
                                   fixed HStack of Kanban columns)

A lazy stack whose enclosing *type* contains a ScrollView somewhere else (the
usual `body { ScrollView { rows } }` / `var rows: some View { LazyVStack … }`
split) is given the benefit of the doubt and not counted. The scan is textual
with bracket tracking — no build needed — over comment- and string-stripped
source, so prose that mentions `LazyVStack` never inflates the count.

Usage:
    collect-layout-smells.py SOURCES_DIR [--json OUT] [--root DIR]

Output (same shape as the other metric collectors):
    {
      "counts": { "lazy_stack_cross_axis_scroll": 0, "lazy_stack_without_viewport": 0 },
      "total": 0,
      "sites": [ {"file": "...", "line": 12, "kind": "..."} ]
    }
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

LAZY = {"LazyVStack": "vertical", "LazyHStack": "horizontal"}
IDENT_BEFORE = re.compile(r"([A-Za-z_][A-Za-z0-9_.]*)\s*$")
# `struct Foo: View, Bar where …` — a type keyword, its name, then anything
# but a bracket or statement break up to the opening brace.
TYPE_BEFORE = re.compile(
    r"\b(?:struct|class|enum|extension|actor|protocol)\s+([A-Za-z_][A-Za-z0-9_.]*)[^{};]*$"
)


def blank_comments_and_strings(text: str) -> str:
    """Replace comment bodies and string literals with spaces, keeping newlines
    so line numbers survive and offsets stay aligned with the original."""
    out: list[str] = []
    i, n = 0, len(text)
    while i < n:
        ch = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if ch == "/" and nxt == "/":
            while i < n and text[i] != "\n":
                out.append(" ")
                i += 1
            continue
        if ch == "/" and nxt == "*":
            depth = 0
            while i < n:
                if text.startswith("/*", i):
                    depth += 1
                    out.append("  ")
                    i += 2
                elif text.startswith("*/", i):
                    depth -= 1
                    out.append("  ")
                    i += 2
                    if depth == 0:
                        break
                else:
                    out.append("\n" if text[i] == "\n" else " ")
                    i += 1
            continue
        if ch == '"':
            quote = '"""' if text.startswith('"""', i) else '"'
            out.append(quote)
            i += len(quote)
            while i < n:
                if text[i] == "\\" and i + 1 < n:
                    out.append("  ")
                    i += 2
                    continue
                if text.startswith(quote, i):
                    out.append(quote)
                    i += len(quote)
                    break
                out.append("\n" if text[i] == "\n" else " ")
                i += 1
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def scroll_axes(args: str) -> set[str]:
    """Axes a ScrollView's argument list scrolls. No axis argument = vertical."""
    axes = set()
    if ".horizontal" in args:
        axes.add("horizontal")
    if ".vertical" in args:
        axes.add("vertical")
    return axes or {"vertical"}


def nearest_scroll_axes(stack: list[dict]) -> set[str] | None:
    """Axes of the innermost enclosing ScrollView closure, stopping at the
    enclosing type; None when no ScrollView encloses this point."""
    for frame in reversed(stack):
        if frame["ch"] != "{":
            continue
        if frame.get("type"):
            return None
        if frame.get("name") == "ScrollView":
            return scroll_axes(frame.get("args", ""))
    return None


def scan(text: str) -> list[dict]:
    """Bracket-track `text` and return lazy-stack findings as
    {"offset", "kind"} dicts."""
    src = blank_comments_and_strings(text)
    stack: list[dict] = []           # open brackets, innermost last
    last_call: dict | None = None    # the `(...)` that closed most recently
    pending: list[dict] = []         # lazy sites awaiting their type's extent
    findings: list[dict] = []

    def note_lazy(offset: int, axis: str) -> None:
        pending.append({"offset": offset, "axis": axis, "nearest": nearest_scroll_axes(stack)})

    for i, ch in enumerate(src):
        if ch == "(":
            m = IDENT_BEFORE.search(src[max(0, i - 120):i])
            name = m.group(1).split(".")[-1] if m else None
            if name in LAZY:
                note_lazy(i, LAZY[name])
            stack.append({"ch": "(", "name": name, "args_start": i + 1})
        elif ch == ")":
            if stack and stack[-1]["ch"] == "(":
                frame = stack.pop()
                frame["args"] = src[frame["args_start"]:i]
                last_call = frame
        elif ch == "{":
            before = src[max(0, i - 240):i].rstrip()
            type_match = TYPE_BEFORE.search(before)
            owner, args = None, ""
            if before.endswith(")") and last_call is not None:
                owner, args = last_call["name"], last_call.get("args", "")
            else:
                m = IDENT_BEFORE.search(before)
                if m:
                    owner = m.group(1).split(".")[-1]
                    if owner in LAZY:                 # bare `LazyVStack { … }`
                        note_lazy(i, LAZY[owner])
            stack.append({
                "ch": "{", "name": owner, "args": args, "start": i,
                "type": type_match.group(1) if type_match else None,
            })
            last_call = None
        elif ch == "}":
            if stack and stack[-1]["ch"] == "{":
                frame = stack.pop()
                if frame.get("type"):
                    type_has_scroll = "ScrollView" in src[frame["start"]:i]
                    keep: list[dict] = []
                    for site in pending:
                        if frame["start"] < site["offset"] < i:
                            finding = resolve(site, type_has_scroll)
                            if finding:
                                findings.append(finding)
                        else:
                            keep.append(site)
                    pending = keep
            last_call = None
    for site in pending:                              # top-level code, if any
        finding = resolve(site, "ScrollView" in src)
        if finding:
            findings.append(finding)
    return findings


def resolve(site: dict, type_has_scroll: bool) -> dict | None:
    nearest = site.get("nearest")
    if nearest is not None:
        if site["axis"] in nearest:
            return None
        return {"offset": site["offset"], "kind": "lazy_stack_cross_axis_scroll"}
    if type_has_scroll:
        return None
    return {"offset": site["offset"], "kind": "lazy_stack_without_viewport"}


def relativize(path: str, root: str) -> str:
    p = path
    if root and p.startswith(root):
        p = p[len(root):]
    return p.lstrip("/")


def collect(sources_dir: str, root: str) -> dict:
    sites = []
    for swift in sorted(Path(sources_dir).rglob("*.swift")):
        text = swift.read_text(errors="replace")
        rel = relativize(str(swift), root)
        for finding in scan(text):
            line = text.count("\n", 0, finding["offset"]) + 1
            sites.append({"file": rel, "line": line, "kind": finding["kind"]})
    counts: dict[str, int] = {}
    for s in sites:
        counts[s["kind"]] = counts.get(s["kind"], 0) + 1
    return {"counts": dict(sorted(counts.items())), "total": len(sites), "sites": sites}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("sources_dir", help="path to the Sources/ tree")
    ap.add_argument("--json", help="output path (default: stdout)")
    ap.add_argument("--root", default=os.getcwd(), help="prefix to strip (repo root)")
    args = ap.parse_args()

    snapshot = collect(args.sources_dir, args.root)
    out = json.dumps(snapshot, indent=2) + "\n"
    if args.json:
        Path(args.json).write_text(out)
        print(f"Found {snapshot['total']} lazy stack(s) without a viewport → {args.json}")
    else:
        sys.stdout.write(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
