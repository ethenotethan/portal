from __future__ import annotations

import subprocess
import unittest

from automation.product_factory.triage import (
    apply_labels,
    default_labels,
    ensure_labels,
    replace_state_label,
)


class ProductFactoryTriageTests(unittest.TestCase):
    def test_plain_issue_is_admitted_with_safe_operational_defaults(self) -> None:
        labels = default_labels(
            {
                "title": "Toolbar button does nothing",
                "body": "Clicking the toolbar control has no effect.",
                "labels": [],
            }
        )

        self.assertEqual(
            labels,
            {
                "factory:product",
                "factory:ready",
                "state:ready",
                "priority:P2",
                "validation:interactive",
                "risk:bounded",
            },
        )

    def test_existing_bug_label_is_bounded_and_ready(self) -> None:
        labels = default_labels(
            {
                "title": "Crash when opening Timeline",
                "body": "Existing behavior regressed.",
                "labels": ["bug"],
            }
        )

        self.assertIn("risk:bounded", labels)
        self.assertIn("factory:ready", labels)
        self.assertIn("state:ready", labels)

    def test_security_sensitive_issue_routes_to_human_approval_design(self) -> None:
        labels = default_labels(
            {
                "title": "Change authentication and permissions",
                "body": "Redesign credential storage.",
                "labels": ["enhancement"],
            }
        )

        self.assertIn("risk:human-approval", labels)
        self.assertIn("state:design", labels)
        self.assertNotIn("factory:ready", labels)
        self.assertNotIn("state:ready", labels)

    def test_backend_issue_uses_noninteractive_validation(self) -> None:
        labels = default_labels(
            {
                "title": "Fix reconciliation cursor",
                "body": "The SQLite checkpoint can roll backward.",
                "labels": ["bug"],
            }
        )

        self.assertIn("validation:noninteractive", labels)
        self.assertNotIn("validation:interactive", labels)

    def test_replace_state_label_removes_prior_lifecycle_and_adds_next(self) -> None:
        calls = []

        def run(command, **kwargs):
            calls.append(command)
            return subprocess.CompletedProcess(command, 0, "", "")

        replace_state_label(
            "ethenotethan/portal",
            510,
            current_labels={"factory:product", "state:ready", "priority:P2"},
            new_state="state:implementing",
            run=run,
        )

        command = calls[0]
        self.assertIn("--remove-label", command)
        self.assertIn("state:ready", command)
        self.assertEqual(command[-2:], ["--add-label", "state:implementing"])

    def test_ensure_labels_creates_manifest_entries(self) -> None:
        calls = []

        def run(command, **kwargs):
            calls.append(command)
            return subprocess.CompletedProcess(command, 0, "", "")

        ensure_labels(
            "ethenotethan/portal",
            [{"name": "factory:product", "color": "123456", "description": "Product lane"}],
            run=run,
        )

        self.assertEqual(calls[0][:4], ["gh", "label", "create", "factory:product"])
        self.assertIn("--force", calls[0])

    def test_apply_labels_uses_one_bounded_gh_mutation(self) -> None:
        calls = []

        def run(command, **kwargs):
            calls.append((command, kwargs))
            return subprocess.CompletedProcess(command, 0, stdout="", stderr="")

        apply_labels(
            "ethenotethan/portal",
            321,
            {"state:ready", "factory:product", "priority:P2"},
            run=run,
        )

        command, kwargs = calls[0]
        self.assertEqual(command[:5], ["gh", "issue", "edit", "321", "--repo"])
        self.assertEqual(command[5], "ethenotethan/portal")
        self.assertEqual(command[6:8], ["--add-label", "factory:product,priority:P2,state:ready"])
        self.assertNotIn("GH_TOKEN", kwargs["env"])
        self.assertNotIn("GITHUB_TOKEN", kwargs["env"])

    def test_factory_owned_issue_is_not_retriaged(self) -> None:
        labels = default_labels(
            {
                "title": "Already managed",
                "body": "",
                "labels": ["factory:product", "state:triage"],
            }
        )

        self.assertEqual(labels, set())


if __name__ == "__main__":
    unittest.main()
