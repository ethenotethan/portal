#!/usr/bin/env python3
"""Constraint ratchet: the declarations that decide what CI accepts may only tighten.

The numeric ratchets already read their baselines from the base branch, so a PR
cannot lower a floor in the same change it needs to pass. Everything declarative
was still open: an agent blocked by an invariant could delete the invariant, grow
an exception list, drop a lint rule, remove a gate step from a workflow, or
delete a specification — all in the PR that needed it. This guard closes that
surface the same way the other ratchets do: read each file as it exists on the
BASE branch (`git show BASE:path`), read the working tree, and reject anything
that is looser. Tightening (a new invariant, a stricter minimum, a new rule, a
new gate step) always passes.

What "looser" means, per file:

  architecture/interplay/invariants.json
      an invariant removed; its `kind` changed; `min` lowered (or a per-key
      minimum dropped); `max_*` raised; `allow_*` exceptions grown; a
      `*_outside_lock` gate flipped off; a `declared` machine dropped;
      `transports` widened; a set that names what an invariant checks
      (`configures`, `relations`, `systems`, `containers`, `roots`, `zones`)
      narrowed.
  architecture/config.json
      a declared external system, external group, page, layer, launch root,
      specified edge, ratchet, workflow family, architectural run-site or
      static-check job removed. A `release` or `maintenance` workflow family
      may go with its deleted workflow file: those workflows ship or upkeep,
      they do not decide what CI accepts.
      (Components are not guarded: every file must be assigned anyway.)
  architecture/glossary.json (the vocabulary the enrichment layer is held to)
      a term removed; an `avoid` word dropped; a proper noun demoted to a
      case-insensitive kind; a distinction dropped; the file deleted.
  .swiftlint.yml
      a custom rule removed or demoted from error to warning; a rule's or the
      top-level `excluded` list grown; `disabled_rules` grown; `opt_in_rules`
      shrunk.
  Tests/PortalTests/ArchitectureTests.swift
      fewer `@Test(` cases than base.
  scripts/test_architecture.py, scripts/test_interplay.py, scripts/test_constraint_growth.py
      fewer `def test_` cases than base; the file deleted.
  architecture/specifications/*.md, scripts/check-*.py, scripts/collect-*.py,
  scripts/build_architecture*.py, scripts/architecture_agent.py, scripts/test_*.py
      a file deleted.
  .github/workflows/{tests,ratchet,architecture-pages}.yml
      a job removed; a job given an `if:` it did not have (or `if: false`);
      fewer gate steps in a job (steps that run a check script, a test runner,
      swiftlint, gitleaks or periphery); a gate step that still names its gate
      but can no longer fail the job (a step `if:`, `continue-on-error` on the
      step or the job, the command neutralised by `echo`, `|| true`, `|| :` or
      `; exit 0`); `pull_request` dropped from `on`, or given a `paths` or
      `paths-ignore` filter it did not have.
  .github/CODEOWNERS
      an owned path removed.
  architecture/semantic/{constructs,flows}.json (enrichment freshness)
      a construct record or flow that is stale or broken in the working tree
      (the lines it cites changed, or an edge it walks went) and was not so on
      the base. Both trees are compiled leniently with their own compiler; the
      base is checked out into a temporary worktree. A record or flow the
      lenient compile dropped as invalid counts as broken, not absent.

A deliberate loosening (retiring an invariant after a redesign, deleting a rule
that was wrong) is still possible: it carries the `constraints-loosened` label,
which the workflow turns into `--allow-loosening`. The guard then reports every
loosening and exits 0, so the change is explicit in the PR and in the log rather
than silent in a diff. CODEOWNERS makes a human the one who adds the label.

Usage:
    check-constraint-growth.py [BASE_REF] [--allow-loosening]
"""
from __future__ import annotations

import importlib.util
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

ROOT = Path(__file__).resolve().parents[1]

INVARIANTS = "architecture/interplay/invariants.json"
CONFIG = "architecture/config.json"
SWIFTLINT = ".swiftlint.yml"
ARCH_TESTS = "Tests/PortalTests/ArchitectureTests.swift"
GLOSSARY = "architecture/glossary.json"
# The Python suites behind the architecture gate: the compiler's, the interplay's and this guard's own.
COMPILER_TESTS = ("scripts/test_architecture.py", "scripts/test_interplay.py", "scripts/test_constraint_growth.py")
PY_TEST_RE = re.compile(r"^\s*def test_[A-Za-z0-9_]+\(", re.M)
CODEOWNERS = ".github/CODEOWNERS"
SPECIFICATIONS = "architecture/specifications"
GUARDED_WORKFLOWS = (
    ".github/workflows/tests.yml",
    ".github/workflows/ratchet.yml",
    ".github/workflows/architecture-pages.yml",
)
GATE_STEP_RE = re.compile(
    r"scripts/check-[a-z-]+\.py|scripts/build_architecture\.py\s+--check|python3 -m unittest|swiftlint lint|gitleaks\b|periphery scan|swift test|xcodebuild test"
)


def git_show(root: Path, ref: str, path: str) -> Optional[str]:
    result = subprocess.run(
        ["git", "-C", str(root), "show", f"{ref}:{path}"], capture_output=True, text=True, check=False
    )
    return result.stdout if result.returncode == 0 else None


def git_ls_tree(root: Path, ref: str, path: str) -> List[str]:
    result = subprocess.run(
        ["git", "-C", str(root), "ls-tree", "--name-only", ref, f"{path}/"], capture_output=True, text=True, check=False
    )
    return [line.strip() for line in result.stdout.splitlines() if line.strip()] if result.returncode == 0 else []


def working(root: Path, path: str) -> Optional[str]:
    file = root / path
    return file.read_text(encoding="utf-8") if file.is_file() else None


def _yaml():
    """The workflow/lint YAML subset parser shared with the architecture compiler."""
    spec = importlib.util.spec_from_file_location("build_architecture", ROOT / "scripts/build_architecture.py")
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules.setdefault("build_architecture", module)
    spec.loader.exec_module(module)
    return module.parse_yaml_subset


def _load_json(text: Optional[str], where: str, problems: List[str]) -> Optional[Any]:
    if text is None:
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError as exc:
        problems.append(f"{where}: not valid JSON ({exc})")
        return None


# ── invariants.json ──────────────────────────────────────────────────────────


def _numbers(value: Any) -> Dict[str, float]:
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return {"": float(value)}
    if isinstance(value, dict):
        return {str(k): float(v) for k, v in value.items() if isinstance(v, (int, float)) and not isinstance(v, bool)}
    return {}


def _members(value: Any) -> set:
    if isinstance(value, list):
        return {json.dumps(item, sort_keys=True) for item in value}
    if isinstance(value, dict):
        return set(value)
    return set()


# Lists on an invariant that name what it checks (as opposed to `allow_*`, which name what it excuses).
NARROWABLE_SETS = ("configures", "relations", "systems", "containers", "roots", "zones")


def check_invariants(base: Optional[str], head: Optional[str]) -> List[str]:
    problems: List[str] = []
    base_doc = _load_json(base, INVARIANTS, problems)
    head_doc = _load_json(head, INVARIANTS, problems)
    if base_doc is None or head_doc is None:
        return problems
    base_entries = {e["id"]: e for e in base_doc.get("invariants", []) if isinstance(e, dict) and "id" in e}
    head_entries = {e["id"]: e for e in head_doc.get("invariants", []) if isinstance(e, dict) and "id" in e}
    for invariant_id, before in base_entries.items():
        after = head_entries.get(invariant_id)
        where = f"{INVARIANTS}: invariant {invariant_id!r}"
        if after is None:
            problems.append(f"{where} was removed")
            continue
        if after.get("kind") != before.get("kind"):
            problems.append(f"{where} changed kind {before.get('kind')!r} → {after.get('kind')!r}")
        for key in ("min",):
            before_numbers = _numbers(before.get(key))
            after_numbers = _numbers(after.get(key))
            for sub, value in before_numbers.items():
                label = f"{key}[{sub}]" if sub else key
                if sub not in after_numbers:
                    problems.append(f"{where} dropped {label} (was {value:g})")
                elif after_numbers[sub] < value:
                    problems.append(f"{where} lowered {label} {value:g} → {after_numbers[sub]:g}")
        for key, value in before.items():
            # The sets that define what an invariant checks may not shrink: a narrower set checks less.
            if key in NARROWABLE_SETS and isinstance(value, list):
                narrowed = _members(value) - _members(after.get(key))
                if narrowed:
                    names = sorted(str(item).strip('"') for item in narrowed)
                    problems.append(f"{where} narrowed {key}: {', '.join(names)}")
            elif key.startswith("max_") and isinstance(value, (int, float)) and not isinstance(value, bool):
                after_value = after.get(key)
                if isinstance(after_value, (int, float)) and not isinstance(after_value, bool) and after_value > value:
                    problems.append(f"{where} raised {key} {value:g} → {after_value:g}")
            if key.startswith("allow_"):
                grown = _members(after.get(key)) - _members(value)
                if grown:
                    problems.append(f"{where} grew {key} by {len(grown)} exception(s)")
            elif key.endswith("_outside_lock") and value is True and after.get(key) is not True:
                problems.append(f"{where} switched off {key}")
            elif key == "declared" and isinstance(value, dict):
                dropped = set(value) - set(after.get(key) or {})
                if dropped:
                    problems.append(f"{where} dropped declared {', '.join(sorted(dropped))}")
            elif key == "transports" and isinstance(value, list):
                widened = _members(after.get(key)) - _members(value)
                if widened:
                    problems.append(f"{where} widened transports by {len(widened)}")
    return problems


# ── glossary.json ────────────────────────────────────────────────────────────


def check_glossary(base: Optional[str], head: Optional[str]) -> List[str]:
    """The vocabulary the enrichment layer is held to may only grow or tighten: a term removed, an
    `avoid` word dropped, a proper noun demoted to a case-insensitive kind, or a distinction dropped
    is a loosening."""
    problems: List[str] = []
    if base is None:
        return problems  # a repository without a glossary declares nothing to keep
    if head is None:
        return [f"{GLOSSARY}: the glossary was removed"]
    base_doc = _load_json(base, GLOSSARY, problems)
    head_doc = _load_json(head, GLOSSARY, problems)
    if base_doc is None or head_doc is None:
        return problems
    before = {e["term"].lower(): e for e in base_doc.get("terms", []) if isinstance(e, dict) and isinstance(e.get("term"), str)}
    after = {e["term"].lower(): e for e in head_doc.get("terms", []) if isinstance(e, dict) and isinstance(e.get("term"), str)}
    for key, entry in before.items():
        where = f"{GLOSSARY}: term {entry['term']!r}"
        now = after.get(key)
        if now is None:
            problems.append(f"{where} was removed")
            continue
        if entry.get("kind") == "proper-noun" and now.get("kind") != "proper-noun":
            problems.append(f"{where} is no longer a proper noun (its spelling was enforced; now it is not)")
        dropped = _members(entry.get("avoid")) - _members(now.get("avoid"))
        if dropped:
            problems.append(f"{where} dropped {len(dropped)} avoid word(s): {', '.join(sorted(str(a).strip(chr(34)) for a in dropped))}")
        gone = set((entry.get("distinguish_from") or {}).keys()) - set((now.get("distinguish_from") or {}).keys())
        if gone:
            problems.append(f"{where} dropped the distinction from {', '.join(sorted(gone))}")
    return problems


# ── config.json ──────────────────────────────────────────────────────────────


def _ids(items: Any, key: str = "id") -> set:
    return {str(item[key]) for item in items or [] if isinstance(item, dict) and key in item}


# Workflows that ship or upkeep; they do not decide what CI accepts.
NON_GATING_FAMILIES = {"release", "maintenance"}


def check_config(base: Optional[str], head: Optional[str], root: Optional[Path] = None) -> List[str]:
    problems: List[str] = []
    base_doc = _load_json(base, CONFIG, problems)
    head_doc = _load_json(head, CONFIG, problems)
    if base_doc is None or head_doc is None:
        return problems

    def removed(label: str, before: set, after: set) -> None:
        gone = before - after
        if gone:
            problems.append(f"{CONFIG}: {label} removed: {', '.join(sorted(gone))}")

    removed("external system(s)", _ids(base_doc.get("external_systems")), _ids(head_doc.get("external_systems")))
    removed("external group(s)", _ids(base_doc.get("external_groups")), _ids(head_doc.get("external_groups")))
    removed("layer(s)", _ids(base_doc.get("layers")), _ids(head_doc.get("layers")))
    removed("page(s)", _ids((base_doc.get("pages") or {}).get("items")), _ids((head_doc.get("pages") or {}).get("items")))
    removed("launch root(s)", set(map(str, (base_doc.get("launch") or {}).get("roots") or [])), set(map(str, (head_doc.get("launch") or {}).get("roots") or [])))
    edges = lambda doc: {f"{e.get('source')}→{e.get('target')}" for e in doc.get("specified_edges") or [] if isinstance(e, dict)}
    removed("specified edge(s)", edges(base_doc), edges(head_doc))
    base_ci = base_doc.get("ci") or {}
    head_ci = head_doc.get("ci") or {}
    removed("ratchet(s)", _ids(base_ci.get("ratchets")), _ids(head_ci.get("ratchets")))
    base_workflows = base_ci.get("workflows") or {}
    # Retiring a release or maintenance workflow together with its file is not a loosening: it ships
    # or upkeeps, it gates nothing. A gating family stays guarded even when its file goes.
    retired = {
        wid for wid, entry in base_workflows.items()
        if root is not None and isinstance(entry, dict) and entry.get("family") in NON_GATING_FAMILIES
        and not (root / ".github/workflows" / f"{wid}.yml").is_file()
    }
    removed("workflow famil(ies)", set(base_workflows) - retired, set(head_ci.get("workflows") or {}))
    removed("architectural run site(s)", set((base_ci.get("architectural") or {}).get("runs_in") or []),
            set((head_ci.get("architectural") or {}).get("runs_in") or []))
    removed("static-check job(s)", set((base_ci.get("static_checks") or {}).get("jobs") or []),
            set((head_ci.get("static_checks") or {}).get("jobs") or []))
    return problems


# ── .swiftlint.yml ───────────────────────────────────────────────────────────

SEVERITY_RANK = {"warning": 1, "error": 2}


def check_swiftlint(base: Optional[str], head: Optional[str], parse: Callable[[str], Any]) -> List[str]:
    problems: List[str] = []
    if base is None or head is None:
        return problems
    try:
        before = parse(base)
        after = parse(head)
    except Exception as exc:  # the compiler's parser raises ArchitectureError subclasses
        return [f"{SWIFTLINT}: could not parse ({exc})"]

    def as_list(value: Any) -> set:
        return {str(v) for v in value} if isinstance(value, list) else set()

    grown = as_list(after.get("excluded")) - as_list(before.get("excluded"))
    if grown:
        problems.append(f"{SWIFTLINT}: top-level excluded grew: {', '.join(sorted(grown))}")
    grown = as_list(after.get("disabled_rules")) - as_list(before.get("disabled_rules"))
    if grown:
        problems.append(f"{SWIFTLINT}: disabled_rules grew: {', '.join(sorted(grown))}")
    shrunk = as_list(before.get("opt_in_rules")) - as_list(after.get("opt_in_rules"))
    if shrunk:
        problems.append(f"{SWIFTLINT}: opt_in_rules lost: {', '.join(sorted(shrunk))}")
    base_rules = before.get("custom_rules") if isinstance(before.get("custom_rules"), dict) else {}
    head_rules = after.get("custom_rules") if isinstance(after.get("custom_rules"), dict) else {}
    for rule_id, rule in base_rules.items():
        if rule_id not in head_rules:
            problems.append(f"{SWIFTLINT}: custom rule {rule_id} was removed")
            continue
        head_rule = head_rules[rule_id] if isinstance(head_rules[rule_id], dict) else {}
        rule = rule if isinstance(rule, dict) else {}
        before_severity = SEVERITY_RANK.get(str(rule.get("severity") or "warning"), 1)
        after_severity = SEVERITY_RANK.get(str(head_rule.get("severity") or "warning"), 1)
        if after_severity < before_severity:
            problems.append(f"{SWIFTLINT}: custom rule {rule_id} demoted to warning")
        grown = as_list(head_rule.get("excluded")) - as_list(rule.get("excluded"))
        if grown:
            problems.append(f"{SWIFTLINT}: custom rule {rule_id} grew excluded by {len(grown)} path(s)")
    return problems


# ── Tests, specifications, scripts, CODEOWNERS ───────────────────────────────


def check_architecture_tests(base: Optional[str], head: Optional[str]) -> List[str]:
    if base is None:
        return []
    before = base.count("@Test(")
    after = head.count("@Test(") if head is not None else 0  # a deleted suite has no tests left
    return [f"{ARCH_TESTS}: architecture tests dropped {before} → {after}"] if after < before else []


def check_compiler_tests(path: str, base: Optional[str], head: Optional[str]) -> List[str]:
    """The tests that hold the compiler, the agent and this guard to their rules may not thin out."""
    if base is None:
        return []
    before = len(PY_TEST_RE.findall(base))
    after = len(PY_TEST_RE.findall(head)) if head is not None else 0
    return [f"{path}: tests dropped {before} → {after}"] if after < before else []


def check_files_kept(root: Path, base_ref: str, directory: str, pattern: str = "*") -> List[str]:
    problems: List[str] = []
    for path in git_ls_tree(root, base_ref, directory):
        if Path(path).match(pattern) and not (root / path).is_file():
            problems.append(f"{path}: deleted (a guarded file may be replaced, not removed)")
    return problems


def check_codeowners(base: Optional[str], head: Optional[str]) -> List[str]:
    if base is None or head is None:
        return []
    owned = lambda text: {line.split()[0] for line in text.splitlines() if line.strip() and not line.lstrip().startswith("#")}
    gone = owned(base) - owned(head)
    return [f"{CODEOWNERS}: owned path(s) removed: {', '.join(sorted(gone))}"] if gone else []


# ── Workflows ────────────────────────────────────────────────────────────────


NEUTRALISED_LINE_RE = re.compile(r"\|\|\s*(?:true|:)(?:\s|$)|;\s*exit\s+0\b|^\s*echo\b")


def _truthy_flag(value: Any) -> bool:
    return str(value).strip().lower() in ("true", "${{ true }}", "1", "yes")


def _gate_lines(run: str) -> List[str]:
    """The lines of a step's command that name a gate and can still fail: not printed with `echo`,
    not followed by `|| true`, `|| :` or `; exit 0`."""
    return [line for line in run.splitlines() if GATE_STEP_RE.search(line) and not NEUTRALISED_LINE_RE.search(line)]


def _gate_steps(job: Any) -> int:
    """Every step that names a gate, whatever its condition: the count a job may not lose."""
    steps = job.get("steps") if isinstance(job, dict) else None
    count = 0
    for step in steps or []:
        if isinstance(step, dict) and isinstance(step.get("run"), str) and GATE_STEP_RE.search(step["run"]):
            count += 1
    return count


def _effective_gate_runs(job: Any) -> Dict[str, str]:
    """The gate steps of a job that can still fail it, keyed by their gate lines: a step whose `run`
    names a gate, that carries no `if:` and no `continue-on-error: true`, and whose gate command is
    not neutralised. Anything that stops a gate from failing the job, by whatever means, drops it
    from this set. The value says why a step is not effective, or is empty when it is."""
    runs: Dict[str, str] = {}
    if not isinstance(job, dict):
        return runs
    job_tolerates = _truthy_flag(job.get("continue-on-error"))
    for step in job.get("steps") or []:
        if not isinstance(step, dict) or not isinstance(step.get("run"), str) or not GATE_STEP_RE.search(step["run"]):
            continue
        named = " ".join(" ".join(line.split()) for line in step["run"].splitlines() if GATE_STEP_RE.search(line))
        key = re.sub(r"\s*(?:\|\|\s*(?:true|:)|;\s*exit\s+0)\s*$", "", re.sub(r"^\s*echo\s+", "", named)).strip("'\" ")
        if job_tolerates:
            reason = "the job gained continue-on-error: true"
        elif _truthy_flag(step.get("continue-on-error")):
            reason = "the step carries continue-on-error: true"
        elif step.get("if") is not None:
            reason = f"the step carries a condition (if: {str(step.get('if')).strip()})"
        elif not _gate_lines(step["run"]):
            reason = "the command is neutralised (echo, `|| true`, `|| :` or `; exit 0`)"
        else:
            reason = ""
        if key not in runs or not reason:
            runs[key] = reason
    return runs


def _trigger_filters(doc_on: Dict[str, Any], key: str) -> set:
    trigger = doc_on.get("pull_request") if isinstance(doc_on.get("pull_request"), dict) else {}
    return set(map(str, trigger.get(key) or [])) if isinstance(trigger.get(key), list) else set()


def check_workflow(path: str, base: Optional[str], head: Optional[str], parse: Callable[[str], Any]) -> List[str]:
    problems: List[str] = []
    if base is None or head is None:
        return problems
    try:
        before = parse(base)
        after = parse(head)
    except Exception as exc:
        return [f"{path}: could not parse ({exc})"]
    before_on = before.get("on") if isinstance(before.get("on"), dict) else {}
    after_on = after.get("on") if isinstance(after.get("on"), dict) else {}
    if "pull_request" in before_on and "pull_request" not in after_on:
        problems.append(f"{path}: no longer runs on pull_request")
    elif "pull_request" in after_on:
        # A path filter on the trigger is a loosening: a PR touching other files no longer runs the workflow.
        ignored = _trigger_filters(after_on, "paths-ignore") - _trigger_filters(before_on, "paths-ignore")
        if ignored:
            problems.append(f"{path}: pull_request gained paths-ignore: {', '.join(sorted(ignored))}")
        before_paths, after_paths = _trigger_filters(before_on, "paths"), _trigger_filters(after_on, "paths")
        if before_paths and after_paths and before_paths - after_paths:
            problems.append(f"{path}: pull_request narrowed paths: {', '.join(sorted(before_paths - after_paths))}")
        elif not before_paths and after_paths:
            problems.append(f"{path}: pull_request gained a paths filter: {', '.join(sorted(after_paths))}")
    before_jobs = before.get("jobs") if isinstance(before.get("jobs"), dict) else {}
    after_jobs = after.get("jobs") if isinstance(after.get("jobs"), dict) else {}
    for job_id, job in before_jobs.items():
        where = f"{path}: job {job_id}"
        if job_id not in after_jobs:
            problems.append(f"{where} was removed")
            continue
        head_job = after_jobs[job_id] if isinstance(after_jobs[job_id], dict) else {}
        job = job if isinstance(job, dict) else {}
        if job.get("if") is None and head_job.get("if") is not None:
            problems.append(f"{where} gained a condition: if: {str(head_job.get('if')).strip()}")
        elif str(head_job.get("if") or "").strip().lower() in ("false", "${{ false }}") and str(job.get("if") or "").strip().lower() not in ("false", "${{ false }}"):
            problems.append(f"{where} was disabled")
        if not _truthy_flag(job.get("continue-on-error")) and _truthy_flag(head_job.get("continue-on-error")):
            problems.append(f"{where} gained continue-on-error: true")
        before_gates = _gate_steps(job)
        after_gates = _gate_steps(head_job)
        if after_gates < before_gates:
            problems.append(f"{where} lost gate step(s): {before_gates} → {after_gates}")
        # A step that still names its gate but can no longer fail the job is a loosening however it is done.
        before_runs = _effective_gate_runs(job)
        after_runs = _effective_gate_runs(head_job)
        for run, reason in sorted(before_runs.items()):
            if not reason and after_runs.get(run):
                problems.append(f"{where} gate step can no longer fail the job: {after_runs[run]}: {run[:120]}")
    return problems


# ── enrichment freshness ─────────────────────────────────────────────────────

# Run inside a tree with its own compiler: compile leniently and print the ids of
# the stale construct records and the stale or broken flows. Lenient, because a
# tree whose strict build fails for another reason must still yield its stale set.
STALE_ENRICHMENT_PROBE = """
import importlib.util, json, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("build_architecture", Path("scripts/build_architecture.py").resolve())
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
try:
    spec.loader.exec_module(module)
    module.LENIENT = True
    model, _site = module.compile_architecture()
except Exception as exc:  # the probe reports, the caller decides
    print(json.dumps({"error": [f"{type(exc).__name__}: {exc}"]}))
    raise SystemExit(0)
interplay = model["interplay"]
records = sorted(
    [n["history_key"] for n in interplay["nodes"] if (n.get("semantic") or {}).get("stale")]
    + [f"page:{p['id']}" for p in interplay.get("pages", []) if (p.get("semantic") or {}).get("stale")]
)
flows = sorted(f["id"] for f in interplay.get("flows", []) if f.get("stale") or f.get("status") != "traceable")
# A lenient compile drops a record or flow it cannot validate (a key for a construct that is gone, a
# step over a node that left the map) and records why under FIDELITY; those are broken, not absent.
import re
fidelity = getattr(module, "FIDELITY", {}) or {}
for message in fidelity.get("constructs_invalid", []):
    found = re.search(r"construct (?:record )?([^\\s]+)", str(message))
    if found and found.group(1) not in records:
        records.append(found.group(1))
for message in fidelity.get("flows_invalid", []):
    found = re.search(r"flow (?:id )?([^\\s:]+)", str(message))
    if found and found.group(1) not in flows:
        flows.append(found.group(1))
# The lenient compile builds no CI plane and sets `gate:` records aside, so they are judged here against
# the workflows as they are: a record whose cited workflow lines changed is stale, and one that no
# longer validates (a renamed job, a dropped script, a changed role) is broken.
if hasattr(module, "ci_record_index"):
    try:
        module.LENIENT = False
        interplay["ci_jobs"] = module.ci_record_index()
        config = module.load_json(module.CONFIG_PATH)
        files = module.read_sources(config)[0] + module.read_launch_sources(config)[0]
        persisted = module.load_json(module.CONSTRUCTS_PATH).get("records", []) if module.CONSTRUCTS_PATH.is_file() else []
        for record in persisted:
            key = str(record.get("key", "")) if isinstance(record, dict) else ""
            if not key.startswith("gate:"):
                continue
            try:
                if module.validate_construct_record(record, interplay, files, model.get("externals"), persisted=True)["stale"]:
                    records.append(key)
            except module.ArchitectureError:
                records.append(key)
    except Exception as exc:  # no CI plane to judge against is a fact to report, not a reason to hide the rest
        records.append(f"gate:* (the CI plane did not compile: {type(exc).__name__})")
print(json.dumps({"records": sorted(set(records)), "flows": sorted(flows)}))
"""


def _stale_enrichment(root: Path, label: str) -> Optional[Dict[str, List[str]]]:
    """The stale records and stale/broken flows of the tree at ``root``, compiled with that
    tree's own compiler; None when the tree has no compiler (it predates the check)."""
    if not (root / "scripts/build_architecture.py").is_file():
        return None
    result = subprocess.run([sys.executable, "-c", STALE_ENRICHMENT_PROBE], cwd=root, capture_output=True, text=True, check=False)
    lines = [line for line in result.stdout.splitlines() if line.strip()]
    try:
        parsed = json.loads(lines[-1]) if lines else None
    except json.JSONDecodeError:
        parsed = None
    if not isinstance(parsed, dict):
        return {"error": [f"{label} tree: the compiler probe printed no result ({result.stderr.strip()[-300:]})"]}
    return parsed


def check_enrichment_fresh(root: Path, base_ref: str) -> List[str]:
    """The model-written layer may not go stale in a PR: every record or flow that is stale or
    broken in the working tree must already have been so on the base."""
    head = _stale_enrichment(root, "head")
    if head is None:
        return []
    if "error" in head:
        return [f"enrichment: the working tree does not compile, so freshness cannot be judged ({head['error'][0][:300]})"]
    base: Optional[Dict[str, List[str]]] = None
    with tempfile.TemporaryDirectory() as tmp:
        worktree = Path(tmp) / "base"
        try:
            subprocess.run(["git", "-C", str(root), "worktree", "add", "--detach", "--quiet", str(worktree), base_ref],
                           check=True, capture_output=True, text=True)
            base = _stale_enrichment(worktree, "base")
        except subprocess.CalledProcessError:
            base = None
        finally:
            subprocess.run(["git", "-C", str(root), "worktree", "remove", "--force", str(worktree)], capture_output=True, text=True)
    tolerated_records = set(base["records"]) if base and "error" not in base else set()
    tolerated_flows = set(base["flows"]) if base and "error" not in base else set()

    def named(ids: List[str]) -> str:
        return ", ".join(ids[:8]) + (f" … and {len(ids) - 8} more" if len(ids) > 8 else "")

    problems: List[str] = []
    records = sorted(set(head["records"]) - tolerated_records)
    if records:
        problems.append(f"enrichment: {len(records)} construct record(s) went stale (the lines they cite changed) and were not "
                        f"refreshed: {named(records)}; run `python3 scripts/architecture_agent.py --constructs --stale-only`")
    flows = sorted(set(head["flows"]) - tolerated_flows)
    if flows:
        problems.append(f"enrichment: {len(flows)} flow(s) went stale or broke (cited lines changed, or an edge went) and were not "
                        f"rewritten: {named(flows)}; run `python3 scripts/architecture_agent.py --flows --stale-only`")
    return problems


# ── Driver ───────────────────────────────────────────────────────────────────


def evaluate(root: Path, base_ref: str) -> List[str]:
    """Every loosening of a guarded declaration in ``root``'s working tree relative to ``base_ref``."""
    parse = _yaml()
    problems: List[str] = []
    problems += check_invariants(git_show(root, base_ref, INVARIANTS), working(root, INVARIANTS))
    problems += check_config(git_show(root, base_ref, CONFIG), working(root, CONFIG), root)
    problems += check_glossary(git_show(root, base_ref, GLOSSARY), working(root, GLOSSARY))
    problems += check_swiftlint(git_show(root, base_ref, SWIFTLINT), working(root, SWIFTLINT), parse)
    problems += check_architecture_tests(git_show(root, base_ref, ARCH_TESTS), working(root, ARCH_TESTS))
    problems += check_files_kept(root, base_ref, SPECIFICATIONS, "*.md")
    problems += check_files_kept(root, base_ref, "scripts", "check-*.py")
    problems += check_files_kept(root, base_ref, "scripts", "collect-*.py")
    problems += check_files_kept(root, base_ref, "scripts", "build_architecture*.py")
    problems += check_files_kept(root, base_ref, "scripts", "architecture_agent.py")
    problems += check_files_kept(root, base_ref, "scripts", "test_*.py")
    for path in COMPILER_TESTS:
        problems += check_compiler_tests(path, git_show(root, base_ref, path), working(root, path))
    problems += check_codeowners(git_show(root, base_ref, CODEOWNERS), working(root, CODEOWNERS))
    for path in GUARDED_WORKFLOWS:
        problems += check_workflow(path, git_show(root, base_ref, path), working(root, path), parse)
    problems += check_enrichment_fresh(root, base_ref)
    return problems


def main(argv: List[str]) -> int:
    args = [a for a in argv if not a.startswith("--")]
    allow = "--allow-loosening" in argv
    base_ref = args[0] if args else "origin/main"
    problems = evaluate(ROOT, base_ref)
    if not problems:
        print(f"Constraint ratchet: no declaration is looser than {base_ref}.")
        return 0
    print(f"Constraint ratchet: {len(problems)} loosening(s) relative to {base_ref}:")
    for problem in problems:
        print(f"  - {problem}")
    if allow:
        print("Allowed: this PR carries the constraints-loosened label; the loosening is explicit, not silent.")
        return 0
    print(
        "\nA constraint may only tighten in an ordinary PR. To loosen one deliberately, say why in the PR and "
        "add the `constraints-loosened` label (a code owner's call); the guard then passes with the loosening on record."
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
