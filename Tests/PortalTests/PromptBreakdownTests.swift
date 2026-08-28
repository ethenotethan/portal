import SwiftUI
import Testing
@testable import Portal

@Suite("Prompt breakdown")
internal struct PromptBreakdownTests {
    @Test("Token totals, remaining context, and utilization share one calculation")
    internal func tokenAccounting() {
        let breakdown = makeBreakdown(
            contextLimit: 1_000,
            systemTokens: 200,
            toolTokens: 150,
            historyTokens: 50
        )

        #expect(breakdown.totalUsedTokens == 400)
        #expect(breakdown.totalTokens == 400)
        #expect(breakdown.freeTokens == 600)
        #expect(breakdown.utilizationPercent == 40)
        #expect(breakdown.contextUsagePercent == 40)
    }

    @Test("Zero context reports zero utilization instead of dividing by zero")
    internal func zeroContextUtilization() {
        let breakdown = makeBreakdown(
            contextLimit: 0,
            systemTokens: 10,
            toolTokens: 20,
            historyTokens: 30
        )

        #expect(breakdown.utilizationPercent == 0)
    }

    @Test("Sections sort by descending token count")
    internal func sectionsSortByTokenCount() {
        let smaller = makeSection(id: "small", contentLength: 10, tokenCount: 5)
        let larger = makeSection(id: "large", contentLength: 10, tokenCount: 50)
        let breakdown = makeBreakdown(sections: [smaller, larger])

        #expect(breakdown.sortedSections.map(\.id) == ["large", "small"])
    }

    @Test("Only content shorter than 500 characters expands by default")
    internal func defaultExpansionBoundary() {
        #expect(makeSection(id: "short", contentLength: 499).isExpandableByDefault)
        #expect(!makeSection(id: "boundary", contentLength: 500).isExpandableByDefault)
    }

    @Test("Section color uses valid hex and falls back to the accent color")
    internal func sectionColor() {
        #expect(makeSection(id: "valid", contentLength: 0, colorHex: "#4ecdc4").color == Color(hex: "#4ecdc4"))
        #expect(makeSection(id: "invalid", contentLength: 0, colorHex: "not-a-color").color == .accentColor)
    }

    private func makeBreakdown(
        contextLimit: Int = 1_000,
        systemTokens: Int = 0,
        toolTokens: Int = 0,
        historyTokens: Int = 0,
        sections: [PromptSection] = []
    ) -> PromptBreakdown {
        PromptBreakdown(
            sessionID: "session",
            model: "model",
            contextLimit: contextLimit,
            totalSystemTokens: systemTokens,
            sections: sections,
            toolDefinitionsTokenCount: toolTokens,
            toolDefinitionsCount: 0,
            conversationHistoryTokenCount: historyTokens,
            conversationHistoryMessageCount: 0
        )
    }

    private func makeSection(
        id: String,
        contentLength: Int,
        tokenCount: Int = 0,
        colorHex: String = "#000000"
    ) -> PromptSection {
        PromptSection(
            id: id,
            name: id,
            source: "test",
            contentPreview: "",
            fullContent: String(repeating: "x", count: contentLength),
            tokenCount: tokenCount,
            charCount: contentLength,
            colorHex: colorHex
        )
    }
}
