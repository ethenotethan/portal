# Hermes Native — macOS Swift Client

## Architecture

```
┌─────────────────────────────────────┐
│         HermesNative App            │
│  (Swift + SwiftUI, no Electron/Node) │
├─────────────────────────────────────┤
│  Views (SwiftUI)                     │
│  ├─ ChatView                         │
│  ├─ SessionSidebar                   │
│  ├─ ToolCallPanel                    │
│  ├─ ApprovalSheet                    │
│  └─ SettingsView                     │
├─────────────────────────────────────┤
│  ViewModels                          │
│  ├─ ChatViewModel                    │
│  ├─ SessionListViewModel             │
│  └─ SettingsViewModel                │
├─────────────────────────────────────┤
│  Services                            │
│  ├─ GatewayClient (WS JSON-RPC)      │
│  ├─ KeychainStore                    │
│  └─ EventDispatcher                  │
├─────────────────────────────────────┤
│  Models                              │
│  ├─ JSON-RPC types                   │
│  ├─ Gateway event types              │
│  ├─ Session model                    │
│  └─ Config model                     │
└──────────┬──────────────────────────┘
           │ wss://gateway.example.com/api/ws
           ▼
┌─────────────────────────────────────┐
│  Hermes Gateway (Python aiohttp)     │
│  API Server :8642                    │
│  Dashboard :9119                     │
└─────────────────────────────────────┘
```

## Gateway Auth Problem & Solution

### Problem
The WS `/api/ws` endpoint on the dashboard (port 9119) is gated by:
1. `_SESSION_TOKEN` — ephemeral token injected into SPA HTML at server start
2. `_LOOPBACK_HOSTS` — only 127.0.0.1/::1/localhost
3. `_DASHBOARD_EMBEDDED_CHAT_ENABLED` flag

Remote native clients can't authenticate or connect.

The API server (port 8642) has no WS endpoint — only REST/SSE.

### Solution
Add a WS endpoint to the **API server** (aiohttp, port 8642) that:
- Reuses `tui_gateway.ws.handle_ws` logic (same JSON-RPC dispatch)
- Authenticates via Bearer token (`_check_auth` already exists)
- No loopback restriction (API server already serves remote clients)
- No session token dependency

**Gateway change required**: Add WebSocket route to `APIServerAdapter` in `api_server.py`:
```python
self._app.router.add_get("/v1/ws", self._handle_ws)
```

The handler accepts the WS upgrade, validates Bearer token via existing `_check_auth`,
then delegates to `tui_gateway.ws.handle_ws` (same as dashboard).

Swift client connects to `wss://gateway:8642/v1/ws` with `Authorization: Bearer <key>`.

## JSON-RPC Protocol Reference

### Connection Lifecycle
```
1. Client opens WS to /v1/ws (or /api/ws?token=...)
2. Server sends: {"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"skin":"..."}}}
3. Client calls: session.create → gets session_id
4. Client calls: prompt.submit → streaming events begin
5. Server streams: message.start, message.delta, message.complete, tool.start, tool.complete, etc.
6. Client may call: session.interrupt, approval.respond, clarify.respond
7. Client calls: session.close
8. Client closes WS
```

### Core Methods (v1 scope)

| Method | Params | Returns | Description |
|--------|--------|---------|-------------|
| `session.create` | `cols?` | `{session_id}` | Create new agent session |
| `session.list` | — | `{sessions: [...]}` | List sessions |
| `session.resume` | `session_key` | `{session_id}` | Resume existing session |
| `session.close` | `session_id` | `{ok}` | Close and finalize session |
| `session.interrupt` | `session_id` | `{ok}` | Interrupt running turn |
| `session.steer` | `session_id, text` | `{ok}` | Inject mid-turn steering |
| `session.title` | `session_id, title` | `{ok}` | Set session title |
| `session.history` | `session_id` | `{messages}` | Get conversation history |
| `prompt.submit` | `session_id, text` | `{ok}` (async) | Submit user message |
| `approval.respond` | `session_id, choice, all?` | `{resolved}` | Approve/deny dangerous command |
| `clarify.respond` | `answer` | `{ok}` | Respond to clarify question |
| `config.set` | `key, value, session_id?` | `{result}` | Change config (model, etc.) |
| `config.get` | — | `{...}` | Get current config |
| `tools.list` | `session_id` | `{tools}` | List available tools |
| `toolsets.list` | — | `{toolsets}` | List toolsets |
| `model.options` | — | `{models}` | List available models |
| `commands.catalog` | — | `{commands}` | List slash commands |

### Server Event Types

| Event | Payload | When |
|-------|---------|------|
| `gateway.ready` | `{skin}` | On WS connect |
| `session.info` | `{model, tools, skills, usage, version, ...}` | After session.create, config changes |
| `message.start` | — | Turn begins |
| `message.delta` | `{text, rendered?}` | Streaming token |
| `message.complete` | `{text, usage, status, rendered?, reasoning?}` | Turn ends |
| `tool.start` | `{tool_id, name, context}` | Tool invocation begins |
| `tool.complete` | `{tool_id, name, summary?, duration_s?, inline_diff?, todos?}` | Tool finishes |
| `tool.progress` | `{name, preview}` | Tool progress update |
| `tool.generating` | `{name}` | Model generating for tool |
| `reasoning.delta` | `{text}` | Reasoning stream |
| `reasoning.available` | `{text}` | Reasoning preview |
| `thinking.delta` | `{text}` | Extended thinking stream |
| `approval.request` | `{command, ...}` | Dangerous command needs approval |
| `error` | `{message}` | Error occurred |
| `skin.changed` | `{...}` | Skin/theme changed |
| `status.update` | `{kind, text}` | Status bar update |
| `voice.transcript` | `{text}` | Voice transcription |
| `voice.status` | `{state}` | Voice status change |

### Wire Format

All messages are newline-delimited JSON-RPC:

**Request** (client → server):
```json
{"jsonrpc": "2.0", "id": 1, "method": "session.create", "params": {"cols": 120}}
```

**Response** (server → client):
```json
{"jsonrpc": "2.0", "id": 1, "result": {"session_id": "a1b2c3d4"}}
```

**Event** (server → client, no id):
```json
{"jsonrpc": "2.0", "method": "event", "params": {"type": "message.delta", "session_id": "a1b2c3d4", "payload": {"text": "Hello"}}}
```

**Error**:
```json
{"jsonrpc": "2.0", "id": 1, "error": {"code": 4001, "message": "session not found"}}
```

## Project Structure

```
HermesNative/
├── HermesNative.xcodeproj
├── HermesNative/
│   ├── HermesNativeApp.swift          # App entry point
│   ├── Info.plist
│   ├── Assets.xcassets
│   │
│   ├── Models/
│   │   ├── JSONRPC/
│   │   │   ├── JSONRPCRequest.swift    # Outbound request envelope
│   │   │   ├── JSONRPCResponse.swift   # Inbound response envelope
│   │   │   └── JSONRPCEvent.swift      # Inbound event envelope
│   │   ├── GatewayEvent.swift          # Enum of all event types + payloads
│   │   ├── Session.swift               # Session model
│   │   ├── ChatMessage.swift            # Chat message (user/assistant/tool)
│   │   ├── ToolCall.swift               # Tool invocation model
│   │   ├── Approval.swift              # Approval request model
│   │   └── GatewayConfig.swift         # Config/model info
│   │
│   ├── Services/
│   │   ├── GatewayClient.swift          # WS connection + JSON-RPC dispatch
│   │   ├── KeychainStore.swift         # macOS Keychain wrapper
│   │   └── EventDispatcher.swift        # Routes events to subscribers
│   │
│   ├── ViewModels/
│   │   ├── ChatViewModel.swift          # Chat state + prompt.submit
│   │   ├── SessionListViewModel.swift   # Session list + create/resume
│   │   └── SettingsViewModel.swift      # Connection config
│   │
│   ├── Views/
│   │   ├── ChatView.swift               # Main chat interface
│   │   ├── MessageBubbleView.swift      # User/assistant message rendering
│   │   ├── StreamingTextView.swift      # Live token streaming
│   │   ├── ToolCallView.swift           # Tool invocation card
│   │   ├── ApprovalSheet.swift          # Danger command approval
│   │   ├── SessionSidebar.swift         # Session list sidebar
│   │   └── SettingsView.swift           # API key + gateway URL
│   │
│   └── Utilities/
│       ├── Constants.swift              # App-wide constants
│       └── Extensions.swift            # Common extensions
│
└── HermesNativeTests/
    ├── GatewayClientTests.swift
    ├── KeychainStoreTests.swift
    └── JSONRPCTests.swift
```

## Dependencies (SPM)

- **Network.framework** (Apple) — WebSocket tasks via URLSessionWebSocketTask (no third-party WS library needed)
- **Security.framework** (Apple) — Keychain access via SecItem
- **SwiftUI** (Apple) — UI framework
- **Combine** (Apple) — Reactive event stream from WS

Zero third-party dependencies. URLSessionWebSocketTask handles WS natively on macOS 12+.

## Implementation Order

1. **Gateway change** — Add WS endpoint to api_server.py (unblocks remote client)
2. **Models** — JSON-RPC types, GatewayEvent enum, Session/ChatMessage
3. **Services** — GatewayClient (WS + JSON-RPC), KeychainStore, EventDispatcher
4. **ViewModels** — ChatViewModel (the core), SessionListViewModel
5. **Views** — ChatView with streaming, SettingsView
6. **Approval flow** — approval.respond + UI sheet
7. **Tool calls** — tool.start/complete rendering
8. **Session management** — sidebar, list, resume, close
9. **Polish** — error handling, reconnection, voice TTS

## Key Design Decisions

### Why URLSessionWebSocketTask over Starscream/NIO?
- Zero dependencies, Apple-maintained, built into Foundation
- Native backpressure and memory management
- Works with URLSession configuration (proxies, TLS, cookies)
- macOS 12+ API (current target)

### Why not SSE /v1/chat/completions for v1?
- WS gives session management (interrupt, steer, approval flows)
- WS gives rich tool-call events (start/complete with diffs)
- WS gives slash command support
- WS gives voice mode events
- SSE is stateless per request — can't interrupt mid-turn without /v1/runs indirection

### Auth model
- API key stored in macOS Keychain (kSecClassGenericPassword, kSecAttrService: "com.hermes.native")
- Key sent as `Authorization: Bearer <key>` header on WS upgrade (aiohttp supports headers on WS)
- Fallback: `?key=<api_key>` query param for gateways that don't support WS headers
