# Portal

The native macOS + iOS client for **[Harness](https://github.com/ethenotethan/harness)** — an opinionated fork of [Hermes Agent](https://github.com/NousResearch/hermes-agent). Swift 6 + SwiftUI, no local server, no CLI, no Electron.

Harness and Portal are two halves of one product. Upstream Hermes Agent exposes an OpenAI-compatible HTTP API and drives its own TUI; Harness adds the WebSocket JSON-RPC gateway (`/v1/ws`) and the agent-side machinery that a rich native client needs — a wiki API with an edit history, a cron *dataflow* graph, living artifacts, a learning surface, a read-only file browser, push notifications. Portal is the surface built for that gateway: every one of those RPCs has a view here. Everything Harness changes relative to upstream is published as a fork diff at **[ethenotethan.github.io/harness](https://ethenotethan.github.io/harness/)**, kept honest by CI on the Harness side.

Stock hermes-agent is not a supported backend: it has no `/v1/ws`, so the health probe passes and the socket upgrade fails. Run Harness — see [docs/gateway-setup.md](docs/gateway-setup.md).

**[ethenotethan.github.io/portal](https://ethenotethan.github.io/portal/)** — the feature tour, with screenshots and an architecture walkthrough.

## What you get

- **Chat** — streaming responses with tool calls, reasoning traces, Mermaid diagrams, LaTeX, syntax-highlighted code, and file attachments
- **Canvas** — the conversation as a resizable panel; peel any message into a floating card
- **Thought graph** — live DAG of the agent's tool-call chain with on-device reasoning summarization
- **Session tools** — spawn tree, session observer, playback timeline, prompt breakdown, token usage
- **Wiki** — Obsidian-style browser with 2D/3D force graphs, a glossary editor, and the edit timeline Harness records for every page write
- **Cron dataflow graph** — jobs, the data they read and write, the services they touch, and the source files behind each job, drawn from the metadata Harness makes jobs declare
- **Living artifacts** — revisioned datasets, models, timelines, kanban boards and HTML documents the agent maintains and the app renders live
- **Skills, files, activity inbox** — browse and edit skills, read the gateway host's scripts and source in-app, handle approvals and clarifications
- **Learning** — quizzes and flashcard decks with SM-2 spaced repetition
- **Multi-gateway** — save and switch between several Harness gateways; per-gateway session and artifact scoping

### Other backends

Portal also speaks to **[Centaur](https://github.com/paradigmxyz/centaur)** (REST + SSE, sandboxed, non-interactive) through the same `AgentBackend` contract, and can manage a stock **Hermes Standard** install over its HTTP API. Both are deliberately narrower: each backend declares its capabilities, and the UI hides what the connected backend can't honour. Harness is the one that serves the full surface.

## Requirements

- macOS 14 (Sonoma) / iOS 17+
- Xcode 16+ / Swift 6.1+
- [`xcodegen`](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`
- A running **Harness** gateway ([`ethenotethan/harness`](https://github.com/ethenotethan/harness)) — or, for the reduced surface, Centaur ([`paradigmxyz/centaur`](https://github.com/paradigmxyz/centaur))

## Build & Run

```bash
git clone https://github.com/ethenotethan/portal.git
cd portal

swift build          # SwiftPM library build
make build           # full macOS app (xcodegen + xcodebuild)
make run             # build and launch (macOS)
```

> `make build` regenerates `Portal.xcodeproj` from `project.yml` first — don't build a stale `.xcodeproj` directly.

Open `Portal.xcodeproj` in Xcode and select the `Portal-macOS` or `Portal-iOS` target.

## Configuration

On first launch, enter your Harness gateway URL and API key. The app converts `https://` → `wss://` and appends `/v1/ws` automatically.

Add or switch gateways any time from **Settings → Connection → Saved Gateways**.

## Architecture

The public [Architecture Observatory](https://ethenotethan.github.io/portal/architecture/)
combines an interactive source-backed component graph with reviewed
specifications and evidence. Its model is maintained through pull requests and
published from `main` with GitHub Pages, alongside the
[product site](https://ethenotethan.github.io/portal/) at the root. Build or
preview the observatory locally with `make architecture` and
`make architecture-serve`; preview both together with `make site-serve`.

```
App/
  MacApp.swift / IOSApp.swift     # platform entry points
Sources/Portal/
  Views/                          # SwiftUI views
  ViewModels/                     # @MainActor ObservableObjects
  Models/                         # value types, codable models
  Services/                       # networking, persistence, inference
```

Swift 6 strict concurrency throughout (`@MainActor`, `Sendable`). SwiftLint enforces zero violations on every CI run.

The gateway contract Portal is written against — every RPC and event — is catalogued in [docs/rpc-reference.md](docs/rpc-reference.md); the Harness side documents each surface under its `docs/api/`.

## License

MIT
