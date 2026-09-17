# Portal

Open-source macOS + iOS SwiftUI client for a personally managed Hermes fork.

Portal presents streaming chat, multi-gateway sessions, knowledge graphs, artifacts, skills, cron, and spaced-repetition learning in a native app. A session-scoped Centaur connection is also supported, but the management surfaces depend on the Hermes fork below.

The Hermes gateway is [`ethenotethan/harness`](https://github.com/ethenotethan/harness), a fork of [`NousResearch/hermes-agent`](https://github.com/NousResearch/hermes-agent). The fork is required, not preferred: stock hermes-agent has no `/v1/ws` endpoint. See [docs/gateway-setup.md](docs/gateway-setup.md).

**[ethenotethan.github.io/portal](https://ethenotethan.github.io/portal/)** — the feature tour, with screenshots and an architecture walkthrough.

## Features

- **Chat** — streaming responses with tool calls, reasoning traces, Mermaid diagrams, LaTeX, syntax-highlighted code, and file attachments
- **Canvas** — the conversation as a resizable panel; peel any message into a floating card
- **Multi-gateway** — save and switch between multiple backends; per-gateway session and artifact scoping
- **Thought graph** — live DAG of the agent's tool-call chain with on-device reasoning summarization
- **Session tools** — spawn tree, session observer, playback timeline, prompt breakdown, token usage
- **Wiki** — Obsidian-style browser with 2D/3D force graphs and edit timeline
- **Skills & cron** — browse, edit, and schedule agent skills; monitor run history
- **Activity inbox** — tool approvals, clarifications, and notifications with artifact preview
- **Learning** — quizzes and flashcard decks with SM-2 spaced repetition

## Requirements

- macOS 14 (Sonoma) / iOS 17+
- A model-provider account or local model supported by Hermes

The managed macOS installer supplies Hermes, its local API server, and its
gateway. Building Portal from source additionally requires:

- Xcode 16+ / Swift 6.1+
- [`xcodegen`](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`

## Managed macOS installer

`make installer` builds `dist/Portal-Installer.dmg`. The image contains the
signed Portal app and **Set Up Portal.command**, which runs as the logged-in user
and:

1. Installs Portal into `~/Applications`.
2. Clones and installs the managed Hermes fork under Portal's Application Support directory.
3. Configures a loopback-only API server with a generated key.
4. Runs Hermes provider setup and installs its per-user launchd gateway.
5. Prefills Portal through a mode-`0600` one-time handoff; Portal moves the values into Keychain after **Connect** is pressed.

It never uses `sudo`, never prints the generated API key, and refuses to replace
an unexpected checkout or unreadable Keychain state. See
[docs/macos-installer.md](docs/macos-installer.md) for the complete security and
release model.

> This removes the manual fork/gateway setup, but it is not yet an honest
> “two-minute setup” guarantee. Provider authentication and dependency downloads
> remain variable and must be measured on clean Macs before making that claim.

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

On first launch, enter your gateway URL and API key. The app converts `https://` → `wss://` and appends `/v1/ws` automatically for Hermes gateways.

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

## License

MIT
