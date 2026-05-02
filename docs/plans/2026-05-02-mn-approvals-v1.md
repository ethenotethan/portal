# Hermes M/N Approvals V1 Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Add a durable, HermesNative-visible M/N approval flow for autonomous write/modify actions, starting with generic approval proposals and leaving Linear/tool-specific executors pluggable.

**Architecture:** Implement approval state in the Hermes gateway/TUI RPC layer as a small durable JSON store under `$HERMES_HOME/approvals`. Agents/tools create typed approval proposals; HermesNative lists, receives events for, and decides approvals. V1 uses existing API-server auth and logical approver IDs, supports M/N quorum, and deliberately avoids device signatures/principal unification to minimize fork-management risk.

**Tech Stack:** Python gateway/TUI JSON-RPC (`tui_gateway/server.py`, new `gateway/approvals.py`, optional tool in `tools/approval_requests.py`), SwiftUI HermesNative (`GatewayClient`, models, viewmodel, views), JSON files with atomic writes, XCTest/pytest.

---

## Existing context to preserve

- API server WebSocket `/v1/ws` in `gateway/platforms/api_server.py` bridges every request to `tui_gateway.server.dispatch`.
- TUI RPC methods are registered in `tui_gateway/server.py` via `@method("...")`.
- There is already blocking command approval via `approval.respond`, `tools.approval.resolve_gateway_approval`, and `approval.request` event. Do **not** replace it in V1; add a new durable approval domain.
- HermesNative already parses event frames in `GatewayClient.handleMessage` and maps them through `GatewayEvent.from(type:payload:)`.
- HermesNative already has a lightweight cron dashboard pattern: model + `@Observable` viewmodel + list/detail UI + `GatewayClient` RPC methods.
- Current Hermes Agent repo working tree has local modifications; avoid broad edits and never `git add -A`.

---

## V1 product contract

### Approval object

```json
{
  "id": "appr_01HV...",
  "status": "pending",
  "target": "linear",
  "action": "issue.update",
  "summary": "Move INF-421 to In Progress",
  "risk": "medium",
  "resource": {"type": "issue", "id": "INF-421", "title": "Provider health scoring", "url": "https://linear.app/..."},
  "diff_markdown": "Status:\n  Backlog → In Progress",
  "payload": {"opaque_executor_payload": true},
  "proposal_hash": "sha256:...",
  "requested_by": {"session_id": "...", "tool": "linear_propose_mutation"},
  "quorum": {"required": 2, "allowed": ["ethan", "gajesh", "bbuddha_xyz"]},
  "decisions": [],
  "created_at": 1777745160.0,
  "expires_at": 1777748760.0,
  "applied_at": null,
  "denied_at": null
}
```

### Decision object

```json
{
  "approver": "ethan",
  "decision": "approve",
  "comment": "ok",
  "decided_at": 1777745200.0,
  "source": "hermes_native"
}
```

### Quorum semantics

- `required = M`.
- `allowed = []` means any authenticated caller with the API key may decide in V1. If non-empty, `approver` must be in `allowed`.
- One decision per approver per approval. A later decision from the same approver replaces their previous decision while approval is still pending.
- Approval applies when unique `approve` count >= `required`.
- Denial is terminal only if `decision == deny` and `deny_terminal == true` in params/config. Default V1: denial records a no vote but does not terminally deny unless quorum can no longer be reached or explicit terminal denial is requested.
- Expired approvals cannot be decided.
- Executor is stubbed in V1: when quorum is met, status becomes `approved` or `ready_to_apply`; real tool-specific application can follow separately.

### RPC methods

```text
approval.create    # internal/tool-facing, can be used from tests and future tools
approval.list
approval.get
approval.decide
approval.cancel
```

### Events

```text
approval.created
approval.updated
approval.approved
approval.denied
approval.expired
approval.canceled
```

Events can use empty `session_id` so all native clients receive them via current transport. If broadcast-to-all transports is not available, emitting to the request transport is acceptable for V1; list refresh covers missed events.

---

## Task 1: Add Python approval store tests

**Objective:** Define durable M/N approval behavior before implementation.

**Files:**
- Create: `tests/gateway/test_approvals.py`
- Create later: `gateway/approvals.py`

**Step 1: Write failing tests**

Add tests covering:

```python
def test_create_approval_defaults_to_pending(tmp_path, monkeypatch): ...
def test_m_of_n_quorum_marks_approved(tmp_path, monkeypatch): ...
def test_duplicate_approver_replaces_decision_not_counted_twice(tmp_path, monkeypatch): ...
def test_disallowed_approver_rejected(tmp_path, monkeypatch): ...
def test_expired_approval_rejects_decision(tmp_path, monkeypatch): ...
def test_cancel_pending_approval(tmp_path, monkeypatch): ...
```

Test setup should monkeypatch Hermes home before importing/reloading `gateway.approvals` if the module computes paths at import time. Prefer module code that calls `get_hermes_home()` lazily to simplify tests.

**Step 2: Run test to verify failure**

```bash
cd ~/.hermes/hermes-agent
python -m pytest tests/gateway/test_approvals.py -q
```

Expected: import failure for `gateway.approvals`.

---

## Task 2: Implement `gateway/approvals.py`

**Objective:** Add a small, profile-safe, atomic JSON approval store.

**Files:**
- Create: `gateway/approvals.py`
- Test: `tests/gateway/test_approvals.py`

**Implementation sketch:**

```python
from __future__ import annotations

import hashlib, json, os, tempfile, threading, time, uuid
from pathlib import Path
from typing import Any
from hermes_constants import get_hermes_home

_LOCK = threading.RLock()

class ApprovalError(Exception): pass
class ApprovalNotFound(ApprovalError): pass
class ApprovalForbidden(ApprovalError): pass
class ApprovalExpired(ApprovalError): pass
class ApprovalInvalid(ApprovalError): pass

def _base_dir() -> Path:
    return Path(get_hermes_home()) / "approvals"

def _status_dir(status: str) -> Path:
    return _base_dir() / status

def _secure_write(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, ensure_ascii=False, sort_keys=True)
            f.flush(); os.fsync(f.fileno())
        os.replace(tmp, path)
        try: os.chmod(path, 0o600)
        except OSError: pass
    except BaseException:
        try: os.unlink(tmp)
        except OSError: pass
        raise

def proposal_hash(payload: dict[str, Any]) -> str:
    raw = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return "sha256:" + hashlib.sha256(raw.encode("utf-8")).hexdigest()
```

Expose:

```python
create_approval(...)->dict
list_approvals(status="pending", limit=50)->list[dict]
get_approval(id)->dict
decide_approval(id, approver, decision, comment="", source="rpc", deny_terminal=False)->dict
cancel_approval(id, reason="")->dict
expire_due(now=None)->list[dict]
```

Store files under:

```text
$HERMES_HOME/approvals/pending/<id>.json
$HERMES_HOME/approvals/approved/<id>.json
$HERMES_HOME/approvals/denied/<id>.json
$HERMES_HOME/approvals/canceled/<id>.json
$HERMES_HOME/approvals/expired/<id>.json
```

Moving status should be atomic-ish: write destination then unlink source.

**Step 2: Run tests**

```bash
python -m pytest tests/gateway/test_approvals.py -q
```

Expected: PASS.

---

## Task 3: Add TUI/API-server JSON-RPC methods

**Objective:** Expose approval store over the existing `/v1/ws` JSON-RPC path used by HermesNative.

**Files:**
- Modify: `tui_gateway/server.py`
- Test: create or modify `tests/tui_gateway/test_approval_rpc.py`

**Step 1: Write failing RPC tests**

Call `tui_gateway.server.dispatch()` directly with methods:

```python
{"jsonrpc":"2.0", "id":1, "method":"approval.create", "params": {...}}
{"jsonrpc":"2.0", "id":2, "method":"approval.list", "params":{"status":"pending"}}
{"jsonrpc":"2.0", "id":3, "method":"approval.get", "params":{"id": approval_id}}
{"jsonrpc":"2.0", "id":4, "method":"approval.decide", "params":{"id": approval_id, "approver":"ethan", "decision":"approve"}}
```

Assert JSON-RPC response shapes and status transitions.

**Step 2: Implement methods near existing `approval.respond`**

Add methods after the current blocking approval methods:

```python
@method("approval.create")
def _(rid, params: dict) -> dict:
    from gateway.approvals import create_approval
    try:
        approval = create_approval(**params)
        _emit("approval.created", "", {"approval": _approval_summary(approval)})
        return _ok(rid, {"approval": approval})
    except Exception as e:
        return _err(rid, 5004, str(e))
```

Add similar methods for list/get/decide/cancel. `approval.decide` should emit `approval.updated` every time and `approval.approved` when quorum is met.

**Important:** V1 may require clients to pass `approver`. If missing, use `params.get("approver") or "api"` to keep dev flow simple.

**Step 3: Run focused tests**

```bash
python -m pytest tests/tui_gateway/test_approval_rpc.py tests/gateway/test_approvals.py -q
```

Expected: PASS.

---

## Task 4: Add a generic agent-facing proposal tool

**Objective:** Let autonomous agents request durable approvals without exposing write tools.

**Files:**
- Create: `tools/approval_requests.py`
- Modify if needed: `toolsets.py`
- Test: `tests/tools/test_approval_requests.py`

**Tool schema:**

```python
request_approval(
    target: str,
    action: str,
    summary: str,
    diff_markdown: str = "",
    payload: dict | str = None,
    risk: str = "medium",
    required_approvals: int = 1,
    allowed_approvers: list[str] = None,
    expires_in_seconds: int = 3600,
    resource: dict = None,
)
```

The handler should call `gateway.approvals.create_approval`, emit a best-effort `approval.created` event if there is a current TUI transport available, and return JSON:

```json
{"success": true, "approval_id": "appr_...", "status": "pending", "required": 2}
```

**Note:** It is okay if event emission is skipped in early V1 when tool runs outside TUI context; HermesNative can refresh `approval.list`.

**Run:**

```bash
python -m pytest tests/tools/test_approval_requests.py -q
```

---

## Task 5: Add HermesNative approval models and RPC client methods

**Objective:** Give the app typed access to approval RPCs.

**Files:**
- Create: `Sources/HermesNative/Models/ApprovalRequest.swift`
- Modify: `Sources/HermesNative/Models/GatewayEvent.swift`
- Modify: `Sources/HermesNative/Services/GatewayClient.swift`

**Model sketch:**

```swift
struct ApprovalRequest: Identifiable, Equatable {
    let id: String
    let status: String
    let target: String
    let action: String
    let summary: String
    let risk: String
    let createdAt: Double?
    let expiresAt: Double?
    let requiredApprovals: Int
    let approvalCount: Int
    let denialCount: Int
}

struct ApprovalDetail: Identifiable, Equatable {
    let id: String
    let status: String
    let target: String
    let action: String
    let summary: String
    let risk: String
    let resourceTitle: String?
    let resourceURL: String?
    let diffMarkdown: String
    let decisions: [ApprovalDecisionRecord]
    let requiredApprovals: Int
}
```

**GatewayClient methods:**

```swift
func approvalList(status: String = "pending", limit: Int = 50) async throws -> [ApprovalRequest]
func approvalGet(id: String) async throws -> ApprovalDetail
func approvalDecide(id: String, approver: String, decision: String, comment: String?) async throws -> ApprovalDetail
func approvalCancel(id: String, reason: String?) async throws -> ApprovalDetail
```

Follow existing RPC style: `let response = try await call("method", params: ...)`, check `response.error`, parse `response.result?.dictionaryValue`.

**Event changes:**

Add cases:

```swift
case approvalCreated(ApprovalRequest)
case approvalUpdated(ApprovalRequest)
case approvalApproved(ApprovalRequest)
case approvalDenied(ApprovalRequest)
case approvalExpired(ApprovalRequest)
case approvalCanceled(ApprovalRequest)
```

Keep old `.approvalRequest(payload:)` for blocking terminal-command approvals.

---

## Task 6: Add HermesNative ApprovalListViewModel

**Objective:** Maintain approval inbox state and react to gateway events.

**Files:**
- Create: `Sources/HermesNative/ViewModels/ApprovalListViewModel.swift`
- Modify: likely `SessionListViewModel.swift` or app root to own one instance

**Implementation sketch:**

```swift
@MainActor
@Observable
final class ApprovalListViewModel {
    private let gateway: GatewayClient
    var pending: [ApprovalRequest] = []
    var history: [ApprovalRequest] = []
    var selectedApprovalID: String?
    var selectedDetail: ApprovalDetail?
    var isLoading = false
    var errorMessage: String?
    var approverName: String {
        UserDefaults.standard.string(forKey: "hermes.approvals.approverName") ?? "api"
    }

    func refresh() async { ... }
    func loadDetail(id: String) async { ... }
    func approve(id: String, comment: String? = nil) async { ... }
    func deny(id: String, comment: String? = nil) async { ... }
    func handleEvent(_ event: GatewayEvent) { ... }
}
```

For V1, `approverName` can be a user-editable setting later. Default `api` keeps development unblocked; a follow-up can wire identity to native device/user.

---

## Task 7: Add HermesNative approval inbox UI

**Objective:** Make M/N approvals usable from macOS/iOS without chat commands.

**Files:**
- Create: `Sources/HermesNative/Views/ApprovalListView.swift`
- Create: `Sources/HermesNative/Views/ApprovalDetailView.swift`
- Modify: `Sources/HermesNative/Views/SessionListView.swift` and/or platform root navigation

**UI requirements:**

Approval row shows:

```text
[risk badge] summary
Target/action · approvals 1/2 · expires in 14m
```

Detail shows:

```text
Linear · issue.update
INF-421 — Provider health scoring
Status: Backlog → In Progress
Required approvals: 1/2
Decisions: Ethan approved, Gajesh pending
[Approve] [Deny]
```

Use `Theme.*` colors only. For diff body, use existing `MarkdownContentView`.

Platform integration:

- iOS: add `Approvals` tab beside Sessions/Cron, badge count if easy.
- macOS: toolbar button or sidebar section like Cron dashboard.
- Swipe actions on pending rows: Approve leading, Deny trailing.
- Context menu on macOS pending rows: Approve/Deny/Refresh.

---

## Task 8: Add local notifications for new approvals

**Objective:** Surface pending approvals immediately in HermesNative.

**Files:**
- Modify: `Sources/HermesNative/Services/NotificationService.swift`
- Modify: event handling owner to call notification service on `approval.created`

**Behavior:**

Add category if needed:

```swift
case approval
```

Method:

```swift
func notifyApprovalRequired(summary: String, approvalID: String, required: Int, current: Int)
```

Notification text:

```text
Approval required
Move INF-421 to In Progress · 0/2 approvals
```

Tapping can initially just open the app; deep-linking to detail can be follow-up.

---

## Task 9: End-to-end manual verification

**Objective:** Prove V1 works across gateway RPC and HermesNative.

**Gateway test via WebSocket or direct dispatch:**

If gateway is running with API server enabled, connect HermesNative normally. Otherwise use a direct Python smoke:

```bash
cd ~/.hermes/hermes-agent
python - <<'PY'
from tui_gateway import server
params = {
  "target": "linear",
  "action": "issue.update",
  "summary": "Move INF-421 to In Progress",
  "diff_markdown": "Status:\n  Backlog → In Progress",
  "risk": "medium",
  "required_approvals": 2,
  "allowed_approvers": ["ethan", "gajesh"],
  "expires_in_seconds": 3600,
}
r = server.dispatch({"jsonrpc":"2.0","id":1,"method":"approval.create","params":params})
print(r)
appr = r["result"]["approval"]["id"]
print(server.dispatch({"jsonrpc":"2.0","id":2,"method":"approval.decide","params":{"id":appr,"approver":"ethan","decision":"approve"}}))
print(server.dispatch({"jsonrpc":"2.0","id":3,"method":"approval.decide","params":{"id":appr,"approver":"gajesh","decision":"approve"}}))
PY
```

Expected: final status `approved`.

**HermesNative build:**

```bash
cd ~/projects/HermesNative
xcodebuild build -project HermesNative.xcodeproj -scheme HermesNative-macOS \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY="-"
```

Expected: build succeeds.

**Hermes Agent focused tests:**

```bash
cd ~/.hermes/hermes-agent
python -m pytest tests/gateway/test_approvals.py tests/tui_gateway/test_approval_rpc.py tests/tools/test_approval_requests.py -q
```

Expected: PASS.

---

## Out of scope for V1

- Secure Enclave signatures.
- Unified Hermes principal store.
- Real Linear mutation executor.
- Push notifications through APNs.
- Editing proposals in Native.
- Approval leases/budgets.
- Multi-transport broadcast reliability. Polling/list refresh is acceptable.

---

## Follow-up V2 shape

Once V1 proves useful, upstream-friendly next steps:

1. Replace freeform `approver` with authenticated principal mapping.
2. Add device-bound native identities and signed decisions.
3. Add policy config for action classes and M/N defaults.
4. Add executor registry: `target+action -> revalidate -> apply`.
5. Make approvals generic across Linear, GitHub, filesystem writes, deploys, cron edits.
