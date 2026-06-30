# Hermes Native — Design

Native macOS + iOS client for the Hermes Agent gateway. This document covers the
high-level architecture, the gateway connection/auth design, and the key design
decisions. For the exhaustive RPC method + event catalog, see
[`docs/rpc-reference.md`](docs/rpc-reference.md).

## Architecture

```
┌──────────────────────────────────────────┐
│              HermesNative App              │
│        (Swift + SwiftUI, no Electron)      │
├──────────────────────────────────────────┤
│  Views (SwiftUI)                           │
│   ChatView · SessionListView · SettingsView│
│   Wiki/ · MissionControl/ · Playback/      │
│   ThoughtGraph/ · Quiz/ · Feed · Cron      │
├──────────────────────────────────────────┤
│  ViewModels (@MainActor ObservableObject)  │
│   ChatViewModel · SessionListViewModel     │
│   WikiGraphViewModel · SettingsViewModel … │
├──────────────────────────────────────────┤
│  Services                                  │
│   GatewayClient (WS JSON-RPC)              │
│   GatewayClientWrapper (lifecycle)         │
│   KeychainStore · ChatHistoryStore         │
│   FileDownloadManager · CronPoller …       │
├──────────────────────────────────────────┤
│  Models                                    │
│   JSON-RPC types · GatewayEvent enum       │
│   Session · ChatMessage · WikiGraph …      │
└───────────────────┬──────────────────────┘
                    │ wss://gateway.example.com/v1/ws
                    ▼
┌──────────────────────────────────────────┐
│      Hermes Gateway (Python aiohttp)       │
│      API Server :8642  (/v1/ws, /v1/*)     │
└──────────────────────────────────────────┘
```

### Data flow

- **One persistent WebSocket per app process.** `GatewayClientWrapper` owns the
  single `GatewayClient`. Sessions are multiplexed over that socket by
  `session_id`; creating/selecting a session does **not** recreate the transport.
- **Events fan out via Combine.** `GatewayClient` publishes
  `eventStream: PassthroughSubject<(GatewayEvent, String?), Never>`. `ChatViewModel`
  and other view models subscribe, filtering by `session_id`. Rapid deltas are
  batched with `collect(.byTimeOrCount)` (~32ms) to avoid main-thread layout storms.
- **Connection dedupe.** `GatewayClientWrapper` keys connections on a
  `ConnectionSignature` (URL + API key + CF cookie value) so redundant reconnects
  are skipped; a genuine change (e.g. switching gateways) recreates the transport.
- **State reset on gateway switch.** Switching the active gateway writes the chosen
  URL/key into `SettingsViewModel`, which drives the reconnect, then resets in-memory
  view-model state (chat, sessions, activity inbox) so the previous gateway's data
  doesn't leak into the new one. Persisted history is keyed per session ID on disk.

## Gateway Auth Problem & Solution

### Problem
The original WS endpoint lived on the dashboard (port 9119) and was gated by an
ephemeral SPA session token, a loopback-only host restriction, and an embedded-chat
feature flag — so remote native clients could not authenticate or connect. The API
server (port 8642) had only REST/SSE, no WebSocket.

### Solution
A WebSocket endpoint was added to the **API server** (aiohttp, port 8642) that:
- reuses the same JSON-RPC dispatch as the dashboard WS handler,
- authenticates via Bearer token (the API server's existing `_check_auth`),
- has no loopback restriction (the API server already serves remote clients), and
- has no SPA session-token dependency.

The Swift client connects to `wss://gateway:8642/v1/ws` with
`Authorization: Bearer <key>`.

### Cloudflare Access
For CF-gated gateways, the app runs a web-view login flow (`CFAuthView`) to capture
the `CF_Authorization` cookie, verifies it with an HTTP probe to `/health` before
opening the socket, and sends it alongside the bearer token. The cookie is **per-host**
and held in memory only (re-auth on launch / host switch); it is not persisted.

## Connection Lifecycle

```
1. HTTP health probe → <scheme>://<host>/health (5s timeout)
2. If CF cookie set → verify it (200 ok; 302/401/403 → clear + fail)
3. Open WebSocket to /v1/ws with Authorization: Bearer <key> (+ CF cookie)
4. Server sends event gateway.ready {skin}
5. Client: session.create → {session_id (hex), session_key (db format)}
6. Client: prompt.submit → streaming events begin
7. Server streams message.* / tool.* / reasoning.* / subagent.* events
8. Client may: session.interrupt, approval.respond, etc.
9. Ping/pong keepalive every 15s; auto-reconnect with backoff 1→2→4→…→30s (max 10)
10. On reconnect, resume via session_key (lastSessionKey)
```

Two session ID formats matter: the **short hex** `session_id` (current connection,
used in most RPCs) and the **database-format** `session_key`
(e.g. `20260501_112429_d91274`, used to resume across reconnects/restarts).

## Project Structure

```
hermes-native/
├── Package.swift                  # SwiftPM manifest (library target + deps)
├── project.yml                    # xcodegen source of truth for the Xcode project
├── Makefile                       # generate / build / run / kill / lint / test / clean
├── App/
│   ├── MacApp.swift               # macOS @main, owns @StateObjects
│   └── IOSApp.swift               # iOS @main
├── Sources/HermesNative/
│   ├── HermesNativeApp.swift      # Shared app helpers (notifications, perf, window)
│   ├── Models/                    # GatewayEvent, ChatMessage, Session, WikiGraph,
│   │   └── JSONRPC/               #   SavedGateway, … + JSON-RPC envelopes
│   ├── Services/                  # GatewayClient(+Wiki/+Feed), GatewayClientWrapper,
│   │                              #   KeychainStore, ChatHistoryStore, FileDownloadManager,
│   │                              #   SRS/Quiz stores, CronPoller, TTS, Notifications, …
│   ├── ViewModels/                # ChatViewModel, SessionListViewModel, Wiki*, Feed*, …
│   ├── Views/                     # ChatView, SettingsView + Wiki/, MissionControl/,
│   │                              #   Playback/, ThoughtGraph/, Quiz/, Learning/, Charts/, …
│   ├── Utilities/                 # Constants, Extensions (AnyCodable accessors),
│   │                              #   DocumentTextExtractor, PerfInstrumentation, DeepLink
│   └── Utils/                     # PlatformCompat, MacInputTextField, scroll introspection
├── Tests/
│   ├── HermesNativeTests/         # Unit tests (Session, Skill, Capabilities, …)
│   └── HermesNativeUITests/       # Smoke / offline / gateway-connection UI tests
└── docs/
    └── rpc-reference.md           # Full RPC method + event catalog
```

## Dependencies

Networking and security use **Apple frameworks only** — `URLSessionWebSocketTask`
(Foundation) for the WebSocket and `SecItem` (Security) for the Keychain; there is no
third-party networking or WS library. The third-party SPM packages are for UI and
on-device inference:

| Package | Purpose |
|---------|---------|
| lottie-spm | Avatar / celebration animations |
| Highlightr | Code-block syntax highlighting |
| beautiful-mermaid-swift | Mermaid diagram rendering |
| mlx-swift-lm | On-device LLM inference (reasoning summarization) |
| swift-huggingface / swift-transformers | Model + tokenizer support for MLX |

Plus system frameworks: SwiftUI, Combine, SceneKit, SpriteKit, AVFoundation, WebKit.

## Key Design Decisions

### Why URLSessionWebSocketTask over Starscream/NIO?
- Zero networking dependencies, Apple-maintained, built into Foundation
- Native backpressure and memory management
- Works with `URLSession` configuration (proxies, TLS, cookies — needed for CF Access)

### Why WebSocket over SSE `/v1/chat/completions`?
- WS gives session management (interrupt, approval flows, resume)
- WS gives rich tool-call events (start/complete with diffs and todos)
- WS gives slash-command and voice-mode events
- SSE is stateless per request — can't interrupt mid-turn without `/v1/runs` indirection

### Auth model
- API key, gateway URL, and the saved-gateways list are stored in the Keychain
  (`kSecClassGenericPassword`, service `com.hermes.native`)
- Key sent as `Authorization: Bearer <key>` on the WS upgrade
- CF Access cookie captured via web-view login, held in memory, sent per-host

### Concurrency
- Swift 6 strict concurrency: view models are `@MainActor`; inbound message parsing
  runs off-main (`Task.detached`) while preserving per-connection event ordering;
  on-device MLX inference runs on a utility queue to keep the main thread responsive.

## Gotchas

- **Build the generated project, not a stale `.xcodeproj`.** Run `make build`
  (xcodegen → xcodebuild) so newly-added files are registered.
- **Kill stale instances before relaunch.** A debugger-held instance survives
  `make run`'s pkill; `make kill` (or killing `debugserver`) clears it. A long-lived
  instance can also accumulate a SwiftUI layout loop — relaunch fresh when diagnosing
  a beachball.
- **`swift build` does not catch everything.** Some Swift 6 concurrency errors and
  platform-gated code only surface in the xcodebuild (SwiftPM vs. app target) — run
  the xcode build before claiming CI-clean.
