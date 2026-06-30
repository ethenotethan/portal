# Gateway RPC & Event Reference

The complete catalog of WebSocket JSON-RPC methods the HermesNative app calls, the
server events it handles, and the connection lifecycle. Generated from the
`GatewayClient` sources — keep it in sync when adding methods.

- **Outbound RPCs** are dispatched through `GatewayClient.call(_ method:params:)`.
- **Inbound events** arrive as `method: "event"` notifications and are decoded into the
  `GatewayEvent` enum (`Models/GatewayEvent.swift`).
- Source files: `Services/GatewayClient.swift`, `GatewayClient+Wiki.swift`,
  `GatewayClient+Feed.swift`, `Models/GatewayEvent.swift`.

## Transport & Wire Format

JSON-RPC 2.0 over a single WebSocket (`/v1/ws`). Requests carry an incrementing `id`;
responses echo it; events are id-less notifications.

```jsonc
// Request (client → server)
{"jsonrpc":"2.0","id":1,"method":"session.create","params":{"cols":120}}
// Response (server → client)
{"jsonrpc":"2.0","id":1,"result":{"session_id":"abc123","session_key":"20260501_112429_d91274"}}
// Event (server → client, no id)
{"jsonrpc":"2.0","method":"event","params":{"type":"message.delta","session_id":"abc123","payload":{"text":"Hi"}}}
// Error
{"jsonrpc":"2.0","id":1,"error":{"code":4001,"message":"session not found"}}
```

Responses are routed back to awaiting callers via `pendingRequests[id]` (an
`NSLock`-protected map of `CheckedContinuation`). Inbound parsing runs off the main
actor (`Task.detached`) while preserving per-connection ordering.

## Connection Lifecycle

| Step | Detail |
|------|--------|
| HTTP health probe | `HEAD <scheme>://<host>/health` (5s timeout) before the WS handshake |
| CF Access verify | If a `CF_Authorization` cookie is set: `GET /health` — 200 ok; 302/401/403 → clear cookie + fail |
| WS handshake | `Authorization: Bearer <key>` header (+ CF cookie); ping/pong every 15s |
| Auto-reconnect | Exponential backoff 1s → 2s → 4s → … → max 30s, up to 10 attempts |
| Session resume | On reconnect, resume via `lastSessionKey` (database-format session key) |
| Intentional close | `isIntentionalDisconnect = true` bypasses auto-reconnect |

**Session ID formats:** short hex `session_id` (current connection, used in most RPCs)
vs. database-format `session_key` (e.g. `20260501_112429_d91274`, used to resume).

## Outbound RPC Methods

### session.*

| Method | Params | Description |
|--------|--------|-------------|
| `session.create` | `cols` (int, default 120) | Create a session; returns `session_id` (hex) + `session_key` (db) |
| `session.list` | — | List sessions: `id`, `title`, `preview`, `started_at`, `message_count`, `source`, run state |
| `session.resume` | `session_id` (db key) | Resume a session; returns new hex `session_id` + `messages` history |
| `session.history` | `session_id` | Conversation history messages |
| `session.title` | `session_id` (hex) | Resolve title + `session_key` from a hex ID |
| `session.set_prompt` | `session_id`, `prompt` | Set an ephemeral system prompt (not persisted) |
| `session.attach_skills` | `session_id`, `skills` (`[String]`) | Activate skills for a session |
| `session.usage` | `session_id` | Token usage: `prompt_tokens`, `completion_tokens`, `total_tokens` |
| `session.timeline` | `session_id` | All session events for playback visualization |
| `session.prompt_breakdown` | `session_id` | Prompt assembly breakdown + token allocation |
| `session.interrupt` | `session_id` | Interrupt the current turn |
| `session.close` | `session_id` | Close / finalize a session |

### prompt.* / approval.*

| Method | Params | Description |
|--------|--------|-------------|
| `prompt.submit` | `session_id`, `text` | Submit a user message; triggers a turn (async) |
| `approval.respond` | `session_id`, `choice`, `all` (bool) | Respond to an approval request; `all` approves all pending |

### delegation.* / subagent.* / spawn_tree.*

| Method | Params | Description |
|--------|--------|-------------|
| `delegation.status` | — | Active subagent counts + depth/capacity limits |
| `subagent.interrupt` | `subagent_id`, `session_id?` | Interrupt a running subagent |
| `spawn_tree.list` | `session_id?`, `cross_session` (bool), `limit` | List spawn-tree snapshots |
| `spawn_tree.load` | `path` | Load a specific spawn-tree snapshot |

### skills.* / commands.* / slash.*

| Method | Params | Description |
|--------|--------|-------------|
| `skills.manage` (list) | `action:"list"` | Skills grouped by category |
| `skills.manage` (inspect) | `action:"inspect"`, `query` | Skill metadata |
| `skills.manage` (read) | `action:"read"`, `query` | Full `SKILL.md` content |
| `skills.manage` (write) | `action:"write"`, `query`, `content` | Overwrite `SKILL.md` |
| `skills.manage` (search) | `action:"search"`, `query` | Search skills; returns `results` |
| `skills.manage` (install) | `action:"install"`, `query` | Install a skill |
| `skills.manage` (uninstall) | `action:"uninstall"`, `query` | Uninstall; on code 4017, falls back to `slash.exec` |
| `skills.reload` | — | Reload skills; returns `added`/`removed`/`total` + `output` |
| `commands.catalog` | — | Slash-command catalog (`[name, description]` pairs) |
| `slash.exec` | `command`, `session_id` | Execute a slash command |

### activity.*

| Method | Params | Description |
|--------|--------|-------------|
| `activity.list` | `limit`, `include_read`, `include_dismissed` | Inbox items + `total` |
| `activity.mark_read` | `activity_id`, `read` (bool) | Mark read/unread |
| `activity.dismiss` | `activity_id` | Dismiss an item |
| `activity.artifacts.get` | `artifact_id` | Fetch artifact content |

### cron.*

| Method | Params | Description |
|--------|--------|-------------|
| `cron.manage` | `action:"list"` | Cron jobs: `job_id`, `name`, `schedule`, `next_run_at`, `last_run_at`, `last_status`, `enabled`, … |

### wiki.*

| Method | Params | Description |
|--------|--------|-------------|
| `wiki.list` | — | Available wikis (`name`, `path`) |
| `wiki.scan` | `wiki?` | Full graph: `pages` + `links` (source/target/type) |
| `wiki.page` | `path`, `wiki?` | Single page: `frontmatter` + `body` |
| `wiki.taxonomy` | `wiki?` | Hierarchical taxonomy `flat_paths` |
| `wiki.expand_links` | `slug`, `wiki?` | Expand integration links → `{type, status, title, url}` |
| `wiki.changesets` | `wiki?`, `page?`, `action?`, `trigger?`, `since?`, `until?`, `limit`, `offset` | Edit-history timeline (newest first) + `total` for pagination |

### feed.*

| Method | Params | Description |
|--------|--------|-------------|
| `feed.get` | `sources?`, `since?`, `limit`, `offset` | Articles + `total` + `has_more` |
| `feed.sources` | — | Source name → article count |

### config.* / image.* / capabilities

| Method | Params | Description |
|--------|--------|-------------|
| `config.set` | `key`, `value`, `session_id?` | Set a config value |
| `config.get` | `key` | Get config value(s) |
| `image.attach` | `path`, `session_id?` | Attach an image to a session |
| `gateway.capabilities` → `hermes.capabilities` → `hermes.version` | — | Capability probe, tried in order (fallback chain) |

## HTTP (non-WS) Endpoints

| Operation | Endpoint | Notes |
|-----------|----------|-------|
| Download file | `GET <gateway>/v1/files/...` | Bearer token + CF cookie; 120s timeout |
| Upload file | `POST <gateway>/v1/upload?filename=…&session_id=…` | multipart/form-data; returns `{path}` |
| Media URL resolve | client-side | `resolvedMediaURL` rewrites loopback hosts (localhost/127.0.0.1/::1) in `video_url`/`thumbnail_url`/`image_url` to the current gateway host |

## Inbound Events (`GatewayEvent`)

Events carry `type`, optional `session_id`, and a `payload`. `isLiveTurnEvent` marks
streaming-turn events; `isSessionScopedRequestEvent` marks blocking user-input requests.

### Connection / session
| Wire type | Enum case | Description |
|-----------|-----------|-------------|
| `gateway.ready` | `gatewayReady(skin)` | Server ready; includes theme skin |
| `session.info` | `sessionInfo(SessionInfo)` | model, reasoning effort, fast flag, tools, skills, cwd, version, usage, MCP servers |

### Chat streaming (live turn)
| Wire type | Enum case | Description |
|-----------|-----------|-------------|
| `message.start` | `messageStart` | Turn begins |
| `message.delta` | `messageDelta(text, rendered?)` | Incremental text |
| `message.complete` | `messageComplete(payload)` | `text`, `status`, optional `usage`/`reasoning`/`rendered`/`warning` |

### Tool calls (live turn)
| Wire type | Enum case | Description |
|-----------|-----------|-------------|
| `tool.start` | `toolStart(payload)` | `tool_id`, `name`, `context` |
| `tool.complete` | `toolComplete(payload)` | optional `summary`, `duration_seconds`, `inline_diff`, `todos` |
| `tool.progress` | `toolProgress(name, preview)` | In-progress preview |
| `tool.generating` | `toolGenerating(name)` | Model generating for a tool |

### Reasoning / thinking (live turn)
| Wire type | Enum case | Description |
|-----------|-----------|-------------|
| `reasoning.delta` | `reasoningDelta(text)` | Incremental reasoning |
| `reasoning.available` | `reasoningAvailable(text)` | Complete reasoning available |
| `thinking.delta` | `thinkingDelta(text)` | Extended-thinking stream |

### Subagent delegation
| Wire type | Enum case | Description |
|-----------|-----------|-------------|
| `subagent.spawn_requested` | `subagentSpawnRequested(payload)` | Spawn queued (goal, task idx, ids, depth, model) |
| `subagent.start` | `subagentStart(payload)` | Subagent started |
| `subagent.complete` | `subagentComplete(payload)` | Token counts, api_calls, cost_usd, files read/written |
| `subagent.tool` | `subagentTool(payload)` | Subagent tool call (tool_name, preview) |
| `subagent.progress` | `subagentProgress(text)` | Progress text |
| `subagent.thinking` | `subagentThinking(text)` | Thinking text |
| `background.complete` | `backgroundComplete(taskID, text)` | Background task finished |

### Blocking requests (session-scoped)
| Wire type | Enum case | Description |
|-----------|-----------|-------------|
| `approval.request` | `approvalRequest(payload)` | `command`, `session_key`, optional `tool_name`/`raw_args` |
| `clarify.request` | `clarifyRequest(question, choices)` | Agent needs clarification |
| `sudo.request` | `sudoRequest` | Privilege escalation request |
| `secret.request` | `secretRequest(prompt, envVar)` | Request for a secret/env var |

### Status / UI / voice / activity
| Wire type | Enum case | Description |
|-----------|-----------|-------------|
| `status.update` | `statusUpdate(kind, text)` | Generic status message |
| `error` | `error(message)` | Server error |
| `skin.changed` | `skinChanged(skin?)` | Theme changed |
| `voice.transcript` | `voiceTranscript(text, noSpeechLimit)` | Voice transcription |
| `voice.status` | `voiceStatus(state)` | Voice state change |
| `activity.created` | `activityCreated(ActivityItem)` | New inbox item |
| `activity.updated` / `.read` / `.dismissed` | `activityUpdated(ActivityItem)` | Inbox item modified |
| `review.summary` | `reviewSummary(text)` | Summary / review content |

## Errors

`GatewayError`: `.notConnected`, `.disconnected`, `.invalidResponse(String)`,
`.rpcError(JSONRPCError{code, message})`. Every `call()` checks `response.error` first
and throws `.rpcError`; a missing `result` throws `.invalidResponse`. Parsing uses
`AnyCodable` accessors (`stringValue`/`intValue`/`arrayValue`/`dictionaryValue`/…) with
nil-coalescing defaults — no force unwraps.
