import Foundation
import os

#if canImport(MLXLLM) && canImport(MLXLMCommon) && canImport(HuggingFace) && canImport(Tokenizers)
@preconcurrency import MLXLLM
@preconcurrency import MLXLMCommon
import HuggingFace
import Tokenizers
#endif

private let log = Logger(subsystem: "com.researchoors.HermesNative", category: "SkillSummaryService")

enum SkillSummaryError: LocalizedError {
    case modelUnavailable
    case modelLoadFailed(String)
    case emptyResponse
    var errorDescription: String? {
        switch self {
        case .modelUnavailable: return "Local summarization model is unavailable"
        case .modelLoadFailed(let detail): return detail
        case .emptyResponse: return "Model returned an empty summary"
        }
    }
}

/// Generates and caches concise on-device summaries of skill SKILL.md files
/// using the same MLX Gemma 3 1B model as MLXReasoningSummarizer.
@MainActor
final class SkillSummaryService {
    static let shared = SkillSummaryService()

    enum SummaryState: Equatable {
        case idle
        case generating
        case ready(String)
        case failed(String)
    }

    struct CacheEntry: Codable {
        let contentHash: Int
        let summary: String
        let generatedAt: Date
    }

    private(set) var isModelReady = false
    private(set) var modelLoadError: String?
    private var cache: [String: CacheEntry]?
    private var generationQueue: Task<Void, Never>?

    private init() {}

    /// Begin loading the local model in the background (download on first
    /// use, then cached on disk). Safe to call repeatedly.
    ///
    /// macOS only: mlx-swift-lm compiles for iOS too (canImport passes), but
    /// keeping a ~600MB model resident blows through iOS's jetsam budget and
    /// gets the app killed mid-session — which reads as random crashes. iOS
    /// uses the extractive fallback instead.
    func warmUp() {
#if canImport(MLXLLM) && canImport(MLXLMCommon) && canImport(HuggingFace) && canImport(Tokenizers) && os(macOS)
        Task { await ensureLoaded() }
#endif
    }

    /// Await the local model being loaded (downloading on first use). On
    /// platforms/builds without MLX this returns immediately. Used by
    /// background pregeneration so it doesn't fire many generations before
    /// the model is ready.
    func prepareModel() async {
#if canImport(MLXLLM) && canImport(MLXLMCommon) && canImport(HuggingFace) && canImport(Tokenizers) && os(macOS)
        await ensureLoaded()
#endif
    }

    /// True when a summary for this skill+content is already on disk.
    func hasCachedSummary(name: String, markdown: String) -> Bool {
        cachedSummary(name: name, markdown: markdown) != nil
    }

    // MARK: - Cache

    private static var cacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: "/tmp")
        return base
            .appendingPathComponent("HermesNative", isDirectory: true)
            .appendingPathComponent("skill-summaries.json")
    }

    func cachedSummary(name: String, markdown: String) -> String? {
        loadCacheIfNeeded()
        guard let entry = cache?[name], entry.contentHash == Self.stableHash(markdown) else { return nil }
        return entry.summary
    }

    private func loadCacheIfNeeded() {
        guard cache == nil else { return }
        if let data = try? Data(contentsOf: Self.cacheURL),
           let decoded = try? JSONDecoder().decode([String: CacheEntry].self, from: data) {
            cache = decoded
        } else {
            cache = [:]
        }
    }

    private func store(name: String, markdown: String, summary: String) {
        loadCacheIfNeeded()
        cache?[name] = CacheEntry(contentHash: Self.stableHash(markdown), summary: summary, generatedAt: Date())
        persistCache()
    }

    private func persistCache() {
        guard let cache, let data = try? JSONEncoder().encode(cache) else { return }
        let url = Self.cacheURL
        Task.detached(priority: .background) {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                log.error("Failed to persist skill summaries: \(error.localizedDescription)")
            }
        }
    }

    /// Stable djb2 hash over UTF-8 — String.hashValue is per-process randomized.
    private static func stableHash(_ text: String) -> Int {
        var hash: UInt64 = 5381
        for byte in text.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return Int(bitPattern: UInt(truncatingIfNeeded: hash))
    }

    // MARK: - Summarize

    func summarize(name: String, markdown: String) async -> Result<String, Error> {
        if let cached = cachedSummary(name: name, markdown: markdown) {
            return .success(cached)
        }
        // Serialize generations: chain behind any in-flight request.
        let previous = generationQueue
        let task = Task<Result<String, Error>, Never> {
            _ = await previous?.value
            if let cached = self.cachedSummary(name: name, markdown: markdown) {
                return .success(cached)
            }
            return await self.generate(markdown: markdown)
        }
        generationQueue = Task { _ = await task.value }
        let result = await task.value
        if case .success(let summary) = result {
            store(name: name, markdown: markdown, summary: summary)
        }
        return result
    }

    // MARK: - Text Helpers

    static func stripFrontmatter(_ markdown: String) -> String {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("---") else { return trimmed }
        let lines = trimmed.components(separatedBy: "\n")
        for index in 1..<max(lines.count, 1) where lines[index].trimmingCharacters(in: .whitespaces) == "---" {
            return lines[(index + 1)...].joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    /// Instant non-AI preview: first non-heading paragraph of the body, ≤280 chars.
    static func extractiveFallback(markdown: String) -> String? {
        let body = stripFrontmatter(markdown)
        for paragraph in body.components(separatedBy: "\n\n") {
            let lines = paragraph.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("```") }
            let text = lines.joined(separator: " ")
            guard text.count >= 20 else { continue }
            return String(text.prefix(280))
        }
        return nil
    }

    private static func cleanResponse(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["Summary:", "summary:", "Here is a summary:", "Here's a summary:", "Here is the summary:"]
        for prefix in prefixes where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.replacingOccurrences(of: "**", with: "")
    }

    // MARK: - MLX Generation

#if canImport(MLXLLM) && canImport(MLXLMCommon) && canImport(HuggingFace) && canImport(Tokenizers)

    private var session: ChatSession?
    private var loadTask: Task<Void, Never>?

    private static let summaryPrompt = """
You summarize agent skill definitions. Write 2-3 plain sentences describing \
what the skill does, when it triggers, and what it produces. \
No markdown, no lists, no preamble — output only the sentences.

Skill definition:

"""

    private func generate(markdown: String) async -> Result<String, Error> {
        await ensureLoaded()
        guard isModelReady, let session else {
            let detail = modelLoadError.map { "Model load failed: \($0)" }
            return .failure(SkillSummaryError.modelLoadFailed(detail ?? "Local summarization model is unavailable"))
        }
        let body = String(Self.stripFrontmatter(markdown).prefix(3000))
        let prompt = Self.summaryPrompt + body
        do {
            // Run MLX inference OFF the main actor. This service is @MainActor,
            // so `await session.respond(...)` would otherwise execute the heavy
            // tensor/Metal compute on the main thread and beachball the UI
            // (observed: thousands of mlx::core frames on the main thread,
            // ~150% CPU). Detaching moves the work to a background thread; the
            // ChatSession is a reference type so it's safe to use there.
            let response = try await Task.detached(priority: .utility) { [session] in
                try await session.respond(to: prompt)
            }.value
            let cleaned = Self.cleanResponse(response)
            guard !cleaned.isEmpty else { return .failure(SkillSummaryError.emptyResponse) }
            return .success(cleaned)
        } catch {
            log.warning("Skill summarization failed: \(error.localizedDescription)")
            return .failure(error)
        }
    }

    private func ensureLoaded() async {
        #if os(iOS)
        // Never load the ~600MB MLX model on iOS — it blows the jetsam budget
        // and gets the app killed (reads as random crashes). generate() then
        // fails over to the extractive summary path.
        modelLoadError = "On-device model disabled on iOS (memory budget)"
        return
        #else
        if isModelReady { return }
        if loadTask != nil { await loadTask?.value; return }

        loadTask = Task {
            do {
                let container = try await LLMModelFactory.shared.loadContainer(
                    from: HFHubDownloader(),
                    using: HFTokenizerLoaderWrapper(),
                    configuration: LLMRegistry.gemma3_1B_qat_4bit
                )
                self.session = ChatSession(container)
                self.isModelReady = true
                self.modelLoadError = nil
                log.info("MLX Gemma 3 1B loaded for skill summaries")
            } catch {
                log.error("MLX model load failed: \(error.localizedDescription)")
                self.isModelReady = false
                self.modelLoadError = error.localizedDescription
            }
            self.loadTask = nil
        }
        await loadTask?.value
        #endif
    }

#else

    private func generate(markdown: String) async -> Result<String, Error> {
        .failure(SkillSummaryError.modelUnavailable)
    }

#endif
}
