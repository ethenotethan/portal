import SwiftUI

/// The "thinking" lens as a standalone panel: reasoning beats as a readable,
/// scrollable list of gists rather than diamonds on a time axis. Extracted so a
/// user can pop reasoning out of the flamechart and give it its own space —
/// exactly the composability the dashboard is for.
///
/// A beat's gist mirrors what the flamechart draws beside each diamond
/// (`context`, falling back to the first line of `summary`), so the two
/// surfaces read the same. Derived purely from the turn's nodes — no engine,
/// no timer — so any number of these panels is beachball-free.
internal struct ThinkingBeatsPanel: View {
    internal let nodes: [ThoughtGraphNode]
    /// The local reasoning model is summarizing right now (heartbeat).
    internal var isThinking: Bool = false

    private var beats: [ThoughtGraphNode] {
        nodes
            .filter { $0.category == .reasoning }
            .sorted { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
    }

    internal var body: some View {
        if beats.isEmpty && !isThinking {
            PanelEmptyState(icon: "brain", message: "No thinking recorded this turn")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(beats.enumerated()), id: \.element.id) { index, beat in
                        beatRow(index: index, beat: beat)
                    }
                    if isThinking {
                        thinkingHeartbeat
                    }
                }
                .padding(10)
            }
        }
    }

    private func beatRow(index: Int, beat: ThoughtGraphNode) -> some View {
        HStack(alignment: .top, spacing: 8) {
            // A small diamond glyph ties the row back to the flamechart marker.
            Image(systemName: "diamond.fill")
                .font(.system(size: 7))
                .foregroundStyle(Theme.graphReasoning)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(gist(beat))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = secondaryLine(beat) {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var thinkingHeartbeat: some View {
        HStack(spacing: 6) {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.graphReasoning)
                .symbolEffect(.variableColor.iterative, options: .repeating)
            Text("thinking…")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.secondary)
        }
        .padding(.top, 2)
    }

    /// The beat's headline gist — the extracted decision label, else the first
    /// line of its summary. Matches the flamechart's `reasoningLabel`.
    private func gist(_ node: ThoughtGraphNode) -> String {
        let raw = node.context ?? node.summary?.components(separatedBy: "\n").first
        let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? "(thinking)" : text
    }

    /// A second line only when the summary adds something beyond the gist.
    private func secondaryLine(_ node: ThoughtGraphNode) -> String? {
        guard let summary = node.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
              !summary.isEmpty, summary != gist(node) else { return nil }
        return summary
    }
}

/// Shared empty-state for the small list panels, so they read consistently.
internal struct PanelEmptyState: View {
    internal let icon: String
    internal let message: String

    internal var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(Theme.tertiary)
            Text(message)
                .font(.caption)
                .foregroundStyle(Theme.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(12)
    }
}
