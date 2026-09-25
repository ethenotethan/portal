import Foundation

/// A system flow as Mermaid source: the same sequence diagram the web
/// observatory draws for a flow, generated from its validated steps so it can
/// only show wiring the map has. Participants are the constructions (and page
/// pseudo-nodes) the steps touch, in order of first appearance; messages are the
/// steps, numbered; asynchronous relations draw as dashed arrows.
///
/// Pure text work, deterministic, and defensive about Mermaid's syntax: labels
/// drop the characters its parser treats as structure.
internal enum ArchitectureSystemMapFlowDiagram {
    /// Relations drawn with a dashed (asynchronous) arrow, as on the web.
    internal static let asynchronousRelations: Set<String> = ["notifies", "provides", "publish", "declares", "replays-into", "persists-to"]

    private static let unsafe = CharacterSet(charactersIn: ";:#<>\"`")

    /// Mermaid-safe label text: structural characters become spaces, runs of
    /// whitespace collapse, ends are trimmed. Empty input stays empty.
    internal static func label(_ text: String) -> String {
        let replaced = String(text.unicodeScalars.map { unsafe.contains($0) ? " " : Character($0) })
        return replaced.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// What a step endpoint is called in the diagram: the construction's label,
    /// "User on <page>" for a page pseudo-node ("App entry points" at launch),
    /// or the last segment of an unresolved reference.
    internal static func participantLabel(for reference: String, document: ArchitectureSystemMapDocument) -> String {
        switch document.resolve(stepEndpoint: reference) {
        case .node(let id):
            return document.node(id: id)?.label ?? reference
        case .page(let page):
            if page == "launch" { return "App entry points" }
            let name = document.pages.first { $0.id == page }?.label ?? page
            return "User on \(name)"
        case .unknown(let raw):
            return raw.split(separator: ":").last.map(String.init) ?? raw
        }
    }

    /// The message text for a step: the relation with hyphens as spaces, then
    /// the note when there is one.
    internal static func messageText(for step: ArchitectureFlowStep) -> String {
        var text = step.relation.replacingOccurrences(of: "-", with: " ")
        if !step.note.isEmpty { text += " · \(step.note)" }
        return text
    }

    /// The whole diagram. A flow with no steps is a bare, valid sequence diagram.
    internal static func mermaid(for flow: ArchitectureFlow, document: ArchitectureSystemMapDocument) -> String {
        var aliases: [String: String] = [:]
        var participants: [(alias: String, label: String)] = []
        func alias(for reference: String) -> String {
            if let existing = aliases[reference] { return existing }
            let name = "p\(participants.count)"
            aliases[reference] = name
            participants.append((name, participantLabel(for: reference, document: document)))
            return name
        }
        var messages: [String] = []
        for step in flow.steps {
            let from = alias(for: step.from)
            let to = alias(for: step.to)
            let arrow = asynchronousRelations.contains(step.relation) ? "-->>" : "->>"
            let text = label(messageText(for: step))
            messages.append("  \(from)\(arrow)\(to): \(text.isEmpty ? "step" : text)")
        }
        var lines = ["sequenceDiagram", "  autonumber"]
        lines += participants.map { "  participant \($0.alias) as \(label($0.label).isEmpty ? $0.alias : label($0.label))" }
        lines += messages
        return lines.joined(separator: "\n")
    }
}
