# CI Hardening Spec — scale better, break less post-merge

Status: **proposed** · 2026-07-26

## Context: what CI runs today, and what still breaks

Current gate: strict baselined SwiftLint + per-rule baseline-growth guard
(#222–#225), `swift build -c release`, macOS + iOS `xcodebuild` builds, 330
package tests, iOS simulator smoke + E2E against a checked-out local gateway,
and the DEBUG main-thread hang watchdog (#226, not yet exercised in CI).

The post-merge breakage this repo has actually shipped clusters into:

- **Main-thread hangs** — a dozen+ beachball fixes (#107, #111, #138, #145,
  #146, #193, #210, #217, #231…). Detector now exists (#226) but nothing in
  CI runs it.
- **Swift-concurrency warnings accumulating** — builds scroll
  `ActorIsolatedCall` / Sendable-capture warnings today. These are future
  data races; they ship fine and break intermittently later.
- **Project-generation drift** — the checked-in `.xcodeproj` lagging
  `project.yml`: `swift build` passes, `xcodebuild` fails with "cannot find
  Type in scope".
- **Client/gateway wire drift** — the gateway (researchoors/hermes-agent)
  evolves independently; a payload-shape change surfaces only when the E2E
  happens to exercise that event.
- **Untrusted local gate** — `SubagentGraphIntegratorTests` currently fails
  on a clean local `origin/main` checkout while CI is green, which teaches
  people to ignore red `make check`.

Each item below targets one of those. Same enforcement philosophy as the
lint arc: freeze existing debt, block growth, pay down over time — never a
big-bang cleanup, never honor-system.

---

## Tier 1 — cheap, high leverage (one small PR each)

### 1.1 Compiler-warning ratchet

**Problem.** Swift 6 concurrency diagnostics accumulate unbounded; each one
is a latent data race. A future language-mode migration gets harder every
week.

**Spec.**
- `scripts/check-warning-growth.py`: run `swift build 2>&1`, parse
  `warning:` lines, normalize to `path:count` (per-file count, NOT
  line-keyed — line churn would false-positive), compare against committed
  `.warning-baseline.json`.
- Fail if any file's count grows. Shrink passes; regenerating the baseline
  follows the same shrink-only rules as `.swiftlint-baseline`
  (docs/architecture-rules.md § frozen debt).
- New-file entries are initial-freeze, allowed but printed loudly (mirror
  the fixed semantics of `check-baseline-growth.py`).
- CI job on `macos-26` reusing the release-build job's toolchain; add
  `make warning-guard` and fold into `make check`.

**Acceptance.** A PR adding one new `ActorIsolatedCall` warning to an
existing file fails with the file and delta named; a PR removing warnings
passes and the baseline diff only removes entries.

### 1.2 Project-generation drift check

**Problem.** Committed `.xcodeproj` lags `project.yml` / the Sources tree.

**Spec.** One step in `build.yml` (before the builds, which already run
`xcodegen generate`):

```yaml
- name: Verify committed project matches project.yml
  run: |
    xcodegen generate
    git diff --exit-code -- HermesNative.xcodeproj \
      || { echo "::error::.xcodeproj is stale — run 'make generate' and commit"; exit 1; }
```

**Acceptance.** Adding a source file without regenerating fails with the
actionable message.

### 1.3 Run the hang watchdog in CI (operationalize #226)

**Problem.** The beachball detector exists but no automated run enables it —
detection still depends on a human at the keyboard.

**Spec.**
- Add `--hang-watchdog --hang-fatal --hang-threshold-ms=1000` to the launch
  arguments of the iOS simulator smoke + E2E invocations (CI runners are
  slow; 250 ms would false-positive — tune upward if the first week shows
  runner-noise trips).
- `--hang-fatal` already escalates to `assertionFailure`, so a hang fails
  the test run with the culprit stack in the log; no new plumbing.
- Document the flag set in `docs/architecture-rules.md` § hang watchdog.

**Acceptance.** A deliberate `Thread.sleep(2)` on the main actor in a
smoke-covered path fails CI with the watchdog's stack trace in the artifact
log.

### 1.4 actionlint

**Problem.** Five workflow files, edited four times this week; YAML/
expression/shell errors in workflows fail silently (jobs skip) or at the
worst moment.

**Spec.** New job in `lint.yml`, `ubuntu-latest`,
`raven-actions/actionlint@v2` (or the official docker run). Zero config to
start; shellcheck integration on by default.

**Acceptance.** A workflow referencing `${{ github.event.pullrequest }}`
(typo) fails the job.

---

## Tier 2 — moderate effort, scariest breakage

### 2.1 Cross-repo contract tests (gateway wire compatibility)

**Problem.** Client and gateway are separate repos; the RPC doc-sync arch
test checks the *documentation* mentions each event, not that decoding
works against real payloads.

**Spec — part A, golden fixtures (blocking).**
- `Tests/HermesNativeTests/Fixtures/rpc/<event.type>.json`: one captured
  real payload per documented `GatewayEvent` case (bootstrap from the E2E
  server or session transcripts).
- New test suite: every fixture decodes via `GatewayEvent.from(type:)`
  without throwing and lands in the expected case; every documented case
  has a fixture (mirrors the doc-sync test so the corpus can't rot).

**Spec — part B, nightly canary (advisory).**
- Scheduled workflow (`cron: "17 9 * * *"`) running the existing E2E job
  against hermes-agent **main** instead of the pinned ref.
- On failure: open/refresh a single labeled issue (`gateway-drift`) with the
  failing events; never blocks PRs.

**Acceptance.** A: deleting a fixture or adding an undocumented case fails
locally. B: a gateway payload rename produces a `gateway-drift` issue within
24 h.

### 2.2 Flaky-test quarantine lane

**Problem.** A suite that fails locally-but-not-CI (current:
`SubagentGraphIntegratorTests` layout assertions) erodes trust in the gate;
people start merging over red.

**Spec.**
1. **First**: deflake the integrator suite itself — the failures are
   deterministic-looking layout-coordinate math that diverges by
   environment (likely font metrics / display scale); pin the inputs.
2. CI: rerun failed tests once (`swift test` wrapper script; xcodebuild has
   `-retry-tests-on-failure`). Pass-on-retry is *reported* — a
   `flaky-tests` artifact + PR comment — never silently green.
3. `Tests/quarantine.txt`: shrink-only list (growth-guard script pattern)
   of suites excluded from the blocking run but still executed in a
   non-blocking lane.

**Acceptance.** A test failing then passing on retry shows up in the PR as
flaky; adding a name to quarantine.txt without shrinking elsewhere requires
the same explicit-callout treatment as a baseline addition.

### 2.3 CodeQL security scanning

**Problem.** No static security analysis; this is an agent gateway client
that handles credentials, arbitrary file ingestion, and remote content.

**Spec.** GitHub's stock `codeql.yml` template with `language: swift`,
`macos-26` runner, on PR + weekly schedule. Advisory (not a required check)
for the first month while triaging the initial finding set; then promote.
Findings surface in the Security tab + PR annotations.

**Acceptance.** The workflow completes on a PR and produces a SARIF upload;
a seeded test finding (e.g. `String(contentsOf: URL(string: userInput)!)`)
is flagged.

### 2.4 Periphery dead-code scan (baselined)

**Problem.** One growing module accumulates unreachable code; every
refactor drags corpses, and dead code is where stale patterns hide.

**Spec.** `periphery scan --format json` in a weekly + on-PR advisory job;
findings frozen in `.periphery-baseline.json` with the same shrink-only
growth guard. Promote to blocking after a month of triage.

**Acceptance.** A PR adding an unused `public func` to an existing file
fails the (eventually blocking) guard; the baseline only ever shrinks.

---

## Tier 3 — structural (plan-level, own design docs when picked up)

### 3.1 SPM target split — compiler-enforced layering

Split the single module into `HermesModels` → `HermesServices` →
`HermesViewModels` → app target. Illegal imports become compile errors —
strictly stronger than the regex rules + arch tests that enforce layering
today, and it unlocks per-target build caching (faster CI) and per-target
language modes (3.2). Sequenced after Tier 1/2; big mechanical churn, needs
a quiet week.

### 3.2 Per-target Swift 6 language-mode ratchet

As each target from 3.1 reaches zero concurrency warnings (driven down by
the 1.1 ratchet), flip it to `swiftLanguageMode(.v6)` and commit the
setting — CI then enforces it forever. Data-race safety becomes a
compile-time guarantee module by module.

### 3.3 Changed-lines coverage gate

`swift test --enable-code-coverage` + `llvm-cov export` + diff-aware
threshold (~70% on touched lines, advisory first). Deliberately LAST: a
coverage gate on top of a flaky suite (2.2 unfixed) would make CI hated.
Prerequisite: 2.2 done and quarantine list empty or near-empty.

---

## Sequencing

```
Week 1: 1.1 → 1.2 → 1.3 → 1.4   (independent small PRs)
Week 2: 2.1A (fixtures) → 2.1B (canary) → 2.2 (deflake first) → 2.3
Later:  2.4 → 3.1 → 3.2 → 3.3
```

Dependencies: 3.2 needs 3.1 + 1.1; 3.3 needs 2.2. Everything else is
independent. Each item lands as its own worktree + PR with CI green, per
the standing workflow.
