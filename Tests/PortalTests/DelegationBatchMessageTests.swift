import Testing
import Foundation
@testable import Portal

/// Guards `DelegationBatchMessage.parse` — the parser that turns the gateway's
/// re-injected `[ASYNC DELEGATION BATCH COMPLETE — deleg_…]` report into per-task
/// cards. The format it targets is fixed by the harness (`process_registry.py`'s
/// `_format_async_delegation` + `delegate_tool.py`'s truncation footer), so these
/// tests pin the exact shape: the header id, the dropped boilerplate intro, each
/// `--- ✓ TASK n/m … ---` header's typed fields, and the lifted-out truncation
/// footer. An unrecognized shape must yield nil so the message falls back to
/// plain markdown rather than an empty card.
@Suite("Delegation batch message parsing")
private struct DelegationBatchMessageTests {

    /// A realistic three-task batch mirroring the harness output verbatim —
    /// including a truncation footer with the `[… middle omitted …]` marker on
    /// task 1, a clean task 2, and a failed task 3 whose goal contains
    /// parentheses (to exercise the `(status=` anchor).
    private static let sample = """
    [ASYNC DELEGATION BATCH COMPLETE — deleg_72e3ab62]
    A background fan-out of 3 subagent(s) you dispatched earlier has finished. All ran
    in parallel and waited on each other; their consolidated results are below. You may
    have moved on since dispatching — act on these or re-dispatch if things have changed.

    Dispatched: 2026-08-14 09:15:02 (12m 4s ago)
    Context you provided: audit the coordinator API
    Toolsets: read, search
    Role: researcher   Model: claude-opus-4-8   Total duration: 372.4s

    --- ✓ TASK 1/3: Map the coordinator API surface  (status=completed, api_calls=8, 184.6s) ---
    ## Findings
    The coordinator exposes 4 endpoints.

    [... middle omitted — see footer ...]

    Endpoint 4 is deprecated.

    ──────── [SUMMARY TRUNCATED] ────────
    Showing 1,493 chars (head) + 385 chars (tail) of 18,184 total — trimmed to protect the parent's context window.
    Full subagent output saved to: /tmp/deleg/task1.txt
    To read the omitted middle: read_file path="/tmp/deleg/task1.txt" offset=42 limit=200  (the file is the complete summary; raise/lower offset to page through it).
    ─────────────────────────────────────

    --- ✓ TASK 2/3: Check auth middleware  (status=completed, api_calls=5, 96.2s) ---
    Auth looks solid.

    --- ✗ TASK 3/3: Load test (v2)  (status=failed, 12.0s) ---
    (failed: timeout after 12s)
    Partial output:
    Got through 40% of the plan.
    """

    @Test("header id, dropped intro, and preamble captions")
    private func headerAndPreamble() throws {
        let batch = try #require(DelegationBatchMessage.parse(Self.sample))
        #expect(batch.delegationID == "deleg_72e3ab62")
        #expect(batch.totalDurationSeconds == 372.4)
        // The boilerplate "A background fan-out…" sentence is dropped; only the
        // short informative captions survive.
        #expect(!batch.metaLines.contains { $0.hasPrefix("A background fan-out") })
        #expect(batch.metaLines.contains("Context you provided: audit the coordinator API"))
        #expect(batch.metaLines.contains("Toolsets: read, search"))
        #expect(batch.tasks.count == 3)
        #expect(batch.batchError == nil)
    }

    @Test("a completed task parses its typed header fields and markdown body")
    private func completedTask() throws {
        let batch = try #require(DelegationBatchMessage.parse(Self.sample))
        let task = batch.tasks[0]
        #expect(task.index == 1)
        #expect(task.total == 3)
        #expect(task.succeeded)
        #expect(task.status == "completed")
        #expect(task.apiCalls == 8)
        #expect(task.durationSeconds == 184.6)
        #expect(task.goal == "Map the coordinator API surface")
        // Body keeps its markdown but sheds the footer and the middle marker.
        #expect(task.body.contains("## Findings"))
        #expect(task.body.contains("Endpoint 4 is deprecated."))
        #expect(!task.body.contains("middle omitted"))
        #expect(!task.body.contains("SUMMARY TRUNCATED"))
        #expect(!task.body.contains("saved to"))
    }

    @Test("the truncation footer is lifted into typed fields")
    private func truncationFooter() throws {
        let batch = try #require(DelegationBatchMessage.parse(Self.sample))
        let truncation = try #require(batch.tasks[0].truncation)
        #expect(truncation.headChars == 1_493)
        #expect(truncation.tailChars == 385)
        #expect(truncation.totalChars == 18_184)
        #expect(truncation.spillPath == "/tmp/deleg/task1.txt")
        // A task without a footer carries no truncation.
        #expect(batch.tasks[1].truncation == nil)
    }

    @Test("a failed task keeps its ✗ status and goal parens, drops absent api_calls")
    private func failedTask() throws {
        let batch = try #require(DelegationBatchMessage.parse(Self.sample))
        let task = batch.tasks[2]
        #expect(!task.succeeded)
        #expect(task.status == "failed")
        #expect(task.apiCalls == nil)       // omitted in the header → nil, not 0
        #expect(task.durationSeconds == 12.0)
        #expect(task.goal == "Load test (v2)")  // parentheses survive the (status= anchor
        #expect(task.body.contains("(failed: timeout after 12s)"))
        #expect(task.body.contains("Got through 40% of the plan."))
    }

    @Test("a wholesale batch failure surfaces as an error with no tasks")
    private func batchError() throws {
        let content = """
        [ASYNC DELEGATION BATCH COMPLETE — deleg_dead]
        A background fan-out of 2 subagent(s) you dispatched earlier has finished.

        --- ERROR ---
        The batch did not complete successfully: gateway crashed
        """
        let batch = try #require(DelegationBatchMessage.parse(content))
        #expect(batch.tasks.isEmpty)
        #expect(batch.batchError == "The batch did not complete successfully: gateway crashed")
    }

    @Test("non-batch content and the bare marker both fall through to nil")
    private func fallsThrough() {
        // Ordinary prose — never hijacks the markdown path.
        #expect(DelegationBatchMessage.parse("Here's a summary of the work.") == nil)
        // A header that opens like a batch but carries no tasks or error is not
        // worth an empty card — the bare-marker notice path handles that shape.
        #expect(DelegationBatchMessage.parse("[ASYNC DELEGATION BATCH COMPLETE]") == nil)
    }

    @Test("only assistant messages are reclassified")
    private func roleGating() {
        let user = ChatMessage(role: .user, content: Self.sample)
        #expect(user.asyncDelegationBatch == nil)
        let assistant = ChatMessage(role: .assistant, content: Self.sample)
        #expect(assistant.asyncDelegationBatch != nil)
    }
}

/// Pins the compact duration formatter shared by the batch header and task chips.
@Suite("Delegation duration formatting")
private struct DelegationDurationTests {
    @Test("sub-minute keeps the gateway's raw seconds; whole seconds drop the .0")
    private func subMinute() {
        #expect(DelegationDuration.string(45.6) == "45.6s")
        #expect(DelegationDuration.string(12.0) == "12s")
        #expect(DelegationDuration.string(45) == "45s")
    }

    @Test("a minute or more rounds and reads as m/s")
    private func overAMinute() {
        #expect(DelegationDuration.string(184.6) == "3m 5s")   // 184.6 → 185 → 3m 5s
        #expect(DelegationDuration.string(372.4) == "6m 12s")
        #expect(DelegationDuration.string(60) == "1m 0s")
    }
}
