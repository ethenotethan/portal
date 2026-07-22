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
| `file_length` (800/1200), `type_body_length` (600/900) | Growth guards. ChatViewModel reached 2,500+ lines before these were re-enabled. Legacy giants carry a file-level `swiftlint:disable` pragma with a justification comment; new files are held to the real limits. | SwiftLint |
| ViewModels must not construct Views | Constructing a View from a ViewModel inverts the layer direction and makes the VM untestable without a UI. | ArchitectureTests |
| `Utils/` must not exist | Two helper directories (`Utils/` and `Utilities/`) meant every contributor guessed where shared code lived. Everything merged into `Utilities/`. | ArchitectureTests |
| Every `GatewayEvent` wire type is documented | `docs/rpc-reference.md` is the contract clients and the gateway build against. The test parses the `case "x.y":` strings from `GatewayEvent.from(type:)` and asserts each appears in the doc — the sync we used to do by hand. | ArchitectureTests |

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
