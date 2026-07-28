import Foundation
import os

private let log = Logger(subsystem: "com.ethenotethan.Portal", category: "ReasoningSummarizer")


// MARK: - Regex Helper

/// Pattern-matcher factory — turns the NSRegularExpression throwing init
/// into a clean optional return with a logged warning, satisfying no_swallowed_try.
internal func makeRegex(
    pattern: String,
    options: NSRegularExpression.Options = []
) -> NSRegularExpression? {
    do {
        return try NSRegularExpression(pattern: pattern, options: options)
    } catch {
        log.warning("Invalid regex: \(error.localizedDescription)")
        return nil
    }
}
// MARK: - Summarization Result

internal struct ReasoningDecision: Codable, Sendable, Equatable {
    let id: String
    let label: String
    let reasoning: String
    let options: [String]
}

internal struct ReasoningSummary: Codable, Sendable, Equatable {
    let decisions: [ReasoningDecision]
    let summary: String?
}

// MARK: - Reasoning Summarizer Protocol

internal protocol ReasoningSummarizing: AnyObject {
    @MainActor var isReady: Bool { get }
    @MainActor func feed(delta: String)
    @MainActor func summarize() async -> ReasoningSummary?
    @MainActor func reset()
}

// MARK: - Heuristic Summarizer (Pattern-Based)
//
// Zero-dependency reasoning-structure extractor. Runs layered regex patterns
// over reasoning text, accumulates findings, and deduplicates by normalized
// label. Always available — no model download, no latency, deterministic.
//
// Patterns run in priority order; early patterns don't short-circuit later
// ones (a single reasoning trace may contain both an explicit "I should"
// decision AND a multi-step plan — we want both).

final class HeuristicReasoningSummarizer: ReasoningSummarizing {
    @MainActor var isReady: Bool = true
    private var buffer: String = ""

    @MainActor func feed(delta: String) { buffer += delta }

    @MainActor func summarize() async -> ReasoningSummary? {
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let decisions = Self.extractDecisions(from: text)
        buffer = ""
        if decisions.isEmpty { return nil }
        return ReasoningSummary(decisions: decisions, summary: nil)
    }

    @MainActor func reset() { buffer = "" }

    // MARK: - Extraction (internal for testing)

    /// Top-level extraction: runs all pattern layers, merges, and deduplicates.
    /// Internal so tests can call it directly without the async/actor dance.
    internal static func extractDecisions(from text: String) -> [ReasoningDecision] {
        // Clean markdown noise from the working text, but preserve the original
        // for substring extraction (NSRegularExpression works on the raw string).
        var all: [ReasoningDecision] = []
        var counter = 0
        func nextID(_ prefix: String) -> String {
            counter += 1
            return "\(prefix)-\(counter)-\(UUID().uuidString.prefix(6))"
        }

        // ── Layer 1: Explicit choice / preference statements ──
        all.append(contentsOf: extractChoices(from: text, idFactory: nextID))

        // ── Layer 2: Conclusion statements ("Therefore", "Thus", "So") ──
        all.append(contentsOf: extractConclusions(from: text, idFactory: nextID))

        // ── Layer 3: Multi-step plans (numbered, bulleted, or "First/Next/Then") ──
        all.append(contentsOf: extractStepPlans(from: text, idFactory: nextID))

        // ── Layer 4: Comparative quality ("X is better/faster/safer than Y") ──
        all.append(contentsOf: extractComparisons(from: text, idFactory: nextID))

        // ── Layer 5: Conditional / hypothetical reasoning ──
        all.append(contentsOf: extractConditionals(from: text, idFactory: nextID))

        // ── Layer 6: Trade-off analysis (pros/cons) ──
        all.append(contentsOf: extractTradeoffs(from: text, idFactory: nextID))

        // ── Deduplicate by normalized label ──
        var seen = Set<String>()
        let deduped = all.filter { decision in
            let key = normalizeForDedup(decision.label)
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }

        // ── Cap at 12 results to avoid flooding the graph ──
        let capped = Array(deduped.prefix(12))

        // ── Fallback: if nothing matched at all, use the first meaningful line ──
        if capped.isEmpty {
            return extractFallback(from: text, idFactory: nextID)
        }

        return capped
    }

    // MARK: - Pattern Layer 1: Choices

    /// Matches explicit choice statements:
    /// - "I should/will/need to X because Y"
    /// - "I decided to X instead of Y"
    /// - "Let me X" / "I'll X"
    /// - "choose/pick/opt for/prefer X over Y"
    private static func extractChoices(
        from text: String,
        idFactory: (String) -> String
    ) -> [ReasoningDecision] {
        let pattern = makeRegex(
            pattern: #"(?:I\s+(?:should|will|decided\s+to|could|might|need\s+to|"#
                + #"want\s+to|can|would|'ll|recommend|suggest|think|believe|suspect))"#
                + #"\s+(.+?)(?:\s+(?:instead\s+of|rather\s+than|over|versus|"#
                + #"vs\.?|or)\s+(.+?))?(?:\s+(?:because|since|as|due\s+to|"#
                + #"given\s+that)\s+(.+?))?[.!]|(?:(?:Let\s+me|I'll|I\s+will)\s+"#
                + #"(.+?)[.!])|(?:choose|pick|opt\s+for|go\s+with|prefer)\s+"#
                + #"(.+?)(?:\s+(?:over|instead\s+of|rather\s+than|versus|vs\.?)\s+(.+?))?[.!]?"#,
            options: [.caseInsensitive]
        )
        guard let pattern else { return [] }

        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        var results: [ReasoningDecision] = []

        for match in pattern.matches(in: text, range: range) {
            var choice = ""
            var alternative: String?
            var because: String?

            // Captures: 1=choice("I should..."), 2=alternative, 3=because
            //           4=choice("Let me..."), 5=choice("choose..."), 6=alt
            if match.range(at: 1).location != NSNotFound {
                choice = nsText.substring(with: match.range(at: 1))
            }
            if choice.isEmpty, match.range(at: 4).location != NSNotFound {
                choice = nsText.substring(with: match.range(at: 4))
            }
            if choice.isEmpty, match.range(at: 5).location != NSNotFound {
                choice = nsText.substring(with: match.range(at: 5))
            }
            choice = clean(choice)
            if choice.isEmpty { continue }

            if match.range(at: 2).location != NSNotFound {
                alternative = clean(nsText.substring(with: match.range(at: 2)))
            }
            if match.range(at: 6).location != NSNotFound {
                alternative = clean(nsText.substring(with: match.range(at: 6)))
            }
            if match.range(at: 3).location != NSNotFound {
                because = clean(nsText.substring(with: match.range(at: 3)))
            }

            let label = alternative.map { "\(choice) vs \($0)" } ?? choice
            var options = [choice]
            if let alt = alternative { options.append(alt) }

            results.append(ReasoningDecision(
                id: idFactory("decision"),
                label: truncate(label, 80),
                reasoning: because ?? choice,
                options: options
            ))
        }
        return results
    }

    // MARK: - Pattern Layer 2: Conclusions

    /// Matches conclusion indicators:
    /// - "Therefore, X" / "Thus, X" / "So X" / "This means X"
    /// - "The key takeaway is X" / "The conclusion is X"
    private static func extractConclusions(
        from text: String,
        idFactory: (String) -> String
    ) -> [ReasoningDecision] {
        let pattern = makeRegex(
            pattern: #"(?:Therefore|Thus|Hence|Consequently|"#
                + #"(?:^|\.\s+)So\s+|"#
                + #"This\s+means|This\s+implies|The\s+key\s+takeaway\s+is|"#
                + #"The\s+conclusion\s+is|In\s+conclusion|"#
                + #"Ultimately|As\s+a\s+result),?\s*(.+?)[.!]"#,
            options: [.caseInsensitive]
        )
        guard let pattern else { return [] }

        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        var results: [ReasoningDecision] = []

        for match in pattern.matches(in: text, range: range) {
            let raw = nsText.substring(with: match.range(at: 1))
            let conclusion = clean(raw)
            guard conclusion.count >= 10 else { continue }

            results.append(ReasoningDecision(
                id: idFactory("conclusion"),
                label: truncate(conclusion, 80),
                reasoning: conclusion,
                options: []
            ))
        }
        return results
    }

    // MARK: - Pattern Layer 3: Multi-step plans

    /// Matches structured step plans:
    /// - "Step 1: X. Step 2: Y."
    /// - "First X. Then Y. Finally Z."
    /// - "1. X  2. Y  3. Z" (markdown numbered list)
    private static func extractStepPlans(
        from text: String,
        idFactory: (String) -> String
    ) -> [ReasoningDecision] {
        var results: [ReasoningDecision] = []

        // 3a: "Step/Phase/Stage N:" style
        let numberedPattern = makeRegex(
            pattern: #"(?:Step|Phase|Stage)\s*(\d+)[:.)]\s*"#
                + #"(.+?)(?=(?:Step|Phase|Stage)\s*\d+|$)"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
        if let pattern = numberedPattern {
            let r = NSRange(location: 0, length: (text as NSString).length)
            let matches = pattern.matches(in: text, range: r)
            if matches.count >= 2 {
                for m in matches {
                    let stepNum = (text as NSString).substring(with: m.range(at: 1))
                    let body = clean((text as NSString).substring(with: m.range(at: 2)))
                    guard !body.isEmpty else { continue }
                    results.append(ReasoningDecision(
                        id: idFactory("step"),
                        label: truncate(body, 80),
                        reasoning: body,
                        options: []
                    ))
                }
                return results
            }
        }

        // 3b: Ordinal markers — "First... Then/Next... Finally..."
        let ordinalPattern = makeRegex(
            pattern: #"(?:First|Firstly|To\s+start|Initially),?\s*(.+?)[.;]\s*"#
                + #"(?:Then|Next|After\s+that|Subsequently|Secondly),?\s*(.+?)[.;]"#
                + #"(?:\s*(?:Then|Next|After\s+that|Subsequently|Thirdly|Finally|"#
                + #"Lastly),?\s*(.+?)[.;])?"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
        if let pattern = ordinalPattern {
            let r = NSRange(location: 0, length: (text as NSString).length)
            if let m = pattern.firstMatch(in: text, range: r) {
                let nsText = text as NSString
                for i in 1...3 where m.range(at: i).location != NSNotFound {
                    let body = clean(nsText.substring(with: m.range(at: i)))
                    guard !body.isEmpty else { continue }
                    results.append(ReasoningDecision(
                        id: idFactory("plan"),
                        label: truncate(body, 80),
                        reasoning: body,
                        options: []
                    ))
                }
                if results.count >= 2 { return results }
            }
        }

        // 3c: Markdown numbered list — "1. X\n2. Y\n3. Z"
        let mdListPattern = makeRegex(
            pattern: #"^\s*\d+\.\s+(.+)$"#,
            options: [.anchorsMatchLines]
        )
        if let pattern = mdListPattern {
            let r = NSRange(location: 0, length: (text as NSString).length)
            let matches = pattern.matches(in: text, range: r)
            if matches.count >= 3 {
                for m in matches {
                    let body = clean((text as NSString).substring(with: m.range(at: 1)))
                    guard body.count >= 5 else { continue }
                    results.append(ReasoningDecision(
                        id: idFactory("item"),
                        label: truncate(body, 80),
                        reasoning: body,
                        options: []
                    ))
                }
                if results.count >= 2 { return results }
            }
        }

        return results
    }

    // MARK: - Pattern Layer 4: Comparisons

    /// Matches comparative quality statements:
    /// - "X is better/faster/safer/more efficient than Y"
    /// - "X has lower latency than Y"
    private static func extractComparisons(
        from text: String,
        idFactory: (String) -> String
    ) -> [ReasoningDecision] {
        let pattern = makeRegex(
            pattern: #"(\w[\w\s-]+?)\s+(?:is|are|has|have)\s+"#
                + #"(?:better|worse|faster|slower|safer|cheaper|more\s+efficient|"#
                + #"more\s+secure|more\s+reliable|less\s+error-prone|"#
                + #"higher|lower|superior|inferior|preferable)\s+"#
                + #"(?:than|compared\s+to)\s+(.+?)[.!]"#,
            options: [.caseInsensitive]
        )
        guard let pattern else { return [] }

        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        var results: [ReasoningDecision] = []

        for match in pattern.matches(in: text, range: range) {
            let subject = clean(nsText.substring(with: match.range(at: 1)))
            let compared = clean(nsText.substring(with: match.range(at: 2)))
            guard subject.count >= 2, compared.count >= 2 else { continue }

            let label = "\(subject) vs \(compared)"
            results.append(ReasoningDecision(
                id: idFactory("compare"),
                label: truncate(label, 80),
                reasoning: "\(subject) is better than \(compared)",
                options: [subject, compared]
            ))
        }
        return results
    }

    // MARK: - Pattern Layer 5: Conditionals

    /// Matches conditional / hypothetical reasoning:
    /// - "If X then Y" / "If X, we should Y"
    /// - "Unless X, we need Y"
    private static func extractConditionals(
        from text: String,
        idFactory: (String) -> String
    ) -> [ReasoningDecision] {
        let pattern = makeRegex(
            pattern: #"If\s+(.+?),?\s+then\s+(.+?)[.!]|"#
                + #"If\s+(.+?),?\s+(?:we\s+)?(?:should|must|need\s+to|can|will)\s+(.+?)[.!]|"#
                + #"Unless\s+(.+?),?\s+(?:we\s+)?(?:should|must|need\s+to|will)\s+(.+?)[.!]"#,
            options: [.caseInsensitive]
        )
        guard let pattern else { return [] }

        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        var results: [ReasoningDecision] = []

        for match in pattern.matches(in: text, range: range) {
            var condition = ""
            var action = ""

            // "If X then Y"
            if match.range(at: 1).location != NSNotFound {
                condition = clean(nsText.substring(with: match.range(at: 1)))
                action = clean(nsText.substring(with: match.range(at: 2)))
            }
            // "If X, should Y"
            if condition.isEmpty, match.range(at: 3).location != NSNotFound {
                condition = clean(nsText.substring(with: match.range(at: 3)))
                action = clean(nsText.substring(with: match.range(at: 4)))
            }
            // "Unless X, should Y"
            if condition.isEmpty, match.range(at: 5).location != NSNotFound {
                condition = clean(nsText.substring(with: match.range(at: 5)))
                action = clean(nsText.substring(with: match.range(at: 6)))
            }

            guard !condition.isEmpty, !action.isEmpty else { continue }
            let label = "If \(condition) → \(action)"

            results.append(ReasoningDecision(
                id: idFactory("conditional"),
                label: truncate(label, 80),
                reasoning: action,
                options: [condition, action]
            ))
        }
        return results
    }

    // MARK: - Pattern Layer 6: Trade-offs

    /// Matches pros/cons analysis:
    /// - "Pros: X. Cons: Y" / "Advantages: X. Disadvantages: Y"
    private static func extractTradeoffs(
        from text: String,
        idFactory: (String) -> String
    ) -> [ReasoningDecision] {
        let pattern = makeRegex(
            pattern: #"(?:Pros?:|Advantages?:|Benefits?:)\s*"#
                + #"(.+?)(?:Cons?:|Disadvantages?:|Drawbacks?:|"#
                + #"However|But|On\s+the\s+other\s+hand)"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
        guard let pattern else { return [] }

        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)

        guard let m = pattern.firstMatch(in: text, range: range) else { return [] }
        let pro = clean(nsText.substring(with: m.range(at: 1)))
        guard pro.count >= 5 else { return [] }

        return [ReasoningDecision(
            id: idFactory("tradeoff"),
            label: "Trade-off analysis",
            reasoning: truncate(pro, 120),
            options: []
        )]
    }

    // MARK: - Fallback

    /// Last resort: if no patterns matched, use the first meaningful line.
    /// Only triggers for reasoning text that's long enough to be useful.
    private static func extractFallback(
        from text: String,
        idFactory: (String) -> String
    ) -> [ReasoningDecision] {
        let lines = text.components(separatedBy: .newlines)
        guard let firstLine = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return []
        }
        let cleaned = clean(firstLine)
        guard cleaned.count >= 15 else { return [] }

        return [ReasoningDecision(
            id: idFactory("reason"),
            label: truncate(cleaned, 80),
            reasoning: truncate(text, 200),
            options: []
        )]
    }

    // MARK: - Text Utilities

    /// Strips markdown formatting, collapses whitespace, trims.
    private static func clean(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "##", with: "")
            .replacingOccurrences(of: "###", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .condensedWhitespace
    }

    private static func truncate(_ s: String, _ max: Int) -> String {
        s.count <= max ? s : String(s.prefix(max))
    }

    /// Normalizes a label for dedup: lowercase, strip non-alphanumerics,
    /// collapse whitespace. "I should read the file" and "I should read the file."
    /// produce the same key.
    private static func normalizeForDedup(_ label: String) -> String {
        label.lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]", with: "", options: [.regularExpression])
            .condensedWhitespace
            .trimmingCharacters(in: .whitespaces)
    }
}

private extension String {
    /// Collapses runs of whitespace into a single space.
    var condensedWhitespace: String {
        let pattern = makeRegex(pattern: #"\s+"#, options: [])
        return pattern?
            .stringByReplacingMatches(
                in: self, range: NSRange(location: 0, length: (self as NSString).length),
                withTemplate: " "
            ) ?? self
    }
}

// MARK: - MLX-Powered Summarizer (Apple Silicon, Experimental)

#if canImport(MLXLLM) && canImport(MLXLMCommon) && canImport(HuggingFace) && canImport(Tokenizers)

@preconcurrency import MLXLLM
@preconcurrency import MLXLMCommon
import HuggingFace
import Tokenizers

struct HFHubDownloader: MLXLMCommon.Downloader {
    private let upstream = HubClient()

    func download(
        id: String, revision: String?, matching patterns: [String],
        useLatest: Bool, progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        guard let repoID = HuggingFace.Repo.ID(rawValue: id) else {
            throw SummarizerError.downloadFailed("Invalid repo: \(id)")
        }
        return try await upstream.downloadSnapshot(
            of: repoID, revision: revision ?? "main", matching: patterns,
            progressHandler: { @MainActor p in progressHandler(p) }
        )
    }
}

struct HFTokenizerWrapper: MLXLMCommon.Tokenizer, @unchecked Sendable {
    let tokenizer: Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        tokenizer.encode(text: text, addSpecialTokens: addSpecialTokens)
    }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        tokenizer.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }
    func convertTokenToId(_ token: String) -> Int? {
        tokenizer.convertTokenToId(token)
    }
    func convertIdToToken(_ id: Int) -> String? {
        tokenizer.convertIdToToken(id)
    }
    var bosToken: String? { tokenizer.bosToken }
    var eosToken: String? { tokenizer.eosToken }
    var unknownToken: String? { tokenizer.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        try tokenizer.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
    }
}

struct HFTokenizerLoaderWrapper: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        // from(pretrained:) treats the string as a Hub model ID and resolves
        // the "main" revision against it, which fails for a local path with
        // "File not found: main". from(modelFolder:) is the local-dir loader.
        let tk = try await AutoTokenizer.from(modelFolder: directory)
        return HFTokenizerWrapper(tokenizer: tk)
    }
}

enum SummarizerError: LocalizedError {
    case downloadFailed(String)
    case loadFailed(String)
    var errorDescription: String? {
        switch self {
        case .downloadFailed(let m): return "Download failed: \(m)"
        case .loadFailed(let m): return "Load failed: \(m)"
        }
    }
}

/// Experimental MLX-accelerated summarizer using Gemma 3 1B 4-bit on Apple Silicon.
/// Model downloads from HuggingFace on first use (~600MB, cached).
///
/// **Off by default.** Enable in Settings → Thought Graph → Experimental.
/// When enabled but not yet loaded (or on non-Apple-Silicon), degrades to
/// `HeuristicReasoningSummarizer`.
@MainActor
final class MLXReasoningSummarizer: ReasoningSummarizing {
    private(set) var isReady: Bool = false
    private var buffer: String = ""
    private var session: ChatSession?
    private var loadTask: Task<Void, Never>?

    private let extractionPrompt = """
You are a reasoning-structure extractor. Given an agent's reasoning trace,
extract decision points, trade-offs, or multi-step analysis patterns.
Output ONLY valid JSON with no other text.

Rules:
- Only extract EXPLICIT decisions the agent actually made. If the reasoning
  contains no clear decision, trade-off, or multi-step analysis, return an
  empty decisions array.
- Labels must be <80 chars and describe the actual decision.
- Use the EXACT JSON format shown in the schema below.

Schema (do NOT echo these example values):
{"decisions":[{"id":"d1","label":"<actual decision>","reasoning":"<why>","options":["A","B"]}],"summary":null}

If there are no decisions, respond with exactly:
{"decisions":[],"summary":null}

Reasoning:
"""

    func feed(delta: String) { buffer += delta }

    func summarize() async -> ReasoningSummary? {
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        guard !text.isEmpty, text.count >= 100 else { return nil }

        await ensureLoaded()
        guard isReady, let session = session else {
            let fallback = HeuristicReasoningSummarizer()
            fallback.feed(delta: text)
            return await fallback.summarize()
        }

        let input = String(text.prefix(1200))
        let prompt = extractionPrompt + input

        do {
            // Off the main actor — this type is @MainActor, so running MLX
            // inference inline would block the UI (see SkillSummaryService).
            let response = try await Task.detached(priority: .utility) { [session] in
                try await session.respond(to: prompt)
            }.value
            guard let jsonStart = response.firstIndex(of: "{"),
                  let jsonEnd = response.lastIndex(of: "}"), jsonStart < jsonEnd else {
                return nil
            }
            let json = String(response[jsonStart...jsonEnd])
            guard let data = json.data(using: .utf8),
                  let summary = try? JSONDecoder().decode(ReasoningSummary.self, from: data) else {
                return nil
            }
            return summary
        } catch {
            log.warning("MLX summarization failed: \(error.localizedDescription)")
            return nil
        }
    }

    func reset() { buffer = "" }

    private func ensureLoaded() async {
        if isReady { return }
        if loadTask != nil { await loadTask?.value; return }

        loadTask = Task {
            do {
                let config = LLMRegistry.gemma3_1B_qat_4bit
                let container = try await LLMModelFactory.shared.loadContainer(
                    from: HFHubDownloader(),
                    using: HFTokenizerLoaderWrapper(),
                    configuration: config
                )
                self.session = ChatSession(container)
                self.isReady = true
                log.info("MLX Gemma 3 1B loaded (first launch downloads ~600MB)")
            } catch {
                log.error("MLX model load failed: \(error.localizedDescription)")
                self.isReady = false
            }
            self.loadTask = nil
        }
        await loadTask?.value
    }
}

#else

@MainActor
final class MLXReasoningSummarizer: ReasoningSummarizing {
    let isReady: Bool = false
    func feed(delta: String) {}
    func summarize() async -> ReasoningSummary? { nil }
    func reset() {}
}

#endif
