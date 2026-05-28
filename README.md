# Hermes Native

Native macOS + iOS client for the Hermes Agent gateway — built with Swift + SwiftUI.

Connects directly to a Hermes Gateway via WebSocket JSON-RPC (`/v1/ws`), providing the full Hermes experience from a native app with no local server, CLI, or Node.js required.

## Features

### Core
- **WebSocket JSON-RPC** — 50+ gateway methods: sessions, prompts, approvals, config, skills, cron, delegation
- **Streaming chat** — real-time `message.delta`, `tool.start`, `tool.complete`, `reasoning.delta`, and `thinking.delta` events with 500ms coalesced flush for smooth rendering
- **Chat skins** — pluggable renderers: TUI (terminal-style), Dark Manga, with custom skin API (`ChatSkinProviding`)
- **Markdown rendering** — headings, lists, code blocks with syntax highlighting (Highlightr), blockquotes, inline formatting, tables, Mermaid diagrams
- **Markdown skills editor** — full-featured editor with live preview and block type controls

### Agent Management
- **Spawn tree / Mission Control** — live subagent/delegation hierarchy visualization per session with recursive tree nodes
- **Session explorer** — drill into any session's agents, full chat history, run timeline, and token usage
- **Sessions dashboard** — global session overview with filtering by status (live/ended) and source (Native/Telegram/Discord/CLI/Cron/Web)
- **Session observer** — watch running sessions with live event streaming
- **Cron dashboard + run history** — view, pause, resume, remove scheduled jobs with execution timeline and charts
- **Activity inbox** — notifications for tool approvals, clarifications, response completions, and cron triggers

### Skills & Knowledge
- **Skills browser** — discover and manage agent skills with metadata, markdown editing, and graph visualization
- **Wiki graph** — explore multi-session knowledge graphs with interactive nodes and path picking
- **3D skill graph** — SceneKit-powered visualization of skill relationships

### AI & Media
- **Persona system** — load personas from gateway + local JSON + built-in presets with Lottie/SceneKit avatars
- **3D avatar** — SceneKit + SpriteKit character with state-driven expressions (idle, speaking, thinking, tool use, error)
- **TTS / voice** — text-to-speech integration via AVSpeechSynthesizer for voice transcript events
- **Celebrations** — confetti effects on milestone completions
- **GitHub link cards** — inline preview cards for GitHub URLs in chat
- **File attachments** — image/file upload with thumbnail previews and remote download manager

### Infrastructure
- **Cloudflare Access** — built-in CF Access auth flow for enterprise gateways
- **macOS Keychain** — API key + gateway URL stored securely via Security framework
- **macOS notifications** — native push notifications for approvals, clarifications, and response completions
- **Auto-reconnect** — WebSocket keepalive with ping/pong and exponential backoff (1s → 2s → 4s → max 30s)
- **Session history** — local persistence of messages per session in `Application Support/hermes-native/sessions/`
- **Run history** — per-session execution timeline with token usage charts and duration tracking
- **Offline capabilities** — cached personas, skills, and session history for resilient startup
- **Cross-platform** — macOS 14+ and iOS 17+ from a single SwiftUI codebase
- **Swift 6 strict concurrency** — `@MainActor`, `Sendable`, no data races, no `@Sendable` gymnastics

## Requirements

- macOS 14 (Sonoma) / iOS 17 or later
- Xcode 16+ / Swift 6.1+
- A running Hermes Gateway with API server enabled (`api_server` platform)

## Build

```bash
git clone https://github.com/researchoors/hermes-native.git
cd hermes-native
swift build
```

## Run

Open `Package.swift` in Xcode, select your target (macOS or iOS), and hit ▶.

SwiftPM builds the library target. App entry points live in `App/MacApp.swift` and `App/IOSApp.swift`.

## Configuration

On first launch, enter your gateway URL and API key:

| Field | Example |
|-------|---------|
| Gateway URL | `wss://your-gateway.example.com/v1/ws` |
| API Key | Bearer token from `API_SERVER_KEY` |

The app converts `https://` → `wss://` and appends `/v1/ws` automatically. The production gateway URL can be overridden via the `HERMES_GATEWAY_URL` environment variable.

## Architecture

```
App Entry Points
├── MacApp.swift              # macOS NSApplication lifecycle + menu bar
└── IOSApp.swift              # iOS App lifecycle + scene phases

HermesNativeApp.swift         # Shared root view — environment wiring
  ├── ContentView             # Tab/split navigation, sheet management
  │   ├── SessionListView     # Sidebar session list (owned/archived/cron/other)
  │   ├── ChatView            # Main chat interface (ScrollView + LazyVStack)
  │   ├── SkillsView          # Skills browser + graph
  │   ├── SettingsView        # Gateway config, personas, capabilities
  │   ├── OnboardingView      # First-launch setup
  │   ├── CFAuthView          # Cloudflare Access auth
  │   └── MissionControl/     # Spawn tree + session drill-in
  │       ├── SessionExplorerView  # Agents • Chat • History • Usage tabs
  │       ├── SessionsDashboard    # Global session overview + filter
  │       ├── TreeNodeView        # Recursive tree rendering
  │       ├── SessionRunTimelineView  # Duration + token charts
  │       └── SessionObserverView # Live event stream
  ├── ViewModels/
  │   ├── ChatViewModel       # Message state, streaming, tool calls, delta batching
  │   ├── SessionListViewModel # Session CRUD, ID mapping, bind/unbind
  │   ├── SpawnTreeStore      # Subagent event accumulation into live trees
  │   ├── SkillsViewModel     # Skill discovery + management
  │   ├── CronListViewModel   # Cron job management via gateway RPCs
  │   ├── WikiGraphViewModel  # Multi-session knowledge graph
  │   ├── ActivityInboxViewModel # Tool approvals, clarifications, notifications
  │   ├── SettingsViewModel   # URL, API key, CF auth
  │   ├── PersonaManager      # Persona loading + persistence
  │   ├── CelebrationManager  # Confetti trigger logic
  │   └── HermesCapabilitiesStore # Gateway feature flags
  └── Services/
      ├── GatewayClient       # WebSocket JSON-RPC, events, reconnection
      ├── GatewayClientWrapper # Observable connection lifecycle
      ├── GatewayClient+Wiki   # Wiki-specific RPCs
      ├── SkillStore          # Skill CRUD via gateway + local cache
      ├── SkillCache          # In-memory + disk skill metadata cache
      ├── ChatHistoryStore    # Message persistence to disk
      ├── FileDownloadManager # Remote attachment download + caching
      ├── TTSService          # AVSpeechSynthesizer voice integration
      ├── KeychainStore       # macOS/iOS Keychain API key storage
      └── NotificationService # macOS push notifications
```

### Models

| Model | Description |
|-------|-------------|
| `GatewayEvent` | Central event enum — all WebSocket events with typed payloads (~30 event types) |
| `ChatMessage` | Messages, tool calls, file attachments, reasoning traces, usage info |
| `Session` | Session metadata with status, run state, live detection, source tracking |
| `CronJob` | Scheduled job model with status management |
| `CronRunHistory` | Per-job execution records with duration, status, read/unread tracking |
| `SessionRunEvent` | Per-session run timing and token usage for charts |
| `Persona` | Persona identity with accessories and theming |
| `SpawnNode` | Recursive tree node for subagent/delegation hierarchy (`ObservableObject`) |
| `Skill` / `SkillModels` | Skill metadata, parameter schemas, dependency graph |
| `WikiGraph` | Knowledge graph nodes, edges, and path structures |
| `ActivityItem` | Inbox item for approvals, clarifications, notifications |
| `MediaAttachment` | User-uploaded image/file metadata |
| `SessionFolder` | Lightweight session organization labels |
| `HermesCapabilities` | Gateway feature flags and capability detection |
| `JSONRPCRequest` / `JSONRPCResponse` | JSON-RPC 2.0 framing with `AnyCodable` type-erased params |

### Services

| Service | Description |
|---------|-------------|
| `GatewayClient` | Core networking — WebSocket JSON-RPC, auto-reconnect, ping/pong keepalive, ~40 RPC methods |
| `GatewayClientWrapper` | Observable lifecycle wrapper — manages connection using `SettingsViewModel` |
| `SkillStore` | Skill CRUD via gateway RPCs with local persistence |
| `SkillCache` | In-memory + disk cache for skill metadata, dependency graphs |
| `ChatHistoryStore` | Persists `[ChatMessage]` per session to disk |
| `FileDownloadManager` | Downloads remote file attachments with progress and caching |
| `TTSService` | Text-to-speech using `AVSpeechSynthesizer` for voice transcript events |
| `KeychainStore` | macOS/iOS Keychain CRUD for API key and gateway URL |
| `NotificationService` | macOS push notifications for tool approvals, clarifications, completions |

## Wire Protocol

Same as the Hermes gateway — newline-delimited JSON-RPC 2.0 over WebSocket:

```jsonc
→ {"jsonrpc":"2.0","id":1,"method":"session.create","params":{"cols":120}}
← {"jsonrpc":"2.0","id":1,"result":{"session_id":"abc123"}}

← {"jsonrpc":"2.0","method":"message.delta","params":{"text":"Hello"}}
← {"jsonrpc":"2.0","method":"tool.start","params":{"tool":"terminal","input":"ls"}}
```

## Testing

```bash
# Unit tests
swift test --disable-sandbox

# Lint
swiftlint lint --strict
```

### CI

5 GitHub Actions workflows:
| Workflow | Purpose |
|----------|---------|
| `lint.yml` | SwiftLint + build with warnings-as-errors |
| `build.yml` | macOS + iOS Simulator builds + offline smoke test |
| `swift-tests.yml` | `swift test --disable-sandbox` |
| `ios-simulator-tests.yml` | iOS simulator test suite |
| `testflight.yml` | TestFlight deployment pipeline |

## Dependencies

| Package | Purpose |
|---------|---------|
| [lottie-spm](https://github.com/airbnb/lottie-spm) | Lottie animations for avatars and celebrations |
| [Highlightr](https://github.com/raspu/Highlightr) | Syntax highlighting in code blocks |
| [beautiful-mermaid-swift](https://github.com/lukilabs/beautiful-mermaid-swift) | Mermaid diagram rendering |

Plus system frameworks: SceneKit, SpriteKit.

## License

MIT