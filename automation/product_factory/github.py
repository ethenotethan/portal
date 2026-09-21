"""Read-only GitHub Issue client for deterministic reconciliation."""

from __future__ import annotations

import json
import os
import subprocess
from collections.abc import Callable
from typing import Any
from urllib.parse import urlencode


Runner = Callable[..., subprocess.CompletedProcess[str]]
API = Callable[[str], Any]
CONTROL_LABELS = {
    "factory:product",
    "factory:ratchet",
    "factory:ready",
    "factory:design-approved",
    "state:intake",
    "state:triage",
    "state:design",
    "state:ready",
    "state:implementing",
    "state:review",
    "state:validation",
    "state:merge-ready",
    "state:post-merge-validation",
    "state:blocked",
    "state:regressed",
    "validation:interactive",
    "validation:noninteractive",
    "risk:bounded",
    "risk:human-approval",
    "work:parent",
    "work:child",
    "priority:P0",
    "priority:P1",
    "priority:P2",
    "priority:P3",
}


class GitHubReader:
    """Small paginated reader whose API transport can be replaced in tests."""

    def __init__(self, api: API):
        self.api = api

    @staticmethod
    def _endpoint(path: str, *, page: int) -> str:
        return f"{path}?page={page}&per_page=100&state=all"

    def _pages(self, path: str, *, include_state: bool) -> list[dict[str, Any]]:
        records: list[dict[str, Any]] = []
        page = 1
        while True:
            if include_state:
                endpoint = self._endpoint(path, page=page)
            else:
                endpoint = f"{path}?{urlencode({'per_page': 100, 'page': page})}"
            raw = self.api(endpoint)
            if not isinstance(raw, list):
                raise RuntimeError(f"GitHub API returned non-list response for {path}")
            records.extend(item for item in raw if isinstance(item, dict))
            if len(raw) < 100:
                return records
            page += 1

    def fetch_issues(self, repo: str) -> list[dict[str, Any]]:
        issues: list[dict[str, Any]] = []
        for raw in self._pages(f"repos/{repo}/issues", include_state=True):
            if "pull_request" in raw:
                continue
            issues.append(
                {
                    "repo": repo,
                    "number": int(raw["number"]),
                    "node_id": raw.get("node_id"),
                    "title": raw.get("title") or "",
                    "body": raw.get("body") or "",
                    "author": (raw.get("user") or {}).get("login") or "unknown",
                    "labels": sorted(
                        label.get("name")
                        for label in raw.get("labels") or []
                        if isinstance(label, dict) and label.get("name")
                    ),
                    "state": raw.get("state") or "open",
                    "url": raw.get("html_url") or "",
                    "updated_at": raw.get("updated_at") or "",
                    "parent_issue": None,
                }
            )
        return sorted(issues, key=lambda item: item["number"])

    def fetch_label_events(self, repo: str, issue_number: int) -> list[dict[str, Any]]:
        events: list[dict[str, Any]] = []
        for raw in self._pages(
            f"repos/{repo}/issues/{issue_number}/events",
            include_state=False,
        ):
            action = str(raw.get("event") or "")
            label = str((raw.get("label") or {}).get("name") or "")
            if action not in {"labeled", "unlabeled"} or label not in CONTROL_LABELS:
                continue
            events.append(
                {
                    "event_id": raw.get("id"),
                    "action": action,
                    "label": label,
                    "actor": (raw.get("actor") or {}).get("login") or "unknown",
                }
            )
        return events


def _gh_api(run: Runner) -> API:
    env = os.environ.copy()
    env.pop("GH_TOKEN", None)
    env.pop("GITHUB_TOKEN", None)

    def call(endpoint: str) -> Any:
        result = run(
            ["gh", "api", endpoint],
            capture_output=True,
            text=True,
            timeout=60,
            env=env,
        )
        if result.returncode != 0:
            raise RuntimeError(f"GitHub read failed: {result.stderr.strip()[:1000]}")
        try:
            return json.loads(result.stdout)
        except json.JSONDecodeError as exc:
            raise RuntimeError("GitHub read returned invalid JSON") from exc

    return call


def fetch_issues(repo: str, *, run: Runner = subprocess.run) -> list[dict[str, Any]]:
    """Fetch all Issues, excluding pull requests, through the authenticated gh CLI."""
    return GitHubReader(_gh_api(run)).fetch_issues(repo)
