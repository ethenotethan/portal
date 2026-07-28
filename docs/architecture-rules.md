# Architecture Rules

The layer conventions this codebase runs on, and the machinery that enforces
them. Every rule below fails CI with a message explaining why it exists —
enforcement lives in two places:

- **SwiftLint custom rules** (`.swiftlint.yml`, run with `--strict` in CI —
  warnings are promoted to errors, so every rule is blocking)
- **Architecture tests** (`Tests/HermesNativeTests/ArchitectureTests.swift`,
  run by `swift test` — cross-file assertions regex linting can't express)

## The layers

```
Models  →  Services  →  ViewModels  →  Views
```

Dependencies point left. Models know nothing; Services know Models;
ViewModels orchestrate Services and expose observable state; Views render
ViewModel state and never reach past it.

## Enforced rules

| Rule | What it guards | Enforced by |
|------|----------------|-------------|
| `no_direct_client_in_views` | Views must not call `gatewayClientWrapper.client.` — go through a ViewModel or accept an `AgentBackend`. **Incident:** PR #190 — views hardwired to the raw `GatewayClient` broke Centaur sessions, which use a different backend behind the same protocol. | SwiftLint |
| `no_swiftui_in_services` | Services stay platform-agnostic — no `import SwiftUI`. Use Foundation/Combine; presentation belongs in Views/ViewModels. | SwiftLint + ArchitectureTests |
| `no_new_singletons` | No new `static let shared` — singletons are invisible coupling: the dependency never appears in an initializer signature and can't be swapped for a test double. Existing singletons are grandfathered, not endorsed. | SwiftLint |
| `no_raw_error_assignment` | ViewModels must not assign raw strings to `self.error` — raw strings render as red failure banners. **Incident:** #191/#192 — advisory warnings surfaced as failures because everything funneled through the same red banner. Route errors through an error-mapping helper. | SwiftLint |
| `no_print` | `Sources/` must not call `print(` — stdout has no level or subsystem, can't be filtered in Console, and ships to release. Use `Logger` from os.log. | SwiftLint |
| `no_sync_io_on_main` | Views and ViewModels must not call `Data(contentsOf:)`, `NSImage/UIImage(contentsOfFile:)`, or `FileManager.default.contents(atPath:)` — synchronous file I/O on the UI thread blocks the main run loop and causes a beachball. Read files in `Task.detached` (or a background actor) and `await` the result. `ChatViewModel.ingestAttachment` is the correct pattern. Baselined (3 existing in `AttachmentChipView`). | SwiftLint (baselined) |
| `no_swallowed_try` | `Sources/` must not use `try?` — it discards the error and yields nil with no log or branch, so the failure path vanishes silently (the demo works, the field fails). Use `do/catch` to handle or `try` to propagate. Baselined (165 existing). | SwiftLint (baselined) |
| `force_unwrapping`, `force_try`, `force_cast`, `implicitly_unwrapped_optional` | Crash-safety: the unhappy path (`nil`, a throw, a bad cast) must be handled, not asserted away. These are the bugs that crash on real data an agent didn't anticipate. Frozen debt is baselined (see below); new code is held to the bar. | SwiftLint (baselined) |
| `explicit_acl` | New declarations must state their access level — visibility is a decision, not a default. Baselined (~3.5k existing). | SwiftLint (baselined) |
| `discouraged_optional_boolean` | `Bool?` is a silent three-state trap (true / false / nil) — an agent reading a signature can't tell nil from false. Legit tri-state / Codable-optional fields are baselined (7 existing); new optional bools must be added deliberately. | SwiftLint (baselined) |
| Correctness & idiom guards (`unowned_variable_capture`, `contains_over_range_nil_comparison`, `contains_over_filter_count`, `last_where`, `empty_collection_literal`, `reduce_boolean`, `sorted_first_last`, `flatmap_over_map_reduce`, `legacy_multiple`, `modifier_order`, `redundant_nil_coalescing`, `prefer_zero_over_explicit_init`, `optional_data_string_conversion`, `prohibited_super_call`, `discouraged_object_literal`, `private_action`, `self_binding`, `direct_return`) | Zero-baseline guards: `[unowned self]` crash-after-dealloc, `String(data:encoding:)!` crash on invalid UTF-8, allocate-then-discard collection patterns, and uniform modifier/idiom style. All started at zero (existing nits were fixed or auto-corrected when enabled), so any hit is the contributor's own new code. | SwiftLint |
| `file_length` (800/1200), `type_body_length` (600/900) | Growth guards. ChatViewModel reached 2,500+ lines before these were re-enabled. Legacy giants carry a file-level `swiftlint:disable` pragma with a justification comment; new files are held to the real limits. | SwiftLint |

## The lint baseline (frozen debt)

Several rules above have thousands of pre-existing violations that aren't worth
a big-bang cleanup. Rather than disable them (which would let new violations in
too), the existing set is **frozen** in `.swiftlint-baseline`: CI runs
`swiftlint lint --strict --baseline .swiftlint-baseline`, so only violations
that *aren't already in the baseline* — i.e. newly introduced ones — fail.

This is the mechanism that makes strictness safe to turn on and friendly to
lower-effort contributors: you can't inherit the debt, you only see the handful
of errors your own diff created, and the signal is crisp and local.

Rules for the baseline:

- **Never add entries to silence a new violation.** Fix the code instead. The
  baseline is a record of *old* debt, not an escape hatch for new debt. This is
  now *enforced*, not just policy: the **Baseline growth guard** CI job
  (`scripts/check-baseline-growth.py`, also `make lint-baseline-guard`) fails
  the PR if any rule's frozen-entry count grew versus main. Per-rule, so paying
  down one rule can't mask freezing a new violation in another. A genuinely
  intended new entry (rare) must be called out in the PR description — it can
  no longer slip in silently.
- **Regenerate only to pay debt down** — `make lint-baseline` after you've
  fixed some existing violations. The git diff should only ever *remove* rows.
- **Always regenerate via `make lint-baseline`, never raw
  `swiftlint --write-baseline`.** SwiftLint writes *absolute* `file://` paths
  into the baseline; committed as-is it matches only the machine that wrote it,
  so on CI (checkout at `/Users/runner/work/...`) it excludes *nothing* and
  every frozen violation fails. The make target strips the repo prefix to
  repo-relative paths (and asserts none survive) so the baseline is portable.
- **The SwiftLint version is pinned** (`SWIFTLINT_VERSION` in
  `.github/workflows/lint.yml`) and must match the version behind
  `make lint-baseline`. A newer SwiftLint detects *more* violations than the
  baseline froze, so an unpinned bump fails CI on debt it never recorded. To
  upgrade: bump the pin, install the same version locally, `make lint-baseline`,
  commit the workflow + baseline together.
- `make check` runs the full local gate (build + tests + baselined lint +
  baseline-growth guard); if it's green, CI is green.

## The metric ratchet (self-improving benchmarks)

The lint baseline is one instance of a general pattern — a **ratchet**: a
committed benchmark that CI compares each PR against, allowing improvement and
blocking regression. `metrics-baseline.json` + `scripts/check-metrics-ratchet.py`
generalize it to any measurable metric. Adding a metric is a collector script +
a baseline entry + a handler — no new gate.

Four metrics are wired today. Each runs a **floor** (the whole codebase never
regresses); the two line-oriented metrics also run a **patch** (the code this
PR touches meets a higher bar) — so old debt is paid down gradually while new
code is held to a higher standard immediately. The count-only metrics (skipped
tests, dead code) are floor-only: their signal is a single number that must not
rise.

**Compiler warnings** (`warnings` key). A clean `swift build` is parsed into
unique warning *sites* (`file:line:col:category`) by
`scripts/collect-warnings.py` — SwiftPM re-emits each warning per recompiled
module, so a raw line count over-counts (685 lines → 52 real sites here).

- **Floor:** no warning category's site count may exceed the base branch's.
  Per-category, not just total — fixing one category while adding another nets
  flat but is the regression to catch. A category absent from base is an
  *initial freeze* (expected), never a failure. Same shape as
  `check-baseline-growth.py`.
- **Patch:** no warning may sit on a line this PR *added* (from
  `git diff --unified=0 base...HEAD`). New code compiles warning-free even
  while old debt is paid down gradually under the floor.

**Test coverage** (`coverage` key), scoped to the *testable layers* — Models,
Services, ViewModels, Utilities. Views are excluded entirely: `swift test`
never launches the app target, so View bodies never execute and a global
percentage would be dominated by unreachable code (Views measure ~3%,
testable layers ~35% aggregate). `scripts/collect-coverage.py` reduces
`llvm-cov export` to per-line covered/uncovered sets in those layers.

- **Floor:** aggregate testable-layer coverage may not drop more than 0.5
  points vs base — a small band that absorbs measurement jitter and the
  arithmetic dilution of adding a large well-tested file, without letting real
  erosion through.
- **Patch:** of the executable lines this PR *added* in a testable layer, at
  least **80%** must be covered. Deliberately not 100%: defensive branches
  (catch blocks, `??` fallbacks) are legitimately hard to exercise, and a
  zero-tolerance rule would tax every feature PR — the same reason the lint
  rules are baselined rather than absolute. The ratio matches industry
  patch-coverage gates (Codecov et al.). Below 10 added executable lines the
  ratio is too noisy to judge, so the patch check is skipped. Added Views,
  comments, and non-executable declarations never count toward either side.

**Skipped tests** (`skipped` key). `scripts/collect-skipped-tests.py` scans
`Tests/` for the swift-testing idioms that switch a test off — `.disabled(…)`
and `.enabled(if:)` traits, `withKnownIssue { }` — plus the XCTest `XCTSkip*`
forms. A disabled test no longer defends the behavior it names, and disabling a
failing test is the laziest way for an agent to make CI green.

- **Floor:** the count may not rise. The baseline is **0** — any skip is new
  debt and must be justified, not slipped in. Fix and re-enable the test rather
  than switching it off.

**Dead code** (`deadcode` key). `scripts/collect-deadcode.py` reduces a
`periphery scan` to a count of unused declarations. The raw count is large
(~1,100) and partly noise — Periphery can't see KeyPath / reflection /
SwiftUI-runtime uses — so, exactly like the lint baseline, the backlog is
*frozen*, not fixed: a false positive lives harmlessly in the baseline and only
a genuinely *new* unused declaration fails.

- **Floor:** the count may only shrink. A new unused declaration means either
  dead code to delete or a missing caller — both worth catching, since swarms
  accrete code and rarely delete it.

Rules mirror the lint baseline: **regenerate only to record improvement**
(`make metrics-baseline` — warnings/skipped/dead-code must only drop, coverage
only rise), and `make metrics-ratchet` runs the whole check locally (clean
build + tests → collect → ratchet vs `origin/main`). The CI job is
`metric-ratchet` in `lint.yml`; it always builds from scratch (no cache)
because an incremental build under-counts warnings, and pins the Periphery
version (`PERIPHERY_VERSION`) so a tool bump can't shift the frozen count.

Candidate next metrics (each is one collector away): mutation score (verifies
tests actually catch bugs — see issue #10), main-thread stall budget, View
snapshot tests.

| ViewModels must not construct Views | Constructing a View from a ViewModel inverts the layer direction and makes the VM untestable without a UI. | ArchitectureTests |
| `Utils/` must not exist | Two helper directories (`Utils/` and `Utilities/`) meant every contributor guessed where shared code lived. Everything merged into `Utilities/`. | ArchitectureTests |
| Every `GatewayEvent` wire type is documented | `docs/rpc-reference.md` is the contract clients and the gateway build against. The test parses the `case "x.y":` strings from `GatewayEvent.from(type:)` and asserts each appears in the doc — the sync we used to do by hand. | ArchitectureTests |

## Main-thread hang watchdog (beachball tripwire)

This app has fixed the same bug class — a beachball / spinning cursor from the
main thread blocking — over a dozen times (#107, #111, #138, #145, #146, #193,
#210, #217, …). Every one was found the same way: **a human noticed the cursor
spinning and went hunting.** There was no automated detector, so a hang only
became visible when someone happened to be watching the UI at the instant it
stalled. The three root causes are all one symptom (the main run loop doesn't
get back to idle in time): expensive pure work in a SwiftUI `body`, layout
oscillation loops, and synchronous file I/O + JSON decode on the main actor.

`MainThreadWatchdog` (`Sources/HermesNative/Utilities/MainThreadWatchdog.swift`,
DEBUG-only) is the missing tripwire. It observes the main run loop and, when a
turn stays busy past a threshold (250ms default), suspends the main thread,
walks its stack, and reports the **exact call stack that stalled the UI** as an
`os.log` fault — turning "user notices spinning" into a symbolicated culprit
trace in dev and CI. It catches all three causes with one mechanism.

- **Enable it:** launch with `--hang-watchdog` (or `--perf`, which turns it on
  alongside the memory/CPU sampler). Tune with `--hang-threshold-ms=N`.
- **Make a hang fail CI:** add `--hang-fatal`, which escalates a detected hang
  from a logged fault to an `assertionFailure` — so a hang in a UI test trips
  the run instead of scrolling past in the log.
- **Zero cost in release:** the whole file is `#if DEBUG`; release builds get an
  inert shim so `PerfInstrumentation.bootstrap()` still compiles.

When it fires, the fix is one of: move the work off the main actor (a `Task`
off `@MainActor`, or a background queue), memoize pure work with `RenderMemo`,
or break the layout feedback loop. Don't raise the threshold to silence it.

## Requesting an exception

Exceptions are explicit, justified, and grandfathered — never silent:

1. Add the file to the rule's `excluded:` list in `.swiftlint.yml` **with a
   comment** saying why it's exempt (or `// swiftlint:disable <rule>` at file
   scope for the length rules, with the justification on the next line).
2. If the rule is mirrored in `ArchitectureTests.swift` (currently only
   `no_swiftui_in_services`), add the same entry to the allowlist array there
   with a per-entry justification comment — the two lists are kept in sync by
   hand and reviewed together.
3. Say in the PR description what makes this file special. "It was easier" is
   not a justification; "this service renders SwiftUI views to PDF, SwiftUI
   is the point" is.

Grandfathered violations are debt, not precedent: don't add new code to an
excluded file to inherit its exemption.
