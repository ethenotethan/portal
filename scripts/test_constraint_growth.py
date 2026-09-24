#!/usr/bin/env python3
"""Tests for the constraint ratchet (scripts/check-constraint-growth.py)."""
from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("check_constraint_growth", ROOT / "scripts/check-constraint-growth.py")
assert SPEC is not None and SPEC.loader is not None
guard = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(guard)

INVARIANTS = {
    "schema_version": "1.0.0",
    "invariants": [
        {"id": "single-transport", "kind": "single_transport", "transports": ["GatewayClient"], "why": "one socket"},
        {"id": "pool-guarded", "kind": "pool_guarded_by_lock", "resolve_outside_lock": True, "send_outside_lock": True, "why": "lock"},
        {"id": "pool-lifecycle", "kind": "pool_lifecycle_observed", "min": {"pool_register": 1, "pool_resolve": 1}, "why": "ops"},
        {"id": "triggers-observed", "kind": "triggers_observed", "min": 20, "allow_empty": [], "why": "hops"},
        {"id": "machines", "kind": "machines_complete", "declared": {"A.state": ["x"], "B.state": ["y"]}, "allow_dead": {}, "why": "m"},
    ],
}
CONFIG = {
    "schema_version": "1.0.0",
    "layers": [{"id": "experience"}, {"id": "foundation"}],
    "specified_edges": [{"source": "a", "target": "b"}],
    "external_systems": [{"id": "gateway"}, {"id": "keychain"}],
    "external_groups": [{"id": "platform-storage"}],
    "pages": {"items": [{"id": "chat"}, {"id": "cron"}]},
    "ci": {
        "workflows": {"tests": {}, "ratchet": {}},
        "ratchets": [{"id": "warnings"}, {"id": "coverage"}],
        "architectural": {"runs_in": ["tests/swift-lint", "tests/swift-test"]},
        "static_checks": {"jobs": ["architecture-pages/validate"]},
    },
}
SWIFTLINT = """excluded:
  - .build
opt_in_rules:
  - empty_count
disabled_rules:
  - todo
custom_rules:
  no_print:
    regex: "print\\\\("
    severity: warning
    excluded:
      - ".*/Legacy\\\\.swift"
  no_singletons:
    regex: "static let shared"
    severity: error
"""
TESTS_YML = """name: Tests
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
jobs:
  swift-lint:
    name: SwiftLint
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - name: Run SwiftLint
        run: swiftlint lint --strict --baseline .swiftlint-baseline
  swift-test:
    name: Swift package tests
    runs-on: macos-26
    steps:
      - uses: actions/checkout@v4
      - name: Run Swift unit tests
        run: swift test --disable-sandbox
"""
RATCHET_YML = """name: Ratchet
on:
  pull_request:
    branches: [main]
jobs:
  quality:
    name: Quality
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Check the lint baseline did not grow
        run: python3 scripts/check-baseline-growth.py "$BASE"
"""
PAGES_YML = """name: Pages
on:
  pull_request:
    branches: [main]
jobs:
  validate:
    name: Validate model and site
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Verify generated architecture is current
        run: python3 scripts/build_architecture.py --check
      - name: Test architecture compiler
        run: python3 -m unittest scripts/test_architecture.py
"""
ARCH_TESTS = "@Test(\"one\")\nfunc a() {}\n@Test(\"two\")\nfunc b() {}\n"
CODEOWNERS = "# owners\n/.github/ @me\n/architecture/config.json @me\n"


class ConstraintGrowthTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "t@example.com")
        self.git("config", "user.name", "t")
        self.write(guard.INVARIANTS, json.dumps(INVARIANTS, indent=2))
        self.write(guard.CONFIG, json.dumps(CONFIG, indent=2))
        self.write(guard.SWIFTLINT, SWIFTLINT)
        self.write(guard.ARCH_TESTS, ARCH_TESTS)
        self.write(guard.CODEOWNERS, CODEOWNERS)
        self.write(".github/workflows/tests.yml", TESTS_YML)
        self.write(".github/workflows/ratchet.yml", RATCHET_YML)
        self.write(".github/workflows/architecture-pages.yml", PAGES_YML)
        self.write("architecture/specifications/system.md", "# System\n")
        self.write("scripts/check-metrics-ratchet.py", "# guard\n")
        self.write("scripts/collect-warnings.py", "# collector\n")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "base")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def git(self, *args: str) -> None:
        subprocess.run(["git", "-C", str(self.root), *args], check=True, capture_output=True)

    def write(self, path: str, text: str) -> None:
        file = self.root / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(text, encoding="utf-8")

    def edit_json(self, path: str, mutate) -> None:
        doc = json.loads((self.root / path).read_text(encoding="utf-8"))
        mutate(doc)
        self.write(path, json.dumps(doc, indent=2))

    def problems(self) -> list[str]:
        return guard.evaluate(self.root, "main")

    # ---- the unchanged and the tightened tree pass ------------------------------

    def test_unchanged_tree_has_no_loosening(self) -> None:
        self.assertEqual([], self.problems())

    def test_tightening_passes(self) -> None:
        def tighten(doc):
            doc["invariants"][3]["min"] = 30
            doc["invariants"][2]["min"]["pool_remove"] = 1
            doc["invariants"].append({"id": "new-one", "kind": "stores_mapped", "why": "x"})
        self.edit_json(guard.INVARIANTS, tighten)
        self.edit_json(guard.CONFIG, lambda doc: doc["external_systems"].append({"id": "apns"}))
        self.write(guard.SWIFTLINT, SWIFTLINT.replace("severity: warning\n    excluded", "severity: error\n    excluded") + "  no_nslog:\n    regex: \"NSLog\"\n    severity: error\n")
        self.write(guard.ARCH_TESTS, ARCH_TESTS + "@Test(\"three\")\nfunc c() {}\n")
        self.write(".github/workflows/ratchet.yml", RATCHET_YML + "  constraints:\n    name: Constraints\n    runs-on: ubuntu-latest\n    steps:\n      - run: python3 scripts/check-constraint-growth.py\n")
        self.write("architecture/specifications/new.md", "# New\n")
        self.assertEqual([], self.problems())

    # ---- invariants ------------------------------------------------------------

    def test_invariant_loosenings_are_named(self) -> None:
        def loosen(doc):
            doc["invariants"] = [i for i in doc["invariants"] if i["id"] != "single-transport"]
            doc["invariants"][0]["resolve_outside_lock"] = False           # pool-guarded
            doc["invariants"][1]["min"] = {"pool_register": 1}              # pool-lifecycle: dropped a key
            doc["invariants"][2]["min"] = 10                                # triggers-observed: lowered
            doc["invariants"][2]["allow_empty"] = ["chat"]                  # grew exceptions
            doc["invariants"][3]["declared"] = {"A.state": ["x"]}           # machines: dropped B
            doc["invariants"][3]["kind"] = "pages_populated"                # kind changed
        self.edit_json(guard.INVARIANTS, loosen)
        problems = self.problems()
        expected = [
            "invariant 'single-transport' was removed",
            "invariant 'pool-guarded' switched off resolve_outside_lock",
            "invariant 'pool-lifecycle' dropped min[pool_resolve] (was 1)",
            "invariant 'triggers-observed' lowered min 20 → 10",
            "invariant 'triggers-observed' grew allow_empty by 1 exception(s)",
            "invariant 'machines' changed kind 'machines_complete' → 'pages_populated'",
            "invariant 'machines' dropped declared B.state",
        ]
        for needle in expected:
            self.assertTrue(any(needle in p for p in problems), f"{needle!r} not in {problems}")
        self.assertEqual(len(expected), len(problems))
        widened = json.loads(json.dumps(INVARIANTS))
        widened["invariants"][0]["transports"] = ["GatewayClient", "Other"]
        self.write(guard.INVARIANTS, json.dumps(widened, indent=2))
        self.assertEqual(1, len(self.problems()))
        self.assertIn("invariant 'single-transport' widened transports by 1", self.problems()[0])

    # ---- config ----------------------------------------------------------------

    def test_config_removals_are_named(self) -> None:
        def loosen(doc):
            doc["external_systems"] = [{"id": "gateway"}]
            doc["external_groups"] = []
            doc["pages"]["items"] = [{"id": "chat"}]
            doc["layers"] = [{"id": "experience"}]
            doc["specified_edges"] = []
            doc["ci"]["ratchets"] = [{"id": "warnings"}]
            del doc["ci"]["workflows"]["ratchet"]
            doc["ci"]["architectural"]["runs_in"] = ["tests/swift-lint"]
            doc["ci"]["static_checks"]["jobs"] = []
        self.edit_json(guard.CONFIG, loosen)
        problems = self.problems()
        for needle in ("external system(s) removed: keychain", "external group(s) removed: platform-storage", "page(s) removed: cron",
                       "layer(s) removed: foundation", "specified edge(s) removed: a→b", "ratchet(s) removed: coverage",
                       "workflow famil(ies) removed: ratchet", "architectural run site(s) removed: tests/swift-test",
                       "static-check job(s) removed: architecture-pages/validate"):
            self.assertTrue(any(needle in p for p in problems), f"{needle!r} not in {problems}")
        self.assertEqual(9, len(problems))

    # ---- lint rules, tests, files, owners ---------------------------------------

    def test_swiftlint_loosenings_are_named(self) -> None:
        loosened = (
            SWIFTLINT.replace("excluded:\n  - .build", "excluded:\n  - .build\n  - Sources/Portal/Views")
            .replace("opt_in_rules:\n  - empty_count", "opt_in_rules: []")
            .replace("disabled_rules:\n  - todo", "disabled_rules:\n  - todo\n  - force_cast")
            .replace('      - ".*/Legacy\\\\.swift"', '      - ".*/Legacy\\\\.swift"\n      - ".*/Another\\\\.swift"')
            .replace("static let shared\"\n    severity: error", "static let shared\"\n    severity: warning")
        )
        self.write(guard.SWIFTLINT, loosened)
        problems = self.problems()
        for needle in ("top-level excluded grew: Sources/Portal/Views", "opt_in_rules lost: empty_count", "disabled_rules grew: force_cast",
                       "custom rule no_print grew excluded by 1", "custom rule no_singletons demoted to warning"):
            self.assertTrue(any(needle in p for p in problems), f"{needle!r} not in {problems}")
        self.write(guard.SWIFTLINT, SWIFTLINT.replace("  no_singletons:\n    regex: \"static let shared\"\n    severity: error\n", ""))
        self.assertIn(".swiftlint.yml: custom rule no_singletons was removed", self.problems())

    def test_tests_specs_scripts_and_owners_cannot_shrink(self) -> None:
        self.write(guard.ARCH_TESTS, "@Test(\"one\")\nfunc a() {}\n")
        (self.root / "architecture/specifications/system.md").unlink()
        (self.root / "scripts/check-metrics-ratchet.py").unlink()
        (self.root / "scripts/collect-warnings.py").unlink()
        self.write(guard.CODEOWNERS, "# owners\n/.github/ @me\n")
        problems = self.problems()
        for needle in ("architecture tests dropped 2 → 1", "architecture/specifications/system.md: deleted",
                       "scripts/check-metrics-ratchet.py: deleted", "scripts/collect-warnings.py: deleted",
                       "owned path(s) removed: /architecture/config.json"):
            self.assertTrue(any(needle in p for p in problems), f"{needle!r} not in {problems}")
        self.assertEqual(5, len(problems))

    # ---- workflows --------------------------------------------------------------

    def test_workflow_loosenings_are_named(self) -> None:
        self.write(".github/workflows/tests.yml", TESTS_YML
                   .replace("  pull_request:\n    branches: [main]\n", "")
                   .replace("      - name: Run SwiftLint\n        run: swiftlint lint --strict --baseline .swiftlint-baseline\n", "")
                   .replace("  swift-test:\n    name: Swift package tests\n", "  swift-test:\n    name: Swift package tests\n    if: github.event_name == 'push'\n"))
        self.write(".github/workflows/ratchet.yml", RATCHET_YML.replace("  quality:", "  quality-renamed:"))
        self.write(".github/workflows/architecture-pages.yml", PAGES_YML.replace("    runs-on: ubuntu-latest\n", "    runs-on: ubuntu-latest\n    if: false\n"))
        problems = self.problems()
        for needle in ("tests.yml: no longer runs on pull_request", "tests.yml: job swift-lint lost gate step(s): 1 → 0",
                       "tests.yml: job swift-test gained a condition", "ratchet.yml: job quality was removed",
                       "architecture-pages.yml: job validate gained a condition: if: false"):
            self.assertTrue(any(needle in p for p in problems), f"{needle!r} not in {problems}")
        self.assertEqual(5, len(problems))

    def test_guard_predating_a_file_skips_it(self) -> None:
        # A base without CODEOWNERS or the specifications dir: nothing to compare, nothing flagged.
        self.git("rm", "-q", guard.CODEOWNERS)
        self.git("commit", "-q", "-m", "no owners")
        self.write(guard.CODEOWNERS, "/x @me\n")
        self.assertEqual([], self.problems())

    # ---- the real repository ---------------------------------------------------

    def test_real_repository_is_not_looser_than_its_own_head(self) -> None:
        problems = guard.evaluate(ROOT, "HEAD")
        loosened_by_this_change = [p for p in problems if not p.endswith("deleted (a guarded file may be replaced, not removed)")]
        self.assertEqual([], loosened_by_this_change)

    def test_main_reports_and_honours_the_label(self) -> None:
        self.edit_json(guard.INVARIANTS, lambda doc: doc["invariants"].pop())
        code = subprocess.run([sys.executable, str(ROOT / "scripts/check-constraint-growth.py"), "main"],
                              cwd=self.root, capture_output=True, text=True, check=False)
        # The script evaluates ROOT (the real repo), so drive evaluate() directly for the fake one…
        self.assertIn(code.returncode, (0, 1))
        problems = self.problems()
        self.assertEqual(1, len(problems))
        # …and check the label logic on the module's main with a stub evaluate.
        original = guard.evaluate
        try:
            guard.evaluate = lambda root, base: ["x: invariant 'a' was removed"]
            self.assertEqual(1, guard.main(["main"]))
            self.assertEqual(0, guard.main(["main", "--allow-loosening"]))
            guard.evaluate = lambda root, base: []
            self.assertEqual(0, guard.main([]))
        finally:
            guard.evaluate = original


if __name__ == "__main__":
    unittest.main()
