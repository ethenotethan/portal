#!/usr/bin/env bash
#
# diagnose-hang.sh — one-shot main-thread-hang (beachball) context for a
# programming agent (or human). Assembles three high-signal sections so a
# spinning-wheel report can be triaged WITHOUT a debugger session:
#
#   [1] RUNTIME — the MainThreadWatchdog's captured "🔴 MAIN-THREAD HANG" /
#       "🔴 MAIN-THREAD STORM" faults from the unified log: the actual
#       symbolicated stack that stalled the UI. HANG = one overrun turn; STORM =
#       many short turns saturating the run loop (the #254 relayout-loop class,
#       which no single-turn threshold can see). (Requires the app to have run +
#       stalled in the window; DEBUG only.)
#   [2] STATIC — a grep for the known hang anti-patterns (the recurring root
#       causes the watchdog header enumerates), so candidate culprits show up
#       even if the app wasn't running.
#   [3] CHURN — recent git history under Views/ + perf utilities, since a new
#       hang almost always traces to the last view/perf change.
#
# Usage: make diagnose-hang   (or: scripts/diagnose-hang.sh [minutes])
# The optional arg is the log look-back window in minutes (default 15).

set -o pipefail

SUBSYSTEM="com.researchoors.HermesNative"
CATEGORY="perf"
WINDOW_MIN="${1:-15}"
SRC="Sources/HermesNative"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
rule() { printf '%.0s─' {1..72}; printf '\n'; }

bold "HermesNative — hang diagnosis"
echo "window: last ${WINDOW_MIN}m · subsystem: ${SUBSYSTEM} · category: ${CATEGORY}"
rule

# ── [1] RUNTIME: captured hang stacks from the unified log ──────────────────
bold "[1] Captured MAIN-THREAD HANG / STORM faults (runtime)"
if command -v log >/dev/null 2>&1; then
  # os.Logger faults land in the unified log. Pull this subsystem's perf
  # category over the window and keep the hang/storm report + its stack lines.
  HANGS=$(log show --last "${WINDOW_MIN}m" --style compact \
      --predicate "subsystem == \"${SUBSYSTEM}\" AND category == \"${CATEGORY}\"" 2>/dev/null \
      | grep -E "MAIN-THREAD HANG|MAIN-THREAD STORM|beachball|^\s+[0-9]+: " )
  if [ -n "$HANGS" ]; then
    echo "$HANGS"
  else
    echo "  (no hang/storm faults in the last ${WINDOW_MIN}m)"
    echo "  → Reproduce the beachball with the app running a DEBUG build"
    echo "    (make run), then re-run this. The watchdog is on by default in"
    echo "    DEBUG; it logs the culprit stack the instant the main thread"
    echo "    stalls >250ms (HANG) or saturates the run loop across many short"
    echo "    turns (STORM — the multi-session relayout-loop class)."
  fi
else
  echo "  (\`log\` unavailable — not macOS?)"
fi
rule

# ── [2] STATIC: known hang anti-patterns ────────────────────────────────────
bold "[2] Hang anti-pattern hotspots (static scan)"
echo "The three recurring root causes are expensive work reaching the main"
echo "run loop. Candidate sites (verify against the runtime stack above):"
echo

echo "• Timers driving view state (verify each guards to idle when nothing moves):"
grep -rn "Timer.publish" "$SRC" 2>/dev/null | grep -v "//" | sed 's|^|    |' || echo "    (none)"
echo

echo "• withAnimation inside .onReceive (queues a transaction per tick):"
grep -rn -A3 "\.onReceive" "$SRC" 2>/dev/null | grep -B1 "withAnimation" | grep "onReceive\|withAnimation" | sed 's|^|    |' || echo "    (none)"
echo

echo "• Pure heavy work called from a SwiftUI body/computed var (should be"
echo "  memoized via RenderMemo or computed once in init, not per render):"
grep -rn -E "\.(parse|extract|build|link|compose|highlight)\(" "$SRC/Views" 2>/dev/null \
    | grep -vE "RenderMemo|// " | sed 's|^|    |' | head -30 || echo "    (none)"
echo

echo "• Synchronous file I/O on a view path (Data(contentsOf:)/JSONDecoder in Views):"
grep -rn -E "Data\(contentsOf:|JSONDecoder\(\).decode" "$SRC/Views" 2>/dev/null | sed 's|^|    |' || echo "    (none)"
rule

# ── [3] CHURN: recent view / perf changes ───────────────────────────────────
bold "[3] Recent changes under Views/ + perf utilities (git)"
echo "A new hang usually traces to the last view/perf change:"
echo
git log --oneline -15 -- "$SRC/Views" "$SRC/Utilities/PerfInstrumentation.swift" \
    "$SRC/Utilities/RenderMemo.swift" "$SRC/Utilities/MainThreadWatchdog.swift" 2>/dev/null \
    | sed 's|^|  |' || echo "  (no git history)"
rule

bold "Next steps"
cat <<'EOF'
  • If [1] shows a stack: that frame IS the culprit — move it off @MainActor,
    wrap it in RenderMemo, or break the layout loop it names.
  • If [1] is empty: reproduce with `make run` (watchdog on by default), or
    `make run ARGS=--hang-fatal` to trap the hang as an assertion in a debugger.
  • Cross-reference [1] against the [2] hotspots and the [3] recent changes.
EOF
