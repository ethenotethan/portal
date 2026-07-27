import Foundation

/// Adopted by any type that tracks LLM token consumption and cost.
/// Canonical field names follow the Anthropic API convention (input/output,
/// not prompt/completion). `totalTokens` is a derived convenience; conforming
/// types may store it or compute it — the protocol only requires a getter.
internal protocol TokenAccountable {
    var inputTokens: Int? { get }
    var outputTokens: Int? { get }
    var costUSD: Double? { get }
    var totalTokens: Int? { get }
}

/// Adopted by any type that represents a single tool invocation record.
/// `context` is the preview text surfaced at tool.start (what the tool is
/// about to do); `summary` is the human-readable result from tool.complete.
internal protocol ToolCallRepresentable: Identifiable where ID == String {
    var id: String { get }
    var name: String { get }
    var context: String? { get }
    var summary: String? { get }
    var durationSeconds: Double? { get }
    var isComplete: Bool { get }
}
