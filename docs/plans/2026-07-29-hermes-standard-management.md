# Hermes Standard Management — Lightweight Spec

**Status:** implementation
**Owner:** Portal
**Roadmap artifact:** `portal-hermes-standard`
**Upstream contract audited at:** `NousResearch/hermes-agent@015718066ab8e9499c3caea3cda9f7ea469036fc`

## Product contract

Portal names the existing managed WebSocket fork **Hermes Gateway** and the upstream/default dashboard integration **Hermes Standard**.

- **Hermes Gateway** keeps the full Portal surface and existing `/v1/ws` JSON-RPC behavior.
- **Hermes Standard** is a management-only HTTP + SSE harness. Its navigation surface is exactly **Sessions, Cron, Notifications, Skills, Settings**.
- Unsupported Gateway-only features are hidden, not rendered disabled or allowed to fail at runtime.
- Existing saved `kind: "hermes"` entries decode as Hermes Gateway. The new persisted discriminator is `hermesStandard`.

## Transport and trust boundary

Hermes Standard consumes the upstream dashboard HTTP API. Sensitive routes require either:

1. loopback dashboard session authentication via `X-Hermes-Session-Token`, with legacy `Authorization: Bearer <token>` compatibility; or
2. an authenticated dashboard session on a non-loopback deployment.

Portal V1 accepts a dashboard session token and sends it only to the configured origin. Redirects that change origin are rejected. Secrets stay in the existing Keychain-backed saved-gateway record and are never logged or embedded in URLs.

The audited upstream commit currently exposes REST management routes and WebSocket event routes, but **does not expose an SSE notification stream**. Portal therefore implements notifications as a capability-gated surface: it consumes an SSE endpoint when advertised and otherwise shows an explicit server-version requirement rather than synthesizing or fabricating activity.

## Upstream API slice

| Surface | HTTP contract | V1 behavior |
|---|---|---|
| Status | `GET /api/status` | capability/version probe |
| Sessions | `GET /api/sessions`, `GET /api/sessions/{id}` | read-only list/detail |
| Cron | `/api/cron/jobs` plus pause/resume/trigger/delete | list and safe job actions |
| Skills | `GET /api/skills`, content/toggle routes | list, inspect, edit/toggle where permitted |
| Settings | `GET /api/config`, defaults/schema | read and schema-driven editing |
| Notifications | advertised SSE endpoint | live only when positively advertised |

## Two implementation bets

### Bet A — honest backend boundary

Add an explicit backend-kind/capability model and focus semantics so Hermes Standard is a first-class management target, not an `AgentBackend` pretending it can chat. Add a small authenticated HTTP client behind protocols consumed by management ViewModels.

**Exit:** old saved gateways remain compatible; selecting Standard cannot replace the app-level Gateway WebSocket; only the five permitted surfaces are visible.

### Bet B — management adapters

Route sessions, cron, skills, settings, and advertised notification SSE through the Standard client while preserving existing Gateway RPC behavior.

**Exit:** fixture-backed request/response tests pass for each route, SSE framing/reconnect is tested, and unsupported notification streaming has an honest UI state.

## Current checkpoint

- **Transport complete:** nine focused client tests cover typed decoding, same-origin token auth, cross-origin redirect rejection, cancellation, structured errors, secret redaction, and the honest unavailable-notifications state.
- **Sessions complete:** selecting a Hermes Standard entry and opening Sessions now loads a separate read-only management view. It supports refresh, search, live/ended filtering, explicit loading/error states, and never mutates or replaces the app-level Hermes Gateway chat list.
- **Fresh qualification:** 596 SwiftPM tests pass; macOS and iOS Simulator builds succeed; lint-baseline growth is zero; `git diff --check` passes.
- **Still pending:** Cron, Skills, bounded Settings editing, full navigation capability wiring, and Notifications until upstream advertises a compatible SSE endpoint.

## Acceptance gates

1. `BackendKind` migration and labels are covered by tests.
2. Capability-based navigation contains exactly the five Standard sections.
3. Every HTTP request is same-origin, authenticated, bounded by timeout, and decodes an explicit schema.
4. Existing Hermes Gateway and Centaur tests remain green.
5. `make check` passes without baseline growth.
6. No push occurs without explicit user approval.
