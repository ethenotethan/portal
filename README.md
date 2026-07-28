# Portal

Native macOS + iOS client for AI agent backends — built with Swift + SwiftUI.

Supports **Hermes** (WebSocket JSON-RPC) and **Centaur** (REST + SSE) from a single app. No local server or CLI required.

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
- Xcode 16+ / Swift 6.1+
- [`xcodegen`](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`
- A running gateway: **Hermes** (`researchoors/hermes-agent`) or **Centaur**

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
