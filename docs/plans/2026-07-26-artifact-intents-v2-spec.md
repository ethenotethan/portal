# Artifact Intents V2 — plugins, ledger, agent dispatch

Status: **proposed** · 2026-07-26
Builds on: issue #242 · hermes-native #245 · hermes-agent #31 (both open)

## Context

V1 (#245 native, #31 gateway) shipped the typed-intent contract: an artifact
declares a button by `binding_id`; the gateway resolves the registered handler
from the pinned revision; destructive handlers require a server-issued
challenge confirmed through native UI. Two built-in handlers exist
(`artifact.entity.tombstone`, `artifact.refresh`).

This spec covers what V1 deliberately deferred, in the order it should be
built, plus **two flaws found in the open V1 PRs** that must be fixed before
merge. It exists so the implementation runs have a fixed contract — each
numbered section below is one PR-sized unit with acceptance criteria.

## The tier model (design frame for everything below)

| Tier | Mechanism | Latency/cost | When |
|------|-----------|-------------|------|
| 0 | Local content mutation (`choice`/`toggle`/`delete`) | instant, free | field edits, tombstones the client can do alone |
| 1 | Registered synchronous code (`artifact.entity.tombstone`, `artifact.refresh`, plugins e.g. `linear.issue.delete`) | ms, free | deterministic operations whose code never changes |
| 2 | `agent.prompt` — headless agent run from a declaration-supplied prompt | seconds–minutes, tokens | work needing judgment; behavior depends on the data |

Rule of thumb enforced in review: **if the code could be written in advance,
it's Tier 1.** An LLM loop in front of a fixed GraphQL mutation adds latency,
cost, and non-determinism for zero benefit. Tier 2 is the escape hatch, not
the default.

---

## 0. Fixes to V1 before merge (patch hermes-agent #31)

### 0.1 Trusted confirmation prompt — CONFIRMED VIOLATION

`_build_confirmation_prompt` composes the dialog from the declaration `label`
and artifact `title` — both artifact-authored. Attack: an artifact labels a
destructive binding "Refresh"; the user confirms a dialog that says
"Refresh 'ENG-101'?" while the resolved handler deletes the ticket. This
violates the #242 requirement that confirmation text come from trusted
gateway data.

**Fix:** the prompt MUST lead with the server-resolved intent name:

> **linear.issue.delete** — ENG-101 in "Linear Issues"

The artifact-authored label may appear only as secondary text, visually
attributed as the artifact's own description. Optionally (V2.1+): handlers
may implement `describe(entity_ref) -> str` to fetch canonical target detail
(e.g. the real issue title from Linear) for the dialog body — trusted because
the *handler* fetched it.

**Acceptance:** a declaration with `label: "Refresh"` bound to
`artifact.entity.tombstone` produces a dialog whose first line names
`artifact.entity.tombstone`. Test asserts the intent name is present and
leads.

### 0.2 Entity-ref resolution rule — codify the accident

`entity_ref` is client-supplied. The V1 tombstone handler happens to be safe
because it looks the entity up in the pinned artifact content and fails when
absent — but that is a property of one handler, not an enforced rule. A
plugin author who passes `entity_ref` straight into an external API call
reintroduces the forged-target hole.

**Rule (document in `artifact_actions.py` module docstring + plugin docs):**
a handler MUST treat `entity_ref` as a lookup key into the pinned artifact
content, and MUST extract external identifiers (Linear issue ID, URL, etc.)
from the *stored entity fields*, never from the client-supplied string. If
the lookup fails, return `failed` — never proceed with the raw ref. Blast
radius is then bounded by what the artifact already declares.

**Acceptance:** docstring rule present; built-in handlers conform; the
plugin-loader docs (§1) repeat the rule with a wrong-vs-right example.

---

## 1. Plugin action handlers (hermes-agent)

**Problem.** Tier-1 handlers currently require editing `artifact_actions.py`
in the core repo. Per-deployment actions (the user's real
`linear.issue.delete`) need a registration point that doesn't fork core.

**Design.**

- Plugins live in `~/.hermes/plugins/actions/*.py`. Each file runs at load
  and calls `register_handler("name", fn)` — same registry as built-ins.
- **Authorship/activation split (the security core):** the plugins directory
  MUST NOT be agent-writable. The loader resolves the real path and refuses
  to load (hard error, not warning) if it sits inside any agent workspace
  root. Given that, the *reload trigger* is safe to expose to everyone —
  agent tool, CLI, RPC — because triggering activation is harmless when only
  the human can author what activates. Lever public, gun-loading private.
- **Reload is explicit, never watched.** Surfaces: `actions.reload` RPC; a
  `hermes actions reload` CLI subcommand; an agent tool wrapping the RPC
  (so "reload my actions" works in chat). No filesystem watching — silent
  auto-reload converts the agent's ordinary file-write tools into a
  gateway code-injection path if the directory check is ever misconfigured;
  the convenience delta is seconds, the risk delta is total.
- **Staged swap:** reload executes all plugin files against a staging
  registry; any file failing to parse/execute aborts the whole swap, leaving
  last-good handlers live, and returns the traceback. In-flight invocations
  finish on the old code; the swap affects the next invoke.
- **Registry diff logged** on every reload: name, added/changed/removed,
  content hash before/after. Pairs with the invocation ledger (§2) to answer
  "what code ran when I clicked that button."

**Reference plugin** shipped in docs (not in core): `linear.issue.delete` —
resolves the row from the pinned artifact per rule 0.2, extracts the issue
identifier from the stored row, calls the Linear GraphQL API, returns
`succeeded`/`failed`. Destructive: declared with
`presentation.role: destructive`, so V1's challenge flow applies unchanged.

**Acceptance.**
- Plugin registering a handler is invocable end-to-end after
  `hermes actions reload`; a syntax error in one plugin file leaves prior
  handlers live and reports the error.
- Loader hard-fails when the plugins dir is under an agent workspace root.
- Reload emits a registry diff with hashes.
- Native needs zero changes.

## 2. Invocation ledger (hermes-agent, small native follow-up)

**Problem — three at once.**
(a) `_idempotency_cache` is in-memory: a retry straddling a gateway restart
**re-executes a destructive action**. Correctness bug, not polish.
(b) No durable answer to "what did I click last Tuesday and did it land?"
(c) Native status badges (✓/⚠) are in-memory; app restart loses them while
the effects persist.

**Design.** Append-only JSONL at `~/.hermes/artifacts/invocations.jsonl`
(global, not per-artifact — one grep-able audit stream; artifact ID is a
field). One line per invoke/confirm transition:

```json
{"ts": "...", "artifact_id": "linear-issues", "rev": 22,
 "binding_id": "delete-linear-ticket", "entity_ref": "eng-101",
 "intent": "linear.issue.delete", "idempotency_key": "<uuid>",
 "phase": "invoke|confirm", "outcome": "succeeded|failed|conflict|needs_confirmation|running",
 "reason": null, "duration_ms": 143, "actor": "app:abc123"}
```

- **Durable idempotency:** invoke consults the ledger (tail-indexed on load)
  before the in-memory cache; a key with a terminal outcome returns that
  outcome. Survives restarts. The in-memory dict remains as the fast path.
- **`artifact.action.log` RPC:** query by artifact ID (and optionally
  binding/entity), newest first, capped. Native uses it to re-hydrate badge
  state on artifact-pane open; it also gives the user a per-artifact action
  history view later without new server work.
- Rotation: cap file at N MB, roll to `.1` — same simplicity class as
  MAX_REVISIONS.

**Acceptance.**
- Kill the gateway between invoke and retry with the same idempotency key →
  handler executes exactly once (test simulates by clearing the in-memory
  cache and re-reading the ledger).
- Ledger line exists for every terminal outcome including failures.
- Native shows the prior outcome for a slot after app restart (follow-up PR,
  reads `artifact.action.log`).

## 3. `agent.prompt` — Tier 2 dispatch (hermes-agent + small native change)

**Held until §§0–2 are merged and the sync tiers have been used on at least
one real artifact** — the #242 validation criterion applies to this
extension doubly, since it's the expensive tier.

**Design.**

- One registered handler, `agent.prompt`. The declaration carries data only:

```json
{"type": "intent", "id": "investigate", "label": "Investigate",
 "intent": "agent.prompt", "presentation": {"role": "normal"},
 "prompt": "Research {entity.name} and update this row's notes field.",
 "model": "claude-haiku-4-5", "effort": "low"}
```

- Template variables resolve **server-side from the pinned entity row**
  (rule 0.2 again): `{entity.<field>}`, `{artifact.id}`, `{artifact.title}`.
- Execution reuses the cron headless-run path — no new run machinery, no
  queue, no cancellation (V1 non-goals stay non-goals).
- **Server-side policy, gateway config:** model allowlist (declaration
  requests, server clamps — an artifact cannot demand an Opus-class run),
  per-artifact rate limit (N runs/hour), max concurrent intent-spawned runs.
  Same shape as confirmation policy: the declaration requests a capability,
  the server decides.
- **Async lifecycle:** invoke returns `running` (a NEW outcome), with the
  run ID. The ledger records `running`; when the run completes, the gateway
  appends the terminal outcome and emits `artifact.action.changed`
  (mirroring `artifact.changed`) so native flips the badge without polling.
  Native adds the `running` state to `IntentInvocationState` — spinner with
  a "run started" affordance, NOT a ✓. A ✓ at run-start would be a false
  landing confirmation, violating the never-optimistic rule.
- Destructive `agent.prompt` declarations still require the V1 challenge
  BEFORE the run spawns.

**Acceptance.**
- Invoke returns `running` immediately; terminal outcome lands via event +
  ledger when the run finishes.
- A declaration requesting a model outside the allowlist runs on the clamped
  model and the ledger records the clamp.
- Rate-limited invocations return `failed` with a clear reason, not silence.
- Native shows running → terminal transition without app interaction.

---

## Build order & dependencies

```
0 (patch #31, pre-merge)  →  merge #31 + #245
1 (plugin loader)         →  user's real linear.issue.delete becomes possible
2 (invocation ledger)     →  fixes restart idempotency; native badge re-hydration follow-up
3 (agent.prompt)          →  only after 1–2 used in anger; needs `running` state native-side
```

Each section is one PR. 0 is a patch to the open #31. 1 and 2 are
independent of each other (parallelizable). 3 depends on 2 (ledger records
`running`) and on the validation gate.

## Explicit non-goals (unchanged from #242, restated so they don't creep)

- HTML-to-native command bridges of any kind; artifact HTML never gains a
  message handler or credentials.
- Sessions registering executable handlers. Sessions author *declarations*
  (data, including Tier-2 prompts); only filesystem-authored plugins and
  core code register handlers.
- Durable queues, cancellation, exactly-once distributed guarantees.
- Auto-reload / file-watching of the plugins directory.
- A plugin marketplace or manifest/permission language.

## Decision log (from design review, 2026-07-26)

- **Ledger scope:** global file, artifact ID as a field. One audit stream.
- **Sync vs agent for fixed operations:** fixed operations are Tier 1 —
  code, not agent runs. Latency/cost/determinism all favor code when the
  behavior doesn't depend on the data.
- **Reload trigger publicly exposable** because activation is gated by
  filesystem authorship, not by the trigger. The loader's agent-writability
  check is what makes this true; it is a hard-fail, not a warning.
- **Tier-2 model selection** rides in the declaration but is clamped by a
  server allowlist. Open sub-question deferred to §3 implementation:
  whether the allowlist defaults to the cron-run policy or its own list.
