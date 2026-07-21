import SwiftUI

// MARK: - Session Event Log View

/// The Explorer's "Events" tab: the RAW wire-event log for backends that
/// expose one (`RawEventLogProviding` — Centaur SSE today). Frontend parity
/// with Centaur's own web console: one row per SSE event with its id, event
/// name, and timestamp, expanding to the pretty-printed payload — for
/// `session.output.line` NDJSON harness frames, the inner protocol method
/// leads and the raw JSON stays collapsible underneath.
struct SessionEventLogView: View {
    let sessionID: String
    let provider: any RawEventLogProviding

    @State private var events: [RawSessionEvent] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var expandedEventID: Int64?

    var body: some View {
        Group {
            if isLoading {
                HermesProgressView(label: "Replaying event log…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = loadError {
                eventLogEmptyState(icon: "exclamationmark.triangle", title: "Cannot Load Event Log",
                                   subtitle: error)
            } else if events.isEmpty {
                eventLogEmptyState(icon: "list.bullet.rectangle", title: "No Events",
                                   subtitle: "This session's event log is empty. Events appear once the harness produces output.")
            } else {
                logList
            }
        }
        .task(id: sessionID) { await load() }
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    header
                    ForEach(events) { event in
                        RawEventRow(
                            event: event,
                            isExpanded: expandedEventID == event.id,
                            onTap: {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    expandedEventID = expandedEventID == event.id ? nil : event.id
                                }
                            }
                        )
                        .id(event.id)
                    }
                }
                .padding(12)
            }
            .onAppear {
                if let last = events.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("\(events.count) events")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.secondary)
            Spacer()
            Button {
                Task { await load(force: true) }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.bottom, 4)
    }

    private func load(force: Bool = false) async {
        if !force, !events.isEmpty { return }  // re-entrant .task on tab switch
        isLoading = true
        loadError = nil
        do {
            events = try await provider.rawEventLog(sessionID: sessionID, afterEventID: 0)
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func eventLogEmptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
    }
}

// MARK: - Raw Event Row

/// One raw wire event: collapsed shows id + event name (+ harness method for
/// output lines) + timestamp; expanded adds the pretty-printed payload in a
/// monospaced, selectable block.
private struct RawEventRow: View {
    let event: RawSessionEvent
    let isExpanded: Bool
    var onTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            rowContent
            if isExpanded {
                payloadCard
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var rowContent: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                // SSE event id
                Text("#\(event.id)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.tertiary)
                    .frame(width: 52, alignment: .trailing)

                Image(systemName: iconName)
                    .font(.caption)
                    .foregroundStyle(eventColor)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(event.name)
                            .font(.caption.monospaced())
                            .foregroundStyle(Theme.primary)
                            .lineLimit(1)
                        if let method = event.harnessMethod {
                            Text(method)
                                .font(.caption2.monospaced())
                                .foregroundStyle(eventColor)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(eventColor.opacity(0.12), in: Capsule())
                                .lineLimit(1)
                        }
                    }
                    if let preview = payloadPreview {
                        Text(preview)
                            .font(.caption2.monospaced())
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if let timestamp = event.timestamp {
                    Text(timestamp.formatted(date: .omitted, time: .standard))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Theme.tertiary)
                }

                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isExpanded ? Theme.accent.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private var payloadCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let method = event.harnessMethod {
                HStack(spacing: 8) {
                    Text("method")
                        .font(.caption2)
                        .foregroundStyle(Theme.tertiary)
                    Text(method)
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.primary)
                        .textSelection(.enabled)
                    Spacer()
                    copyButton
                }
            } else {
                HStack {
                    Spacer()
                    copyButton
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(event.prettyPayload.isEmpty ? "(no payload)" : event.prettyPayload)
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(eventColor.opacity(0.3), lineWidth: 1)
        )
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
    }

    private var copyButton: some View {
        Button {
            #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(event.payload, forType: .string)
            #else
            UIPasteboard.general.string = event.payload
            #endif
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.caption)
                .foregroundStyle(Theme.accent)
        }
        .buttonStyle(.plain)
        .help("Copy raw payload")
    }

    private var payloadPreview: String? {
        let flattened = event.payload
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !flattened.isEmpty, flattened != "{}" else { return nil }
        return String(flattened.prefix(120))
    }

    private var iconName: String {
        switch event.name {
        case "session.execution_started": return "play.circle"
        case "session.execution_completed": return "checkmark.circle"
        case "session.execution_failed": return "xmark.circle"
        case "session.execution_cancelled": return "stop.circle"
        case "session.output.line": return "text.alignleft"
        case "session.first_token": return "sparkle"
        case "session.stream_error": return "exclamationmark.triangle"
        default: return "circle.dashed"
        }
    }

    private var eventColor: Color {
        switch event.name {
        case "session.execution_started": return Theme.accent
        case "session.execution_completed": return Theme.success
        case "session.execution_failed", "session.stream_error": return .red
        case "session.execution_cancelled": return Theme.warning
        case "session.output.line": return harnessMethodColor
        default: return Theme.secondary
        }
    }

    /// Output lines take their tint from the inner harness method so the log
    /// scans like Centaur's console: deltas read as content, item lifecycle
    /// as tooling, errors as errors.
    private var harnessMethodColor: Color {
        switch event.harnessMethod {
        case "item/agentMessage/delta": return Theme.graphWrite
        case "error": return .red
        case .some(let method) where method.hasPrefix("item/reasoning") || method.hasPrefix("item/plan"):
            return Theme.graphReasoning
        case .some(let method) where method.hasPrefix("item/"):
            return Theme.graphTerminal
        case .some, .none:
            return Theme.secondary
        }
    }
}
