import Testing
import Foundation
@testable import Portal

/// Guards `ChatMessage.delegationBatchNoticeLabel` — the classifier that pulls
/// gateway async-delegation batch markers (e.g. `[ASYNC DELEGATION BATCH
/// COMPLETE]`) out of the prose-bubble render path and into a centered
/// interstitial chip. The detector is deliberately strict (whole trimmed
/// content must be a single bare bracketed marker) so it can never swallow real
/// model output; these tests pin both halves — it fires on the marker, and
/// stays nil on anything that could be genuine prose.
@Suite("Delegation batch notice")
private struct DelegationBatchNoticeTests {

    private func assistant(_ content: String) -> ChatMessage {
        ChatMessage(role: .assistant, content: content)
    }

    @Test("fires on the canonical marker and humanizes the label")
    private func canonicalMarker() {
        #expect(assistant("[ASYNC DELEGATION BATCH COMPLETE]").delegationBatchNoticeLabel == "delegation batch complete")
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

    @Test("nil when the marker has real output appended after the closing bracket")
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
