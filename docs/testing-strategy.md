# Testing strategy

A deliberately thin, global contract for what to test and where — so a new
feature has one obvious place to prove itself and CI stays fast and
deterministic. The rule of thumb: **push correctness down to a pure type and
test it there; use a snapshot to pin what a view looks like; reach for a UI
test only for a genuine end-to-end path.**

## The layers (cheapest → most expensive)

1. **Logic / unit** — `swift test` (`make test`). The default home for
   correctness. Parsing, merging, action application, view-model state
   transitions. Fast, hermetic, no gateway. If a behavior can be expressed as
   "given this input, the type produces that output," it belongs here.

2. **View snapshots** — `ViewSnapshotTests` (goldens recorded on CI via
   `snapshot-record.yml` with `SNAPSHOT_RECORD=1`, verified per-pixel with a
   tolerance). The home for "does this view render the way we expect." Pins
   layout/appearance without driving a live app. Add one when a view's visual
   output is the thing worth protecting.

3. **UI / E2E** — `PortalUITests` / `PortalMacUITests` (XCUITest). Slow,
   gateway-dependent, and prone to flakiness (SwiftUI drag/tap gestures are not
   reliably scriptable). Reserve for a few real end-to-end paths (onboarding
   renders, connect succeeds, attach button is always present). **Do not** add a
   per-feature UI test to prove interaction logic — extract that logic into a
   pure type (layer 1) instead.

4. **Hang gate** — `MainThreadHangGateUITests`. A main-thread stall over 250ms
   fails the build. Not a correctness test; a performance guardrail.

## Where a new feature's tests go

- **Interaction/state logic** (e.g. "moving a kanban card sets its column",
  "a merge unions by id"): a pure, dependency-free type + a `swift test` suite.
  This is why `KanbanSpec`, `ArtifactMerge`, `ArtifactActionEngine` are testable
  without a view. Prefer a small value type over a view holding `@State`.
- **How a view looks**: a snapshot.
- **A full user journey across the app**: at most one XCUITest, and only if the
  journey can't be covered by the layers above.

## What CI enforces on every PR

- `swift-tests.yml` — the unit suite (layer 1).
- `build.yml` — builds the **iOS Simulator** target (`Portal-iOS`). A macOS-only
  local `swift build` can pass while iOS CI fails; build the iOS target locally
  before pushing UI changes.
- `lint.yml` — `swiftlint --strict` gated on `.swiftlint-baseline`, plus the
  baseline-growth guard (a new violation must be fixed, not baselined).
- `macos-hang-gate.yml` — layer 4.
- `ios-simulator-tests.yml` — the hermetic offline smoke test (layer 3).
- `snapshot-record.yml` — records/verifies view goldens (layer 2).

`make check` runs lint + baseline-guard + build + tests locally, mirroring CI.

## Guidelines

- **Assert on stable identifiers, not prose, in UI tests.** When a UI test must
  look up an element, prefer `accessibilityIdentifier` over visible text — text
  changes with copy edits (a rename, a reworded label) and silently breaks the
  test. Where a test does assert on visible text (e.g. onboarding's
  "Connect to your harness"), rename the assertion in the same commit as the
  string.
- **No non-determinism in unit tests.** No wall-clock (`Date()`), no network, no
  disk that isn't injected. Inject stores (see `SpawnTreeStore`'s
  `batchHistory` parameter) so a test gets an isolated instance.
- **A failing test is signal, not noise.** Don't baseline around it or weaken an
  assertion to green the build — fix the behavior or delete the obsolete test.
