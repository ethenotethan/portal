#!/usr/bin/env python3
"""Derive Portal's System map at every commit that touched the app source.

The map (`scripts/build_architecture.py`) answers what the application looks like
now. This walk answers when it came to look like this, without a second
extractor: it runs today's compiler in `--snapshot` mode over each first-parent
commit that changed the Swift sources, with today's curated files
(`architecture/config.json`, the overlay, the invariants), and writes one
delta-encoded timeline the site loads as an opt-in artifact.

Consecutive commits are nearly identical, so a point stores what changed against
the point before it: indices into one union table of every node and edge any
snapshot contained. Nothing is remembered from when a commit was current; every
point is derived now, by one program, which is what makes two points comparable.

What that costs is stated rather than hidden. A snapshot is named by today's
config and overlay, so each point carries how much of itself today's curation
could not account for (externals that matched nothing, invariants that did not
hold, page roots that did not exist yet), and a commit the extractor cannot
process at all is recorded under `failed`, not skipped silently.

The artifact is not committed: it depends on git history rather than on the
working tree, so `--check` cannot gate it. `make architecture-history` builds it
for a local preview and the Pages deploy job builds it (incrementally, from a
cache) before publishing.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
COMPILER = ROOT / "scripts/build_architecture.py"
CURATED = (
    "architecture/config.json",
    "architecture/semantic/components.json",
    "architecture/interplay/overlay.json",
    "architecture/interplay/invariants.json",
)
OUTPUT = ROOT / "architecture/site/history.js"
OUTPUT_PREFIX = "window.PORTAL_ARCHITECTURE_HISTORY="
SCHEMA_VERSION = "1.0.0"
# Where the app source has lived, oldest name first. A commit is walked if it
# touched any of them; a legacy root is extracted under today's name so today's
# config (which names `Sources/Portal`) applies to it unchanged.
SOURCE_ROOTS: tuple[tuple[str, str], ...] = (
    ("Sources/HermesNative", "Sources/Portal"),
    ("Sources/Portal", "Sources/Portal"),
)


class HistoryError(RuntimeError):
    pass


def display(path: Path) -> str:
    try:
        return path.resolve().relative_to(ROOT).as_posix()
    except ValueError:
        return str(path)


@dataclass(frozen=True)
class Commit:
    rev: str
    date: str
    subject: str


def git(*args: str, cwd: Path = ROOT, binary: bool = False) -> Any:
    result = subprocess.run(["git", *args], cwd=cwd, capture_output=True, check=False)
    if result.returncode != 0:
        raise HistoryError(f"git {' '.join(args)}: {result.stderr.decode('utf-8', 'replace').strip()}")
    return result.stdout if binary else result.stdout.decode("utf-8")


def list_commits(ref: str) -> list[Commit]:
    """First-parent commits on ``ref`` that touched a source root, oldest first.

    First-parent because main is squash-merged: one commit per change, and the
    points are the changes people made rather than the branches they made them on.
    """
    paths = sorted({legacy for legacy, _current in SOURCE_ROOTS})
    out = git("log", "--reverse", "--first-parent", "--format=%H%x00%ad%x00%s", "--date=short", ref, "--", *paths)
    commits: list[Commit] = []
    for line in out.splitlines():
        parts = line.split("\0", 2)
        if len(parts) == 3:
            commits.append(Commit(parts[0], parts[1], parts[2]))
    return commits


def sample(commits: list[Commit], every: int, maximum: int) -> list[Commit]:
    """Keep one commit in ``every`` and at most ``maximum``; the newest always stays,
    because a timeline whose last point is not the head disagrees with the map beside it."""
    kept = commits
    if every > 1 and kept:
        kept = [commit for index, commit in enumerate(kept) if index % every == 0 or index == len(kept) - 1]
    if maximum > 0 and len(kept) > maximum:
        kept = kept[-maximum:]
    return kept


def extractor_fingerprint() -> str:
    """Identity of the program every point is derived by: the compiler and the curated
    files it reads. A timeline built by a different fingerprint is not comparable
    and is rebuilt from scratch rather than extended."""
    digest = hashlib.sha256()
    for relative in ("scripts/build_architecture.py", *CURATED):
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update((ROOT / relative).read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def source_root_at(rev: str) -> tuple[str, str] | None:
    for legacy, current in reversed(SOURCE_ROOTS):
        probe = subprocess.run(["git", "cat-file", "-e", f"{rev}:{legacy}"], cwd=ROOT, capture_output=True, check=False)
        if probe.returncode == 0:
            return legacy, current
    return None


def prepare_skeleton(scratch: Path) -> None:
    """One scratch tree per worker: today's compiler and curated files, and a
    `Sources/` the worker replaces per commit. `ROOT` inside the copied compiler
    resolves to the scratch tree, so nothing in the real checkout is touched."""
    (scratch / "scripts").mkdir(parents=True, exist_ok=True)
    shutil.copy2(COMPILER, scratch / "scripts/build_architecture.py")
    for relative in CURATED:
        target = scratch / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / relative, target)


def snapshot(commit: Commit, scratch: Path) -> dict[str, Any]:
    """Derive one point from ``commit`` into ``scratch``. Raises HistoryError when the
    commit has no source root or the compiler cannot process it."""
    roots = source_root_at(commit.rev)
    if roots is None:
        raise HistoryError("no app source root at this commit")
    legacy, current = roots
    sources = scratch / "Sources"
    shutil.rmtree(sources, ignore_errors=True)
    archive = git("archive", "--format=tar", commit.rev, "--", legacy, binary=True)
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:") as tar:
        tar.extractall(scratch, filter="data")
    if legacy != current:
        (scratch / current).parent.mkdir(parents=True, exist_ok=True)
        (scratch / legacy).rename(scratch / current)
    run = subprocess.run(
        [sys.executable, str(scratch / "scripts/build_architecture.py"), "--snapshot"],
        cwd=scratch, capture_output=True, text=True, check=False,
    )
    if run.returncode != 0:
        reason = (run.stderr.strip().splitlines() or ["compiler exited non-zero"])[-1]
        raise HistoryError(reason[:300])
    try:
        return json.loads(run.stdout)
    except json.JSONDecodeError as exc:
        raise HistoryError(f"compiler printed no shape: {exc}") from exc


# ---------------------------------------------------------------------------
# Delta encoding
# ---------------------------------------------------------------------------

def edge_key(edge: list[Any]) -> tuple[str, str, str, str]:
    return (str(edge[0]), str(edge[1]), str(edge[2]), str(edge[3]))


def encode_timeline(
    ref: str, head: str, fingerprint: str,
    points: list[tuple[Commit, dict[str, Any]]], failed: list[dict[str, str]],
) -> dict[str, Any]:
    """Union tables plus one delta per point.

    A node's metadata in the union is the newest snapshot's view of it, so the head
    revision's nodes are described exactly as the map describes them and a node
    that has since been deleted is described as it last was.
    """
    node_index: dict[str, int] = {}
    node_meta: list[dict[str, Any]] = []
    edge_index: dict[tuple[str, str, str, str], int] = {}
    edge_rows: list[list[Any]] = []

    def node_id(meta: dict[str, Any]) -> int:
        key = meta["k"]
        if key not in node_index:
            node_index[key] = len(node_meta)
            node_meta.append(dict(meta))
        else:
            node_meta[node_index[key]] = dict(meta)
        return node_index[key]

    def edge_id(edge: tuple[str, str, str, str]) -> int:
        if edge not in edge_index:
            edge_index[edge] = len(edge_rows)
            edge_rows.append([node_index[edge[0]], node_index[edge[1]], edge[2], edge[3]])
        return edge_index[edge]

    snapshots: list[dict[str, Any]] = []
    previous_nodes: set[str] = set()
    previous_edges: set[tuple[str, str, str, str]] = set()
    for commit, shape in points:
        nodes = {meta["k"]: meta for meta in shape["nodes"]}
        edges = {edge_key(edge) for edge in shape["edges"]}
        for meta in shape["nodes"]:
            node_id(meta)
        point: dict[str, Any] = {
            "rev": commit.rev, "date": commit.date, "subject": commit.subject, "tree": shape["tree"],
            "counts": {"nodes": len(nodes), "edges": len(edges)},
            "fidelity": shape.get("fidelity", {}),
            "invariants": shape.get("invariants", {}),
        }
        added_nodes = sorted(node_index[key] for key in nodes if key not in previous_nodes)
        removed_nodes = sorted(node_index[key] for key in previous_nodes if key not in nodes)
        added_edges = sorted(edge_id(edge) for edge in edges if edge not in previous_edges)
        removed_edges = sorted(edge_id(edge) for edge in previous_edges if edge not in edges)
        if added_nodes:
            point["na"] = added_nodes
        if removed_nodes:
            point["nd"] = removed_nodes
        if added_edges:
            point["ea"] = added_edges
        if removed_edges:
            point["ed"] = removed_edges
        snapshots.append(point)
        previous_nodes = set(nodes)
        previous_edges = edges
    return {
        "schema_version": SCHEMA_VERSION,
        "ref": ref,
        "head": head,
        "extractor": fingerprint,
        "nodes": node_meta,
        "edges": edge_rows,
        "snapshots": snapshots,
        "failed": failed,
    }


def replay(timeline: dict[str, Any]) -> list[tuple[Commit, dict[str, Any]]]:
    """Invert ``encode_timeline``: the full shape at every point, in order."""
    nodes = timeline["nodes"]
    edges = timeline["edges"]
    live_nodes: set[int] = set()
    live_edges: set[int] = set()
    points: list[tuple[Commit, dict[str, Any]]] = []
    for point in timeline["snapshots"]:
        live_nodes.difference_update(point.get("nd", []))
        live_edges.difference_update(point.get("ed", []))
        live_nodes.update(point.get("na", []))
        live_edges.update(point.get("ea", []))
        shape = {
            "tree": point["tree"],
            "nodes": sorted((dict(nodes[index]) for index in live_nodes), key=lambda meta: meta["k"]),
            "edges": sorted([nodes[edges[i][0]]["k"], nodes[edges[i][1]]["k"], edges[i][2], edges[i][3]] for i in live_edges),
            "fidelity": point.get("fidelity", {}),
            "invariants": point.get("invariants", {}),
        }
        points.append((Commit(point["rev"], point["date"], point["subject"]), shape))
    return points


def read_timeline(path: Path) -> dict[str, Any] | None:
    if not path.is_file():
        return None
    text = path.read_text(encoding="utf-8").strip()
    if not text.startswith(OUTPUT_PREFIX) or not text.endswith(";"):
        return None
    try:
        data = json.loads(text[len(OUTPUT_PREFIX):-1])
    except json.JSONDecodeError:
        return None
    return data if isinstance(data, dict) and data.get("schema_version") == SCHEMA_VERSION else None


def serialize(timeline: dict[str, Any]) -> str:
    return OUTPUT_PREFIX + json.dumps(timeline, separators=(",", ":"), sort_keys=True, ensure_ascii=False) + ";\n"


# ---------------------------------------------------------------------------
# The walk
# ---------------------------------------------------------------------------

def walk(
    commits: list[Commit], jobs: int, progress: Any = None,
) -> tuple[dict[str, dict[str, Any]], dict[str, str]]:
    """Snapshot every commit with ``jobs`` scratch trees in parallel. Returns shapes
    by rev and failure reasons by rev."""
    shapes: dict[str, dict[str, Any]] = {}
    failures: dict[str, str] = {}
    if not commits:
        return shapes, failures
    jobs = max(1, min(jobs, len(commits)))
    with tempfile.TemporaryDirectory(prefix="portal-architecture-history-") as base:
        scratches = [Path(base) / f"worker-{index}" for index in range(jobs)]
        for scratch in scratches:
            prepare_skeleton(scratch)
        # Round-robin assignment keeps each worker on its own scratch tree.
        buckets: list[list[Commit]] = [commits[index::jobs] for index in range(jobs)]
        done = 0
        total = len(commits)

        def run_bucket(worker: int) -> None:
            nonlocal done
            for commit in buckets[worker]:
                started = time.monotonic()
                try:
                    shape = snapshot(commit, scratches[worker])
                    shapes[commit.rev] = shape
                    outcome = f"ok {len(shape['nodes'])} nodes {len(shape['edges'])} edges"
                except HistoryError as exc:
                    failures[commit.rev] = str(exc)
                    outcome = f"FAILED {exc}"
                done += 1
                if progress:
                    progress(done, total, commit, outcome, time.monotonic() - started)

        with ThreadPoolExecutor(max_workers=jobs) as pool:
            list(pool.map(run_bucket, range(jobs)))
    return shapes, failures


def build(ref: str, jobs: int, every: int, maximum: int, output: Path, full: bool, quiet: bool) -> dict[str, Any]:
    head = git("rev-parse", ref).strip()
    fingerprint = extractor_fingerprint()
    commits = sample(list_commits(ref), every, maximum)
    if not commits:
        raise HistoryError(f"no commits on {ref} touched {', '.join(sorted({r for r, _ in SOURCE_ROOTS}))}")

    # Reuse: a previous artifact built by the same extractor whose points are a
    # prefix of this walk contributes its shapes; only what follows is derived.
    reused: list[tuple[Commit, dict[str, Any]]] = []
    previous = None if full else read_timeline(output)
    if previous and previous.get("extractor") == fingerprint:
        earlier = replay(previous)
        wanted = [commit.rev for commit in commits]
        prefix = 0
        while prefix < len(earlier) and prefix < len(wanted) and earlier[prefix][0].rev == wanted[prefix]:
            prefix += 1
        # The previous walk may have failed on commits this one also lists; those
        # sit between points, so the prefix test must skip them.
        reused = [(Commit(*(commit.rev, commit.date, commit.subject)), shape) for commit, shape in earlier[:prefix]]
    reused_revs = {commit.rev for commit, _shape in reused}
    pending = [commit for commit in commits if commit.rev not in reused_revs]

    def progress(done: int, total: int, commit: Commit, outcome: str, seconds: float) -> None:
        if not quiet:
            print(f"[{done}/{total}] {commit.rev[:9]} {commit.date} {outcome} ({seconds:.1f}s)", file=sys.stderr, flush=True)

    if not quiet:
        print(
            f"history: {len(commits)} commits on {ref}, {len(reused)} reused, {len(pending)} to derive with {jobs} worker(s)",
            file=sys.stderr, flush=True,
        )
    shapes, failures = walk(pending, jobs, progress)
    points = list(reused)
    failed: list[dict[str, str]] = []
    for commit in commits:
        if commit.rev in reused_revs:
            continue
        if commit.rev in shapes:
            points.append((commit, shapes[commit.rev]))
        else:
            failed.append({"rev": commit.rev, "date": commit.date, "reason": failures.get(commit.rev, "unknown")})
    order = {commit.rev: index for index, commit in enumerate(commits)}
    points.sort(key=lambda item: order[item[0].rev])
    if not points:
        raise HistoryError("every commit failed to snapshot; nothing to write")
    timeline = encode_timeline(ref, head, fingerprint, points, failed)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(serialize(timeline), encoding="utf-8")
    if not quiet:
        first, last = timeline["snapshots"][0], timeline["snapshots"][-1]
        print(
            f"wrote {display(output)}: {len(timeline['snapshots'])} snapshots "
            f"{first['date']} → {last['date']}, {len(failed)} failed, "
            f"{len(timeline['nodes'])} union nodes, {len(timeline['edges'])} union edges, "
            f"{output.stat().st_size // 1024} KiB",
            file=sys.stderr,
        )
    return timeline


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--ref", default="HEAD", help="history to walk, first-parent (default: HEAD)")
    parser.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 2) - 1), help="parallel scratch trees")
    parser.add_argument("--every", type=int, default=1, help="keep one commit in N (the newest always stays)")
    parser.add_argument("--max", type=int, default=0, help="cap the number of snapshots, newest kept (0 = all)")
    parser.add_argument("--output", type=Path, default=OUTPUT, help=f"where to write (default: {display(OUTPUT)})")
    parser.add_argument("--full", action="store_true", help="ignore an existing artifact instead of extending it")
    parser.add_argument("--quiet", action="store_true", help="no per-commit progress")
    args = parser.parse_args()
    try:
        build(args.ref, args.jobs, args.every, args.max, args.output, args.full, args.quiet)
    except HistoryError as exc:
        print(f"history error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
