import SwiftUI

// MARK: - PlaybackEventRow

/// A single event row in the session playback timeline.
///
/// Displays the event's relative timestamp, type icon, content preview,
/// and optional duration/token badges. Colored by event type.
/// Tapping expands to show full content details.
struct PlaybackEventRow: View {

    // MARK: - Input

    let event: SessionTimelineEvent
    let firstTimestamp: TimeInterval
    let isSelected: Bool
    var onTap: () -> Void = {}

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            rowContent

            if isSelected {
                detailCard
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: - Row Content

    private var rowContent: some View {
        let relativeTime = event.timestamp.timeIntervalSince1970 - firstTimestamp
        let eventColor = Color(hex: event.type.colorHex) ?? Theme.secondary

        return Button(action: onTap) {
            HStack(spacing: 10) {
                // Time indicator
                Text(formatRelativeTime(relativeTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.tertiary)
                    .frame(width: 60, alignment: .trailing)

                // Event type icon
                Image(systemName: event.type.iconName)
                    .font(.caption)
                    .foregroundStyle(eventColor)
                    .frame(width: 20)

                // Content preview
                VStack(alignment: .leading, spacing: 2) {
                    Text(eventDisplayTitle)
                        .font(.caption)
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)

                    if let preview = eventContentPreview {
                        Text(preview)
                            .font(.caption2)
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                // Badges
                HStack(spacing: 6) {
                    if event.type == .toolEnd, let durMs = event.durationMs {
                        badgeLabel(
                            text: formatDurationMs(durMs),
                            color: Color(hex: EventType.toolEnd.colorHex) ?? .green
                        )
                    }

                    if let tokens = event.tokenCount, tokens > 0 {
                        badgeLabel(
                            text: formatTokensCompact(tokens) + " tok",
                            color: Theme.accent
                        )
                    }
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Theme.accent.opacity(0.12) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Theme.accent.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Detail Card

    private var detailCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                Image(systemName: event.type.iconName)
                    .foregroundStyle(Color(hex: event.type.colorHex) ?? Theme.accent)
                Text(eventTypeLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.primary)
                Spacer()

                Button {
                    copyEventContent()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .help("Copy content")
            }

            // Tool-specific info
            if let toolName = event.toolName {
                detailRow(label: "Tool", value: toolName)
            }
            if let toolID = event.toolID {
                detailRow(label: "Tool ID", value: toolID)
            }
            if let durationMs = event.durationMs {
                detailRow(label: "Duration", value: formatDurationMs(durationMs))
            }
            if let tokenCount = event.tokenCount, tokenCount > 0 {
                detailRow(label: "Tokens", value: formatTokensCompact(tokenCount))
            }
            if let summary = event.summary, !summary.isEmpty {
                detailRow(label: "Summary", value: summary)
            }

            // Full content
            if let content = event.content, !content.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Content")
                        .font(.caption2)
                        .foregroundStyle(Theme.tertiary)
                    Text(content)
                        .font(.caption)
                        .foregroundStyle(Theme.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(Theme.surfaceHover.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    Color(hex: event.type.colorHex)?.opacity(0.3) ?? Theme.accent.opacity(0.3),
                    lineWidth: 1
                )
        )
        .padding(.horizontal, 4)
    }

    // MARK: - Copy

    private func copyEventContent() {
        var parts: [String] = []
        if let content = event.content, !content.isEmpty {
            parts.append(content)
        }
        if let summary = event.summary, !summary.isEmpty {
            parts.append("Summary: \(summary)")
        }
        if let toolName = event.toolName {
            parts.append("Tool: \(toolName)")
        }

        let text = parts.joined(separator: "\n")
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    // MARK: - Computed Display Properties

    private var eventDisplayTitle: String {
        switch event.type {
        case .userMessage:
            return "User"
        case .assistantMessage:
            return "Assistant"
        case .toolStart:
            return event.toolName.map { "▶ \($0)" } ?? "Tool Call"
        case .toolEnd:
            return event.toolName.map { "✓ \($0)" } ?? "Tool Finished"
        case .reasoningBlock:
            return "Reasoning"
        case .turnBoundary:
            return "—"
        }
    }

    private var eventTypeLabel: String {
        switch event.type {
        case .userMessage:      return "User Message"
        case .assistantMessage: return "Assistant Message"
        case .toolStart:        return "Tool Call Started"
        case .toolEnd:          return "Tool Call Completed"
        case .reasoningBlock:   return "Reasoning Block"
        case .turnBoundary:     return "Turn Boundary"
        }
    }

    private var eventContentPreview: String? {
        switch event.type {
        case .toolStart, .toolEnd:
            if let summary = event.summary, !summary.isEmpty {
                return String(summary.prefix(80))
            }
            if let content = event.content, !content.isEmpty {
                return String(content.prefix(80))
            }
            return nil
        case .userMessage, .assistantMessage:
            guard let content = event.content, !content.isEmpty else { return nil }
            return String(content.prefix(80))
        case .reasoningBlock:
            guard let content = event.content, !content.isEmpty else { return nil }
            return String(content.prefix(80))
        case .turnBoundary:
            return nil
        }
    }

    // MARK: - Helpers

    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.tertiary)
                .frame(width: 55, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(Theme.primary)
                .textSelection(.enabled)
        }
    }

    private func badgeLabel(text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }

    // MARK: - Formatting

    private func formatRelativeTime(_ seconds: TimeInterval) -> String {
        String(format: "+%.1fs", seconds)
    }

    private func formatDurationMs(_ ms: Double) -> String {
        if ms < 1000 {
            return String(format: "%.0fms", ms)
        }
        return String(format: "%.1fs", ms / 1000)
    }

    private func formatTokensCompact(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    PlaybackEventRowPreviews.previews
}

enum PlaybackEventRowPreviews {
    static var previews: some View {
        PlaybackEventRowInternalPreview()
            .preferredColorScheme(.dark)
            .frame(width: 500)
            .padding()
    }
}

private struct PlaybackEventRowInternalPreview: View {
    @State private var selectedID: String?

    private let baseTimestamp = Date().timeIntervalSince1970 - 15.0

    private var mockEvent: SessionTimelineEvent {
        SessionTimelineEvent(
            id: "preview-1",
            type: .toolEnd,
            timestamp: Date(),
            content: "Successfully retrieved data from the API endpoint.",
            toolName: "fetch_api",
            toolID: "tool-1",
            durationMs: 1200,
            tokenCount: 42,
            summary: "Fetched 200 OK from /api/v2/data"
        )
    }

    var body: some View {
        VStack(spacing: 16) {
            PlaybackEventRow(
                event: mockEvent,
                firstTimestamp: baseTimestamp,
                isSelected: selectedID == mockEvent.id,
                onTap: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selectedID = (selectedID == mockEvent.id) ? nil : mockEvent.id
                    }
                }
            )

            // Also show a user message row for comparison
            PlaybackEventRow(
                event: SessionTimelineEvent(
                    id: "preview-2",
                    type: .userMessage,
                    timestamp: Date().addingTimeInterval(-5),
                    content: "What's the weather in Tokyo?",
                    toolName: nil,
                    toolID: nil,
                    durationMs: nil,
                    tokenCount: nil,
                    summary: nil
                ),
                firstTimestamp: baseTimestamp,
                isSelected: false
            )
        }
    }
}
#endif
