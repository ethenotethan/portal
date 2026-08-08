import Foundation
import os

private let log = Logger(subsystem: "com.ethenotethan.Portal", category: "ReasoningGraphIntegrator")

// MARK: - Reasoning Graph Integrator

/// Bridges reasoning summarization results into `ThoughtGraphNode` entities
/// that render alongside tool-call nodes in the agent thought graph visualization.
///
/// Reasoning-derived nodes are visually differentiated from tool-call nodes
/// via a distinct `"reasoning"` tool-name prefix.
final class ReasoningGraphIntegrator: ObservableObject {

    /// Reasoning-derived decision nodes, keyed by decision ID.
    @Published var reasoningNodes: [ThoughtGraphNode] = []

    /// True while the summarizer is actively running (model loading or
    /// inferring) — drives the "thinking…" heartbeat in the graph so you can
    /// see the local model working before a deduction lands.
    @Published internal var isThinking: Bool = false

    private let summarizer: any ReasoningSummarizing
    private var deltaBuffer: String = ""
    private var summarizationTask: Task<Void, Never>?
    private var idCounter = 0

    init(summarizer: any ReasoningSummarizing = HeuristicReasoningSummarizer()) {
        self.summarizer = summarizer
    }

    // MARK: - Public API

    @MainActor
    func feed(delta: String) {
        deltaBuffer += delta

        let shouldSummarize =
            deltaBuffer.count >= 100

        guard shouldSummarize else { return }

        scheduleSummarization()
    }

    @MainActor
    func finalize() async {
        summarizationTask?.cancel()
        await processBuffer()
    }

    @MainActor
    func reset() {
        summarizationTask?.cancel()
        summarizationTask = nil
        deltaBuffer = ""
        reasoningNodes = []
        idCounter = 0
        isThinking = false
    }

    // MARK: - Private

    @MainActor
    private func scheduleSummarization() {
        summarizationTask?.cancel()
        summarizationTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            await self.processBuffer()
        }
    }

    @MainActor
    private func processBuffer() async {
        let chunk = deltaBuffer
        deltaBuffer = ""
        guard !chunk.isEmpty else { return }

        isThinking = true
        defer { isThinking = false }

        summarizer.feed(delta: chunk)
        guard let summary = await summarizer.summarize() else { return }
        summarizer.reset()

        // Filter out template/placeholder values that the MLX model echoes
        // from its few-shot example when it finds no real decisions.
        let placeholderLabels: Set<String> = [
            "choose x over y",
            "choose x over y.",
        ]
        let placeholderReasons: Set<String> = [
            "x is faster than y",
        ]

        let filtered = summary.decisions.filter { decision in
            let lowerLabel = decision.label.lowercased().trimmingCharacters(in: .whitespaces)
            let lowerReason = decision.reasoning.lowercased().trimmingCharacters(in: .whitespaces)
            let isPlaceholder = placeholderLabels.contains(lowerLabel)
                || placeholderReasons.contains(lowerReason)
            if isPlaceholder {
                log.debug("Skipping placeholder reasoning decision: \(decision.label)")
            }
            return !isPlaceholder
        }

        for decision in filtered {
            idCounter += 1
            let nodeID = "reasoning-\(decision.id)"
            let parentIDs = reasoningNodes.last.map { [$0.id] } ?? []
            let node = ThoughtGraphNode(
                id: nodeID,
                name: "reasoning",
                context: decision.label,
                summary: decision.reasoning,
                isComplete: true,
                depth: reasoningNodes.count,
                parentIDs: parentIDs,
                startedAt: Date(),
                completedAt: Date(),
                role: .reasoning
            )
            reasoningNodes.append(node)
        }

        if !reasoningNodes.isEmpty {
            log.debug("Extracted reasoning nodes from summarization")
        }
    }
}
