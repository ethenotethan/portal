#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
output="$(python3 "$SCRIPT_DIR/portal-pr-kanban-sync.py" sync --actor kanban-sync 2>&1)" || {
  printf '%s\n' "$output"
  exit 1
}
# Successful reconciliation is intentionally silent; the artifact is the output.
