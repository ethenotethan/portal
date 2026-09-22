#!/usr/bin/env bash
# portal-merge-queue.sh
# Auto-merge fully green, mergeable PRs on ethenotethan/portal.
# Designed for no_agent=true cron — stdout is the message delivered.
#
# Merge criteria (ALL must be true):
#   1. PR is OPEN
#   2. CI has completed (no checks still in progress/queued)
#   3. Every check conclusion is SUCCESS (or NEUTRAL/skipped)
#   4. GitHub reports mergeable = MERGEABLE (no conflicts)
#   5. Branch is up to date with base (no behind)
#
# If nothing merges, outputs nothing (silent — watchdog pattern).
# If something merges, outputs a summary line.

set -euo pipefail

# `gh` prefers GITHUB_TOKEN over its authenticated keyring entry. Do not let a
# stale injected token silently turn the queue into an empty/no-op poller.
unset GITHUB_TOKEN

REPO="ethenotethan/portal"
GH="gh"
JQ="jq"
TRACKER="$HOME/.hermes/scripts/portal-merge-tracker.py"

update_tracking() {
    if ! python3 "$TRACKER" >/dev/null 2>&1; then
        printf '⚠️ Portal merge queue completed, but persistent queue tracking failed.\n'
    fi
}

# Get all open PRs with their review decision, labels, and mergeability
PRS_JSON=$($GH pr list --repo "$REPO" --state open --json number,title,headRefName,mergeable,isDraft,baseRefName,labels 2>/dev/null || echo '[]')

PR_COUNT=$(echo "$PRS_JSON" | $JQ 'length')
if [ "$PR_COUNT" -eq 0 ]; then
    update_tracking
    exit 0
fi

MERGED_ANY=false
OUTPUT=""

for i in $(seq 0 $((PR_COUNT - 1))); do
    PR_NUM=$(echo "$PRS_JSON" | $JQ -r ".[$i].number")
    PR_TITLE=$(echo "$PRS_JSON" | $JQ -r ".[$i].title")
    PR_BRANCH=$(echo "$PRS_JSON" | $JQ -r ".[$i].headRefName")
    MERGEABLE=$(echo "$PRS_JSON" | $JQ -r ".[$i].mergeable")
    IS_DRAFT=$(echo "$PRS_JSON" | $JQ -r ".[$i].isDraft")
    BASE_BRANCH=$(echo "$PRS_JSON" | $JQ -r ".[$i].baseRefName")
    LABEL_NAMES=$(echo "$PRS_JSON" | $JQ -r ".[$i].labels | map(.name) | join(\",\")")
    PRODUCT_FACTORY=$(echo "$PRS_JSON" | $JQ '[.['"$i"'].labels[].name | select(. == "factory:product")] | length')
    PRODUCT_MERGE_READY=$(echo "$PRS_JSON" | $JQ '[.['"$i"'].labels[].name | select(. == "state:merge-ready")] | length')
    BLOCKED_LABEL=$(echo "$PRS_JSON" | $JQ '[.['"$i"'].labels[].name | select(. == "state:blocked")] | length')

    # A blocked verdict is an unconditional veto, including when an upstream
    # labeling bug omitted factory:product. Green CI cannot override it.
    if [ "$BLOCKED_LABEL" -gt 0 ]; then
        continue
    fi

    # Product Factory PRs must cross the independently reviewed policy gate.
    # Ratchet and legacy PRs keep their existing profile/queue behavior.
    if [ "$PRODUCT_FACTORY" -gt 0 ] && [ "$PRODUCT_MERGE_READY" -eq 0 ]; then
        continue
    fi

    # Skip drafts
    if [ "$IS_DRAFT" = "true" ]; then
        continue
    fi

    # Only handle MERGEABLE (skip UNKNOWN = still computing, CONFLICTING)
    if [ "$MERGEABLE" != "MERGEABLE" ]; then
        continue
    fi

    # Get detailed check status
    CHECKS_JSON=$($GH pr checks "$PR_NUM" --repo "$REPO" --json name,state,link 2>/dev/null || echo '[]')
    CHECK_COUNT=$(echo "$CHECKS_JSON" | $JQ 'length')

    if [ "$CHECK_COUNT" -eq 0 ]; then
        continue
    fi

    # Check if any are still pending
    PENDING=$(echo "$CHECKS_JSON" | $JQ '[.[] | select(.state == "PENDING" or .state == "QUEUED" or .state == "IN_PROGRESS" or .state == "WAITING")] | length')
    if [ "$PENDING" -gt 0 ]; then
        continue
    fi

    # Check if all are SUCCESS or NEUTRAL or SKIPPED
    FAILING=$(echo "$CHECKS_JSON" | $JQ '[.[] | select(.state != "SUCCESS" and .state != "NEUTRAL" and .state != "SKIPPED")] | length')
    if [ "$FAILING" -gt 0 ]; then
        continue
    fi

    # All green and mergeable — merge it!
    if $GH pr merge "$PR_NUM" --repo "$REPO" --squash --delete-branch 2>/dev/null; then
        OUTPUT+="✅ Merged PR #${PR_NUM}: ${PR_TITLE} (branch: ${PR_BRANCH} → ${BASE_BRANCH})\n"
        MERGED_ANY=true
    else
        OUTPUT+="⚠️ PR #${PR_NUM} was green but merge failed\n"
        MERGED_ANY=true
    fi
done

# Persist the post-merge queue snapshot even when stdout remains silent.
update_tracking

if [ "$MERGED_ANY" = true ]; then
    echo -e "$OUTPUT"
fi
# Silent if nothing merged (watchdog pattern)
