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
      minimum dropped); `allow_*` exceptions grown; a `*_outside_lock` gate
      flipped off; a `declared` machine dropped; `transports` widened.
  architecture/config.json
      a declared external system, external group, page, layer, specified edge,
      ratchet, workflow family, architectural run-site or static-check job
      removed. (Components are not guarded: every file must be assigned anyway.)
  .swiftlint.yml
      a custom rule removed or demoted from error to warning; a rule's or the
      top-level `excluded` list grown; `disabled_rules` grown; `opt_in_rules`
      shrunk.
  Tests/PortalTests/ArchitectureTests.swift
      fewer `@Test(` cases than base.
  architecture/specifications/*.md, scripts/check-*.py, scripts/collect-*.py
      a file deleted.
  .github/workflows/{tests,ratchet,architecture-pages}.yml
      a job removed; a job given an `if:` it did not have (or `if: false`);
      fewer gate steps in a job (steps that run a check script, a test runner,
      swiftlint, gitleaks or periphery); `pull_request` dropped from `on`.
  .github/CODEOWNERS
      an owned path removed.

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
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

ROOT = Path(__file__).resolve().parents[1]

INVARIANTS = "architecture/interplay/invariants.json"
CONFIG = "architecture/config.json"
SWIFTLINT = ".swiftlint.yml"
ARCH_TESTS = "Tests/PortalTests/ArchitectureTests.swift"
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


# ── config.json ──────────────────────────────────────────────────────────────


def _ids(items: Any, key: str = "id") -> set:
    return {str(item[key]) for item in items or [] if isinstance(item, dict) and key in item}


def check_config(base: Optional[str], head: Optional[str]) -> List[str]:
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
    edges = lambda doc: {f"{e.get('source')}→{e.get('target')}" for e in doc.get("specified_edges") or [] if isinstance(e, dict)}
    removed("specified edge(s)", edges(base_doc), edges(head_doc))
    base_ci = base_doc.get("ci") or {}
    head_ci = head_doc.get("ci") or {}
    removed("ratchet(s)", _ids(base_ci.get("ratchets")), _ids(head_ci.get("ratchets")))
    removed("workflow famil(ies)", set(base_ci.get("workflows") or {}), set(head_ci.get("workflows") or {}))
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
    if base is None or head is None:
        return []
    before = base.count("@Test(")
    after = head.count("@Test(")
    return [f"{ARCH_TESTS}: architecture tests dropped {before} → {after}"] if after < before else []


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


def _gate_steps(job: Any) -> int:
    steps = job.get("steps") if isinstance(job, dict) else None
    count = 0
    for step in steps or []:
        if isinstance(step, dict) and isinstance(step.get("run"), str) and GATE_STEP_RE.search(step["run"]):
            count += 1
    return count


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
        before_gates = _gate_steps(job)
        after_gates = _gate_steps(head_job)
        if after_gates < before_gates:
            problems.append(f"{where} lost gate step(s): {before_gates} → {after_gates}")
    return problems


# ── Driver ───────────────────────────────────────────────────────────────────


def evaluate(root: Path, base_ref: str) -> List[str]:
    """Every loosening of a guarded declaration in ``root``'s working tree relative to ``base_ref``."""
    parse = _yaml()
    problems: List[str] = []
    problems += check_invariants(git_show(root, base_ref, INVARIANTS), working(root, INVARIANTS))
    problems += check_config(git_show(root, base_ref, CONFIG), working(root, CONFIG))
    problems += check_swiftlint(git_show(root, base_ref, SWIFTLINT), working(root, SWIFTLINT), parse)
    problems += check_architecture_tests(git_show(root, base_ref, ARCH_TESTS), working(root, ARCH_TESTS))
    problems += check_files_kept(root, base_ref, SPECIFICATIONS, "*.md")
    problems += check_files_kept(root, base_ref, "scripts", "check-*.py")
    problems += check_files_kept(root, base_ref, "scripts", "collect-*.py")
    problems += check_codeowners(git_show(root, base_ref, CODEOWNERS), working(root, CODEOWNERS))
    for path in GUARDED_WORKFLOWS:
        problems += check_workflow(path, git_show(root, base_ref, path), working(root, path), parse)
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
