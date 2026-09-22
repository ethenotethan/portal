import Testing
import Foundation
@testable import Portal

/// Guards the classifier that pulls gateway async-delegation envelopes out of
/// the prose-bubble path. Bare markers become interstitials; completed envelopes
/// retain their returned results for the structured markdown result card.
@Suite("Delegation batch notice")
private struct DelegationBatchNoticeTests {

    private func assistant(_ content: String) -> ChatMessage {
        ChatMessage(role: .assistant, content: content)
    }

    @Test("fires on the canonical marker and humanizes the label")
    private func canonicalMarker() {
        #expect(assistant("[ASYNC DELEGATION BATCH COMPLETE]").delegationBatchNoticeLabel == "delegation batch complete")
    }

    @Test("captures a completed batch envelope without losing its returned results")
    private func completedBatchEnvelope() {
        let content = """
        [ASYNC DELEGATION BATCH COMPLETE — deleg_e34c954c]
        A background fan-out of 1 subagent(s) you dispatched earlier has finished.

        --- ✓ TASK 1/1: Build the shell (status=completed, api_calls=21, 251.24s) ---
        - Implemented the local-only foundation.
        """

        let notice = assistant(content).delegationBatchNotice

        #expect(notice?.label == "delegation batch complete")
        #expect(notice?.batchID == "deleg_e34c954c")
        #expect(notice?.details == """
        A background fan-out of 1 subagent(s) you dispatched earlier has finished.

        --- ✓ TASK 1/1: Build the shell (status=completed, api_calls=21, 251.24s) ---
        - Implemented the local-only foundation.
        """)
    }

    @Test("captures the legacy completion header when its opening bracket is missing")
    private func legacyHeaderWithoutOpeningBracket() {
        let content = """
        ASYNC DELEGATION BATCH COMPLETE — deleg_e34c954c]
        A background fan-out has finished.
        """

        let notice = assistant(content).delegationBatchNotice

        #expect(notice?.batchID == "deleg_e34c954c")
        #expect(notice?.details == "A background fan-out has finished.")
    }

    @Test("does not reclassify ordinary multiline prose as a completed batch")
    private func multilineProsePreserved() {
        let content = """
        [delegation batch recommendations]
        This is ordinary assistant prose.
        """

        #expect(assistant(content).delegationBatchNotice == nil)
    }

    @Test("preserves leading markdown indentation in returned details")
    private func markdownIndentationPreserved() {
        let content = "[ASYNC DELEGATION BATCH COMPLETE — deleg_1]\n    let answer = 42\nDone.\n"

        #expect(assistant(content).delegationBatchNotice?.details == "    let answer = 42\nDone.")
    }

    @Test("accepts CRLF line endings from persisted transcripts")
    private func windowsLineEndings() {
        let content = "[ASYNC DELEGATION BATCH COMPLETE — deleg_1]\r\nResults returned.\r\n"

        let notice = assistant(content).delegationBatchNotice

        #expect(notice?.batchID == "deleg_1")
        #expect(notice?.details == "Results returned.")
    }

    @Test("tolerates surrounding whitespace and trailing space in the marker")
    private func whitespaceTolerant() {
        #expect(assistant("  [ASYNC DELEGATION BATCH COMPLETE ]\n").delegationBatchNoticeLabel == "delegation batch complete")
    }

    @Test("keeps the 'async' prefix stripped but preserves other wording")
    private func variantWording() {
        #expect(assistant("[DELEGATION BATCH STARTED]").delegationBatchNoticeLabel == "delegation batch started")
    }

    @Test("nil for real prose that merely starts with a bracket")
    private func prosePreserved() {
        #expect(assistant("[note] the delegation batch pattern is worth explaining.").delegationBatchNoticeLabel == nil)
        #expect(assistant("[1] first, [2] second — a batch of delegation ideas").delegationBatchNoticeLabel == nil)
    }

    @Test("nil when prose is appended on the marker line")
    private func trailingOutputPreserved() {
        #expect(assistant("[ASYNC DELEGATION BATCH COMPLETE] Here are the results:").delegationBatchNoticeLabel == nil)
    }

    @Test("nil for a bracketed line that isn't a delegation-batch marker")
    private func unrelatedMarker() {
        #expect(assistant("[DONE]").delegationBatchNoticeLabel == nil)
        #expect(assistant("[BATCH]").delegationBatchNoticeLabel == nil)          // batch but no delegation
        #expect(assistant("[DELEGATION STATUS]").delegationBatchNoticeLabel == nil) // delegation but no batch
    }

    @Test("nil on user messages — only assistant notices are reclassified")
    private func userNotReclassified() {
        #expect(ChatMessage(role: .user, content: "[ASYNC DELEGATION BATCH COMPLETE]").delegationBatchNoticeLabel == nil)
    }
}
