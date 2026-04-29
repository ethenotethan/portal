# Hermes Native

Native macOS client for [Hermes Agent](https://github.com/nousresearch/hermes-agent) — built with Swift + SwiftUI.

Connects directly to a Hermes Gateway via WebSocket JSON-RPC (`/v1/ws`), giving you full TUI parity from a native Mac app. No local server, no CLI, no Node.js.

## Features

- **WebSocket JSON-RPC** — 50+ gateway methods: sessions, prompts, approvals, config, skills, cron
- **Streaming chat** — real-time `message.delta` / `tool.start` / `tool.complete` events
- **macOS Keychain** — API key stored securely via Security framework
- **Zero dependencies** — pure Swift, SwiftUI, URLSession + URLSessionWebSocketTask
- **Swift 6 strict concurrency** — no data races, no `@Sendable` gymnastics

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 16+ / Swift 6+
- A running Hermes Gateway with API server enabled (`api_server` platform)

## Build

```bash
git clone https://github.com/researchoors/hermes-native.git
cd hermes-native
swift build
```

## Run

```bash
swift run
```

Or open `Package.swift` in Xcode and hit ▶.

## Configuration

On first launch, enter your gateway URL and API key:

| Field | Example |
|-------|---------|
| Gateway URL | `https://gateway.example.com` |
| API Key | Bearer token from `API_SERVER_KEY` |

The app converts `https://` → `wss://` and appends `/v1/ws` automatically.

## Architecture

```
Views (SwiftUI)
  ├── OnboardingView   — first-run setup
  ├── ContentView      — sidebar + chat
  ├── ChatView         — streaming message list
  └── SettingsView     — connection config

ViewModels (@MainActor)
  ├── ChatViewModel        — message state, event handling
  ├── SessionListViewModel — session CRUD
  └── SettingsViewModel    — gateway URL + keychain

Services
  ├── GatewayClient  — WebSocket JSON-RPC client
  └── KeychainStore  — macOS Keychain wrapper

Models
  ├── GatewayEvent    — all server event types (typed enum)
  ├── ChatMessage     — message + tool call structs
  ├── Session         — session metadata
  └── JSONRPC*        — request/response framing
```

## Wire Protocol

Same as the TUI gateway — newline-delimited JSON-RPC 2.0 over WebSocket:

```jsonc
→ {"jsonrpc":"2.0","id":1,"method":"session.create","params":{"cols":120}}
← {"jsonrpc":"2.0","id":1,"result":{"session_id":"abc123"}}

← {"jsonrpc":"2.0","method":"message.delta","params":{"text":"Hello"}}
← {"jsonrpc":"2.0","method":"tool.start","params":{"tool":"terminal","input":"ls"}}
```

## Status

Early development. Core scaffolding compiles and the WebSocket client connects to gateways with Bearer auth. Event streaming and session management are wired up — end-to-end testing in progress.

## License

MIT
