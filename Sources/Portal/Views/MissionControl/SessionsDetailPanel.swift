#if os(macOS)
import SwiftUI

/// Inline session inspector — shows metadata and run-state for whatever session
/// is selected in `SessionsFilterState.selectedSessionID`. Clicking a card in
/// the list or a bar in the timeline sets that ID; this panel responds instantly.
@MainActor
internal struct SessionsDetailPanel: View {
    @EnvironmentObject private var filterState: SessionsFilterState
    @EnvironmentObject private var sessionList: SessionListViewModel

    internal var onOpenSession: ((String) -> Void)?

    private var session: Session? {
        guard let id = filterState.selectedSessionID else { return nil }
        return sessionList.sessions.first { $0.id == id }
    }

    internal var body: some View {
        Group {
            if let s = session {
                detail(s)
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    // MARK: - Placeholder

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "cursorarrow.click")
                .font(.system(size: 28))
                .foregroundStyle(Theme.tertiary)
            Text("Select a session")
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
            Text("Click a card in the list or a bar in the timeline to inspect it here.")
                .font(.caption)
                .foregroundStyle(Theme.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Detail

    private func detail(_ s: Session) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(s)
                Divider().overlay(Theme.border.opacity(0.5))
                metadataGrid(s)
                if let preview = s.preview, !preview.isEmpty {
                    Divider().overlay(Theme.border.opacity(0.5))
                    previewSection(preview)
                }
                if !s.tags.isEmpty {
                    Divider().overlay(Theme.border.opacity(0.5))
                    tagsSection(s.tags)
                }
                actions(s)
            }
            .padding(16)
        }
    }

    private func header(_ s: Session) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(statusColor(s).opacity(0.12))
                    .frame(width: 38, height: 38)
                statusIcon(s)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(sessionList.titleForSession(s))
                    .font(.headline)
                    .foregroundStyle(Theme.primary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    statusBadge(s)
                    if let src = s.source {
                        Text(src.uppercased())
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .monospaced()
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Theme.accent.opacity(0.12), in: Capsule())
                    }
                }
            }
            Spacer()
            Button { filterState.selectedSessionID = nil } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.tertiary)
                    .frame(width: 20, height: 20)
                    .background(Theme.surface, in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private func metadataGrid(_ s: Session) -> some View {
        let rows: [(String, String)] = [
            ("Session ID", String(s.id.prefix(16))),
            ("Messages", "\(s.messageCount)"),
            ("Started", s.startedAt.map { formatDate($0) } ?? "—"),
            ("Last active", s.lastActive.map { $0.relativeString } ?? "—"),
            ("Duration", durationString(s)),
            ("Run state", s.displayRunState.displayName),
        ]
        return VStack(alignment: .leading, spacing: 8) {
            Text("Details")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.tertiary)
                .textCase(.uppercase)
            ForEach(rows, id: \.0) { row in
                HStack(alignment: .top) {
                    Text(row.0)
                        .font(.caption)
                        .foregroundStyle(Theme.tertiary)
                        .frame(width: 90, alignment: .leading)
                    Text(row.1)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(2)
                    Spacer()
                }
            }
        }
    }

    private func previewSection(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Preview")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.tertiary)
                .textCase(.uppercase)
            Text(text)
                .font(.caption)
                .foregroundStyle(Theme.secondary)
                .lineLimit(6)
                .padding(10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func tagsSection(_ tags: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tags")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.tertiary)
                .textCase(.uppercase)
            FlowLayout(spacing: 4) {
                ForEach(tags, id: \.self) { tag in
                    Text(tag)
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Theme.accent.opacity(0.12), in: Capsule())
                }
            }
        }
    }

    private func actions(_ s: Session) -> some View {
        HStack(spacing: 8) {
            Button {
                onOpenSession?(s.id)
            } label: {
                Label("Open", systemImage: "arrow.up.right.square")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 7))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            if s.isOwned {
                Button {
                    sessionList.selectSession(id: s.id)
                } label: {
                    Label("Chat", systemImage: "bubble.left.and.bubble.right")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 7))
                        .foregroundStyle(Theme.primary)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Helpers

    private func statusColor(_ s: Session) -> Color {
        if s.isLive { return Theme.success }
        if s.displayRunState == .failed { return .red }
        return Theme.tertiary
    }

    @ViewBuilder
    private func statusIcon(_ s: Session) -> some View {
        if s.isLive {
            PulsingDot(color: Theme.success).frame(width: 12, height: 12)
        } else if s.displayRunState == .failed {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
        } else {
            Image(systemName: "circle").foregroundStyle(Theme.tertiary).font(.callout)
        }
    }

    private func statusBadge(_ s: Session) -> some View {
        let (label, color): (String, Color) = s.isLive
            ? (s.displayRunState.displayName, Theme.success)
            : ("Ended", Theme.tertiary)
        return Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }

    private func durationString(_ s: Session) -> String {
        guard let start = s.startedAt else { return "—" }
        let end = s.endedAt ?? s.lastActive ?? Date()
        let t = end.timeIntervalSince(start)
        if t < 60 { return "\(Int(t))s" }
        if t < 3_600 { return "\(Int(t / 60))m" }
        let h = Int(t / 3_600)
        let m = Int(t.truncatingRemainder(dividingBy: 3_600) / 60)
        return m > 0 ? "\(h)h \(m)m" : "\(h)h"
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: date)
    }
}

#endif
