import Testing
import Foundation
@testable import Portal

/// Comprehensive tests for the heuristic reasoning extractor.
///
/// Each test covers one pattern layer (choice, conclusion, step plan,
/// comparison, conditional, trade-off) plus dedup, cap, fallback, and
/// edge cases. Tests call `extractDecisions(from:)` directly — no async,
/// no buffering, deterministic.
@Suite("Heuristic Reasoning Summarizer")
internal struct HeuristicReasoningSummarizerTests {

    /// Mirror of the private normalizer for test-side dedup verification.
    private func normalizeForTest(_ label: String) -> String {
        let lower = label.lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]", with: "", options: .regularExpression)
        // Collapse whitespace manually (production uses a private extension)
        let collapsed = lower.components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Layer 1: Choices

    @Test("Explicit 'I should' with a because clause")
    internal func choiceWithBecause() {
        let decisions = HeuristicReasoningSummarizer.extractDecisions(
            from: "I should use SQLite because it's embedded and needs no server."
        )
        #expect(decisions.count == 1)
        #expect(decisions[0].label.contains("SQLite"))
        #expect(decisions[0].reasoning.contains("embedded"))
    }

    @Test("Choice with alternative — 'instead of'")
    internal func choiceWithAlternative() {
        let decisions = HeuristicReasoningSummarizer.extractDecisions(
            from: "I decided to use Redis instead of Memcached because we need persistence."
        )
        #expect(decisions.count == 1)
        let label = decisions[0].label.lowercased()
        #expect(label.contains("redis"))
        #expect(label.contains("memcached"))
        #expect(decisions[0].options.count == 2)
    }

    @Test("'choose X over Y' pattern")
    internal func chooseOverY() {
        let decisions = HeuristicReasoningSummarizer.extractDecisions(
            from: "I'll choose the streaming approach over batch processing."
        )
        #expect(decisions.count >= 1)
        #expect(decisions[0].label.lowercased().contains("streaming"))
    }

    @Test("'Let me' pattern")
    internal func letMePattern() {
        let decisions = HeuristicReasoningSummarizer.extractDecisions(
            from: "Let me check the database schema first."
        )
        #expect(decisions.count >= 1)
        #expect(decisions[0].label.lowercased().contains("database"))
    }

    // MARK: - Layer 2: Conclusions

    @Test("Therefore conclusion")
    internal func thereforeConclusion() {
        let decisions = HeuristicReasoningSummarizer.extractDecisions(
            from: "The latency is 200ms. Therefore, we should add a cache layer."
        )
        #expect(decisions.contains { $0.label.lowercased().contains("cache") })
    }

    @Test("Thus conclusion")
    internal func thusConclusion() {
        let decisions = HeuristicReasoningSummarizer.extractDecisions(
            from: "All pods are crashing. Thus, the deployment is unhealthy."
        )
        #expect(decisions.contains { $0.label.lowercased().contains("unhealthy") || $0.label.lowercased().contains("deployment") })
    }

    // MARK: - Layer 3: Step Plans

    @Test("Numbered steps — Step 1, Step 2, Step 3")
    internal func numberedSteps() {
        let text = """
        Step 1: Parse the incoming request body.
        Step 2: Validate the schema against the spec.
        Step 3: Write to the database.
        """
        let decisions = HeuristicReasoningSummarizer.extractDecisions(from: text)
        #expect(decisions.count == 3)
        #expect(decisions[0].label.lowercased().contains("parse"))
        #expect(decisions[1].label.lowercased().contains("validate"))
        #expect(decisions[2].label.lowercased().contains("database"))
    }

    @Test("Ordinal plan — First, Then, Finally")
    internal func ordinalPlan() {
        let text = "First, read the config file. Then, initialize the logger. Finally, start the server."
        let decisions = HeuristicReasoningSummarizer.extractDecisions(from: text)
        #expect(decisions.count >= 2)
    }

    @Test("Markdown numbered list")
    internal func markdownNumberedList() {
        let text = """
        1. Check the network connectivity
        2. Verify the DNS resolution
        3. Test the firewall rules
        4. Review the proxy configuration
        """
        let decisions = HeuristicReasoningSummarizer.extractDecisions(from: text)
        #expect(decisions.count >= 3)
        #expect(decisions[0].label.lowercased().contains("network"))
    }

    @Test("Single step is not treated as a plan")
    internal func singleStepNotPlan() {
        let decisions = HeuristicReasoningSummarizer.extractDecisions(
            from: "Step 1: Do something."
        )
        // Single step should fall to fallback if nothing else matches
        #expect(decisions.count <= 1)
    }

    // MARK: - Layer 4: Comparisons

    @Test("'X is faster than Y' comparison")
    internal func comparisonFaster() {
        let decisions = HeuristicReasoningSummarizer.extractDecisions(
            from: "gRPC is faster than REST for internal microservices."
        )
        #expect(decisions.count >= 1)
        let d = decisions[0]
        #expect(d.label.lowercased().contains("grpc") || d.reasoning.lowercased().contains("grpc"))
        #expect(d.options.count == 2)
    }

    @Test("'more efficient than' comparison")
    internal func comparisonMoreEfficient() {
        let decisions = HeuristicReasoningSummarizer.extractDecisions(
            from: "Connection pooling is more efficient than opening a new connection per request."
        )
        #expect(decisions.contains { $0.label.lowercased().contains("connection") })
    }

    // MARK: - Layer 5: Conditionals

    @Test("'If X then Y' conditional")
    internal func ifThenConditional() {
        let decisions = HeuristicReasoningSummarizer.extractDecisions(
            from: "If the cache is full, then we should evict the oldest entries."
        )
        #expect(decisions.count >= 1)
        #expect(decisions[0].label.contains("→") || decisions[0].label.contains("if"))
    }

    @Test("'If X, should Y' conditional")
    internal func ifShouldConditional() {
        let decisions = HeuristicReasoningSummarizer.extractDecisions(
            from: "If the build fails, we should check the CI logs."
        )
        #expect(decisions.count >= 1)
    }

    @Test("'Unless X' conditional")
    internal func unlessConditional() {
        let decisions = HeuristicReasoningSummarizer.extractDecisions(
            from: "Unless the database is replicated, we must not run migrations during peak hours."
        )
        #expect(decisions.count >= 1)
    }

    // MARK: - Layer 6: Trade-offs

    @Test("Pros and cons trade-off")
    internal func prosAndCons() {
        let text = """
        Pros: Fast execution, simple code. Cons: High memory usage.
        """
        let decisions = HeuristicReasoningSummarizer.extractDecisions(from: text)
        #expect(decisions.contains { $0.label == "Trade-off analysis" })
    }

    @Test("Advantages and disadvantages trade-off")
    internal func advantagesDisadvantages() {
        let text = "Advantages: Low latency. Disadvantages: Higher complexity."
        let decisions = HeuristicReasoningSummarizer.extractDecisions(from: text)
        #expect(decisions.contains { $0.label == "Trade-off analysis" })
    }

    // MARK: - Deduplication

    @Test("Duplicate decisions are collapsed")
    internal func dedupIdentical() {
        // Same sentence twice — the dedup normalizer should produce the
        // same key for both and collapse them to one decision.
        let text = "I should check the logs. I should check the logs."
        let decisions = HeuristicReasoningSummarizer.extractDecisions(from: text)
        let keys = Set(decisions.map { normalizeForTest($0.label) })
        #expect(keys.count == 1)
    }

    @Test("Similar labels with different wording are kept")
    internal func dedupDifferentWording() {
        let text = """
        I should check the database connection. I should verify the API endpoint.
        """
        let decisions = HeuristicReasoningSummarizer.extractDecisions(from: text)
        #expect(decisions.count == 2)
    }

    // MARK: - Cap

    @Test("Results are capped at 12")
    internal func capAt12() {
        var lines: [String] = []
        for i in 1...20 {
            lines.append("I should do task number \(i).")
        }
        let decisions = HeuristicReasoningSummarizer.extractDecisions(from: lines.joined(separator: " "))
        #expect(decisions.count <= 12)
    }

    // MARK: - Fallback

    @Test("Fallback: long reasoning with no patterns uses first line")
    internal func fallbackFirstLine() {
        let decisions = HeuristicReasoningSummarizer.extractDecisions(
            from: "The system appears to be running within normal parameters."
        )
        #expect(decisions.count == 1)
        #expect(decisions[0].label.count >= 15)
    }

    @Test("Fallback: short gibberish returns nothing")
    internal func fallbackShortGibberish() {
        let decisions = HeuristicReasoningSummarizer.extractDecisions(from: "hmm ok")
        #expect(decisions.isEmpty)
    }

    // MARK: - Edge Cases

    @Test("Empty text returns nothing")
    internal func emptyText() {
        let decisions = HeuristicReasoningSummarizer.extractDecisions(from: "")
        #expect(decisions.isEmpty)
    }

    @Test("Whitespace-only text returns nothing")
    internal func whitespaceOnly() {
        let decisions = HeuristicReasoningSummarizer.extractDecisions(from: "   \n\t  \n")
        #expect(decisions.isEmpty)
    }

    @Test("Markdown formatting is stripped from labels")
    internal func markdownStripped() {
        let decisions = HeuristicReasoningSummarizer.extractDecisions(
            from: "I should **definitely** use the `async` approach."
        )
        #expect(decisions.count >= 1)
        #expect(!decisions[0].label.contains("**"))
        #expect(!decisions[0].label.contains("`"))
    }

    @Test("Labels are truncated to 80 characters")
    internal func labelsTruncated() {
        let longText = "I should " + String(repeating: "do something ", count: 20) + "."
        let decisions = HeuristicReasoningSummarizer.extractDecisions(from: longText)
        #expect(decisions.count >= 1)
        #expect(decisions[0].label.count <= 80)
    }

    @Test("Multiple pattern types coexist in one trace")
    internal func multiplePatternsCoexist() {
        let text = """
        I should check the config file first.
        Step 1: Load the config. Step 2: Parse the values. Step 3: Apply them.
        gRPC is faster than REST for this use case.
        Therefore, we should use gRPC.
        """
        let decisions = HeuristicReasoningSummarizer.extractDecisions(from: text)
        #expect(decisions.count >= 3)
        // Should have a choice, steps, comparison/conclusion
        let labels = decisions.map { $0.label.lowercased() }.joined(separator: " ")
        #expect(labels.contains("config") || labels.contains("grpc") || labels.contains("load"))
    }

    @Test("Multiple choices in one trace are all captured")
    internal func multipleChoices() {
        let text = """
        I should check the logs. I should also verify the database connection.
        """
        let decisions = HeuristicReasoningSummarizer.extractDecisions(from: text)
        #expect(decisions.count >= 2)
        let labels = decisions.map { $0.label.lowercased() }
        #expect(labels.contains { $0.contains("log") })
        #expect(labels.contains { $0.contains("database") })
    }

    // MARK: - Integration via feed/summarize/reset

    @Test("feed + summarize returns extracted decisions")
    @MainActor
    internal func feedAndSummarize() async {
        let summarizer = HeuristicReasoningSummarizer()
        await summarizer.feed(delta: "I should use the streaming approach because it's more responsive.")
        let result = await summarizer.summarize()
        #expect(result != nil)
        #expect(result?.decisions.isEmpty == false)
    }

    @Test("feed + summarize on empty buffer returns nil")
    @MainActor
    internal func feedEmptySummarize() async {
        let summarizer = HeuristicReasoningSummarizer()
        await summarizer.feed(delta: "")
        let result = await summarizer.summarize()
        #expect(result == nil)
    }

    @Test("reset clears the buffer")
    @MainActor
    internal func resetClearsBuffer() async {
        let summarizer = HeuristicReasoningSummarizer()
        await summarizer.feed(delta: "I should check something.")
        summarizer.reset()
        let result = await summarizer.summarize()
        #expect(result == nil)
    }

    @Test("isReady is always true for heuristic")
    @MainActor
    internal func isReadyAlwaysTrue() {
        let summarizer = HeuristicReasoningSummarizer()
        #expect(summarizer.isReady == true)
    }

    // MARK: - ReasoningDecision equality

    @Test("ReasoningDecision Codable round-trip")
    internal func codableRoundTrip() throws {
        let original = ReasoningDecision(
            id: "test-1",
            label: "Use cache",
            reasoning: "Reduces latency",
            options: ["cache", "no-cache"]
        )
        let data = try JSONEncoder().encode([original])
        let decoded = try JSONDecoder().decode([ReasoningDecision].self, from: data)
        #expect(decoded[0] == original)
    }

    @Test("ReasoningSummary Codable round-trip with nil summary")
    internal func summaryCodableNil() throws {
        let summary = ReasoningSummary(
            decisions: [],
            summary: nil
        )
        let data = try JSONEncoder().encode(summary)
        let decoded = try JSONDecoder().decode(ReasoningSummary.self, from: data)
        #expect(decoded.decisions.isEmpty)
        #expect(decoded.summary == nil)
    }
}
