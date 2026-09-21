"""Kanban dispatch adapter for separate-generation Product Factory work."""

from __future__ import annotations

from collections.abc import Callable
from typing import Any

from .planner import DispatchSpec


CreateTask = Callable[..., str]


STAGE_SKILLS = {
    "implementation": ["test-driven-development", "verification-evidence"],
    "review": ["github-code-review", "verification-evidence"],
    "validation": ["macos-computer-use", "verification-evidence"],
    "post-merge-validation": ["macos-computer-use", "verification-evidence"],
}


def _body(spec: DispatchSpec) -> str:
    return f"""Execute Product Factory stage: {spec.stage}

GitHub Issue: {spec.issue_url}
Repository: {spec.repo}
Issue number: #{spec.issue_number}
Accepted-intent digest: {spec.intent_digest}
Case: {spec.case_id}
Generation: {spec.generation_id}
Regression lane: {str(spec.regression).lower()}

Treat the GitHub Issue at the accepted digest as the product contract. Work only
in the task-owned worktree. Follow strict test-driven development, inspect the live
issue thread, sweep for duplicate PRs, and run the repository's canonical gates.
When verified, commit, push the branch, and open a PR against main whose body contains
`Closes #{spec.issue_number}`. Apply `factory:product`, `state:review`, and the Issue's
priority/risk/validation labels to the PR. Read the created PR back and include its URL,
head SHA, exact test commands, and results in your completion summary. Do not merge the
PR or close the Issue; independent review, validation, and merge are separate stages.
Never claim CUA validation unless cua-driver was actually used against the exact PR SHA.
"""


def create_dispatch_task(
    spec: DispatchSpec,
    *,
    create_task: CreateTask,
    assignee: str,
    project_id: str,
) -> str:
    """Create one idempotent, task-owned generation through Kanban's public API."""
    return create_task(
        title=f"[{spec.stage}] #{spec.issue_number} {spec.title}",
        body=_body(spec),
        assignee=assignee,
        created_by="portal-product-factory",
        workspace_kind="worktree",
        project_id=project_id,
        idempotency_key=f"product-factory:{spec.generation_id}",
        skills=STAGE_SKILLS.get(spec.stage, ["verification-evidence"]),
        max_retries=2,
        goal_mode=True,
        goal_max_turns=8,
        initial_status="running",
        board="portal-product-factory",
    )


def create_validation_task(
    *,
    case_id: str,
    repo: str,
    issue_number: int,
    pr_url: str,
    implementation_task_id: str,
    create_task: CreateTask,
    assignee: str,
    project_id: str,
) -> str:
    """Create the independent run-the-app validation stage for a Product PR."""
    body = f"""Validate Product Factory PR end to end.

GitHub Issue: https://github.com/{repo}/issues/{issue_number}
Pull request: {pr_url}
Case: {case_id}
Implementation task: {implementation_task_id}

Resolve and pin the exact PR head SHA before doing anything. Review the diff and CI.
If the review is clean, replace the PR and Issue lifecycle label with `state:validation`
before launching the app. Then build and run the application from that exact revision.
For user-visible changes, use computer_use/cua-driver against the running macOS or
Simulator application and exercise the changed flow; source inspection or unit tests
alone are not validation.

Capture clear PNG screenshots showing the expected UI state and any important before/
after or interaction states. Keep the PR head immutable. Publish evidence on the
separate `factory-evidence` branch under `factory/evidence/pr-{issue_number}/<head-sha>/`
with a manifest binding every screenshot to the PR number, exact PR head SHA, task ID,
commands, and observed result. Add a PR comment containing inline Markdown images plus
the exact SHA, scenario steps, build/run commands, and pass/fail verdict. The screenshots
must render directly in the PR conversation—not merely be local paths or prose claims.

If validation and independent review pass, replace the PR and Issue lifecycle label with
`state:merge-ready`. If anything fails, request changes, label both `state:blocked`, and
explain the failure with evidence. Never merge the PR and never approve without actual
application execution and at least one attached screenshot for interactive validation.
"""
    return create_task(
        title=f"[validation] #{issue_number} run app + attach screenshots",
        body=body,
        assignee=assignee,
        created_by="portal-product-factory",
        workspace_kind="worktree",
        project_id=project_id,
        parents=[implementation_task_id],
        idempotency_key=f"product-factory:validation:{case_id}:{pr_url}",
        skills=["github-code-review", "macos-computer-use", "verification-evidence"],
        max_retries=2,
        goal_mode=True,
        goal_max_turns=8,
        initial_status="running",
        board="portal-product-factory",
    )


def create_validation_task_on_board(
    *,
    case_id: str,
    repo: str,
    issue_number: int,
    pr_url: str,
    implementation_task_id: str,
    assignee: str = "default",
    project_id: str = "portal",
    board: str = "portal-product-factory",
) -> str:
    """Production adapter for the independent validation worker."""
    from hermes_cli import kanban_db

    with kanban_db.connect_closing(board=board) as conn:
        def create_task(**kwargs: Any) -> str:
            kwargs["board"] = board
            return kanban_db.create_task(conn, **kwargs)

        return create_validation_task(
            case_id=case_id,
            repo=repo,
            issue_number=issue_number,
            pr_url=pr_url,
            implementation_task_id=implementation_task_id,
            create_task=create_task,
            assignee=assignee,
            project_id=project_id,
        )


def create_dispatch_task_on_board(
    spec: DispatchSpec,
    *,
    assignee: str = "default",
    project_id: str = "portal",
    board: str = "portal-product-factory",
) -> str:
    """Production adapter; imported lazily so pure policy tests stay hermetic."""
    from hermes_cli import kanban_db

    with kanban_db.connect_closing(board=board) as conn:
        def create_task(**kwargs: Any) -> str:
            kwargs["board"] = board
            return kanban_db.create_task(conn, **kwargs)

        return create_dispatch_task(
            spec,
            create_task=create_task,
            assignee=assignee,
            project_id=project_id,
        )
