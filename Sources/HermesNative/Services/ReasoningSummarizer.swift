import Foundation
import os

private let log = Logger(subsystem: "com.researchoors.HermesNative", category: "ReasoningSummarizer")

// MARK: - Summarization Result

struct ReasoningDecision: Codable, Sendable {
    let id: String
    let label: String
    let reasoning: String
    let options: [String]
}

struct ReasoningSummary: Codable, Sendable {
    let decisions: [ReasoningDecision]
    let summary: String?
}

// MARK: - Reasoning Summarizer Protocol

protocol ReasoningSummarizing: AnyObject {
    @MainActor var isReady: Bool { get }
    @MainActor func feed(delta: String)
    @MainActor func summarize() async -> ReasoningSummary?
    @MainActor func reset()
}

// MARK: - Heuristic Summarizer (Pattern-Based)

final class HeuristicReasoningSummarizer: ReasoningSummarizing {
    @MainActor var isReady: Bool = true
    private var buffer: String = ""

    @MainActor func feed(delta: String) { buffer += delta }

    @MainActor func summarize() async -> ReasoningSummary? {
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let decisions = extractDecisions(from: text)
        buffer = ""
        if decisions.isEmpty { return nil }
        return ReasoningSummary(decisions: decisions, summary: nil)
    }

    @MainActor func reset() { buffer = "" }

    private func extractDecisions(from text: String) -> [ReasoningDecision] {
        var results: [ReasoningDecision] = []
        var counter = 0
        func nextID(_ prefix: String) -> String { counter += 1; return "\(prefix)-\(counter)-\(UUID().uuidString.prefix(6))" }

        // Pattern 1: "I..." decisions — "I should", "I'll", "I need to", "Let me", "I will"
        let choicePattern = try? NSRegularExpression(
            pattern: "(?:I (?:should|will|decided to|could|might|need to|"
                + "want to|can|would|'ll|recommend|suggest|think|believe|suspect))"
                + "\\s*(.+?)(?:\\s*(?:instead of|rather than|over|versus|"
                + "vs\\.?|or)\\s*(.+?))?(?:\\s*(?:because|since|as|due to|"
                + "given that)\\s*(.+?))?[.!]|(?:Let me|I'll|I will)\\s*"
                + "(.+?)[.!]|(?:choose|pick|opt for|go with|prefer)\\s*"
                + "(.+?)(?:\\s*(?:over|instead of|rather than|versus|vs\\.?)"
                + "\\s*(.+?))?",
            options: [.caseInsensitive]
        )
        if let pattern = choicePattern {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in pattern.matches(in: text, range: range) {
                let nsText = text as NSString
                var choice = ""
                var alternative: String?
                var because: String?
                if match.range(at: 1).location != NSNotFound { choice = nsText.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces) }
                if match.range(at: 4).location != NSNotFound { choice = nsText.substring(with: match.range(at: 4)).trimmingCharacters(in: .whitespaces) }
                if choice.isEmpty { continue }
                if match.range(at: 2).location != NSNotFound { alternative = nsText.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces) }
                if match.range(at: 3).location != NSNotFound { because = nsText.substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespaces) }
                if match.range(at: 5).location != NSNotFound { choice = nsText.substring(with: match.range(at: 5)).trimmingCharacters(in: .whitespaces) }
                if match.range(at: 6).location != NSNotFound { alternative = nsText.substring(with: match.range(at: 6)).trimmingCharacters(in: .whitespaces) }

                let label = alternative.map { "\(choice) vs \($0)" } ?? choice
                var options = [choice]; if let alt = alternative { options.append(alt) }
                results.append(ReasoningDecision(
                    id: nextID("decision"), label: String(label.prefix(80)),
                    reasoning: because ?? choice, options: options))
            }
        }
        if results.isEmpty {
            let stepPattern = try? NSRegularExpression(
                pattern: "(?:Step|Phase|Stage)\\s*(\\d+)[:.)]\\s*"
                    + "(.+?)(?=(?:Step|Phase|Stage)\\s*\\d+|$)",
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            )
            if let pattern = stepPattern {
                let r = NSRange(text.startIndex..<text.endIndex, in: text)
                if pattern.matches(in: text, range: r).count >= 2 {
                    for m in pattern.matches(in: text, range: r) {
                        let s = (text as NSString).substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\n", with: " ")
                        results.append(ReasoningDecision(id: nextID("step"), label: String(s.prefix(80)), reasoning: s, options: []))
                    }
                }
            }
        }
        if results.isEmpty {
            let tradeoffPattern = try? NSRegularExpression(
                pattern: "(?:pros?:|advantages?:|benefits?:)\\s*"
                    + "(.+?)(?:cons?:|disadvantages?:|drawbacks?:|"
                    + "however|but|on the other hand)",
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            )
            if let pattern = tradeoffPattern,
               let m = pattern.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) {
                let pro = (text as NSString).substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                results.append(ReasoningDecision(id: nextID("tradeoff"), label: "Trade-off analysis", reasoning: String(pro.prefix(120)), options: []))
            }
        }
        if results.isEmpty, let firstLine = text.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            let cleaned = firstLine.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "##", with: "")
                .replacingOccurrences(of: "###", with: "")
            if cleaned.count >= 10 {
                results.append(ReasoningDecision(
                    id: nextID("reason"),
                    label: String(cleaned.prefix(80)),
                    reasoning: String(text.prefix(200)),
                    options: []
                ))
            }
        }
        return results
    }
}

// MARK: - MLX-Powered Summarizer (Apple Silicon)

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

/// MLX-accelerated summarizer using Gemma 3 1B 4-bit on Apple Silicon.
/// Model downloads from HuggingFace on first use (~600MB, cached).
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
- Only extract explicit decisions or analysis. If none, return empty array.
- Labels must be <80 chars.
- Use the EXACT JSON format shown.

{"decisions":[{"id":"d1","label":"Choose X over Y","reasoning":"X is faster than Y","options":["X","Y"]}],"summary":null}

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
