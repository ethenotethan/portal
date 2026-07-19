import SwiftUI

// MARK: - SessionPlaybackView

/// Full session playback view with a timeline chart, scrollable event list,
/// play/pause animation, search/filter, and export.
///
/// Layout (top → bottom):
///   1. Header HUD — summary stats (duration, tools, tokens, cost)
///   2. Search/filter bar
///   3. PlaybackTimelineChart — Gantt-style chart with selection binding
///   4. Event list — chronological list of non-boundary events
///   5. Detail card — slides up when an event is selected
struct SessionPlaybackView: View {
    let sessionID: String
    /// True when hosted as a tab inside SessionExplorerView — skips the
    /// NavigationStack/Done chrome that the standalone sheet needed.
    var isEmbedded = false
    @EnvironmentObject var gatewayClientWrapper: GatewayClientWrapper
    @Environment(\.dismiss) private var dismiss

    // MARK: - State

    @State private var timeline: SessionTimeline?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedEventID: String?
    @State private var isPlaying = false
    @State private var playheadIndex: Int = 0
    @State private var searchText = ""
    @State private var timeScale: Double = 1.0  // 0.5x–3x zoom
    @State private var showExportSheet = false

    // Playback timer
    private let playbackTimer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    // MARK: - Filtered Events

    private var visibleEvents: [SessionTimelineEvent] {
        guard let timeline else { return [] }
        let nonBoundary = timeline.events.filter { $0.type != .turnBoundary }
        guard !searchText.isEmpty else { return nonBoundary }
        let query = searchText.lowercased()
        return nonBoundary.filter { event in
            if let name = event.toolName, name.lowercased().contains(query) { return true }
            if let content = event.content, content.lowercased().contains(query) { return true }
            if let summary = event.summary, summary.lowercased().contains(query) { return true }
            return false
        }
    }

    // MARK: - Body

    var body: some View {
        if isEmbedded {
            // Tab inside SessionExplorerView — the Explorer owns the nav
            // chrome, so render bare content with an inline control row.
            VStack(spacing: 0) {
                embeddedControlBar
                playbackBody
            }
        } else {
            NavigationStack {
                playbackBody
                    .navigationTitle("Session Playback")
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { dismiss() }
                        }
                        ToolbarItem(placement: .primaryAction) {
                            playbackControls
                        }
                    }
            }
            .preferredColorScheme(.dark)
        }
    }

    private var playbackBody: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            Group {
                if isLoading {
                    loadingState
                } else if let error = errorMessage {
                    errorState(message: error)
                } else if let timeline, !timeline.events.isEmpty {
                    mainContent(timeline)
                } else {
                    emptyState
                }
            }
        }
        .task { await loadTimeline() }
        .onReceive(playbackTimer) { _ in
            guard isPlaying, !visibleEvents.isEmpty else { return }
            playheadIndex = (playheadIndex + 1) % visibleEvents.count
        }
        .sheet(isPresented: $showExportSheet) {
            if let timeline {
                ExportSheet(timeline: timeline) {
                    showExportSheet = false
                }
            }
        }
    }

    private var playbackControls: some View {
        HStack(spacing: 8) {
            // Export / Share
            Button {
                showExportSheet = true
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .help("Export timeline as text")
            .disabled(timeline == nil)

            // Play / Pause
            Button {
                togglePlayback()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            }
            .help(isPlaying ? "Pause" : "Play at 2x speed")
            .disabled(visibleEvents.isEmpty)
        }
    }

    private var embeddedControlBar: some View {
        HStack {
            Spacer()
            playbackControls
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    // MARK: - Main Content

    private func mainContent(_ timeline: SessionTimeline) -> some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(spacing: 0) {
                    // ── Header HUD ──
                    headerHUD(timeline)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 12)

                    // ── Search / Filter ──
                    searchBar
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)

                    // ── Chart ──
                    chartSection(timeline)

                    // ── Zoom indicator ──
                    if timeScale != 1.0 {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.caption2)
                            Text("\(String(format: "%.1f", timeScale))x speed")
                                .font(.caption2.monospacedDigit())
                        }
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                    }

                    // ── Event List ──
                    eventListSection(timeline, scrollProxy: scrollProxy)
                }
            }
            // Pinch to zoom time scale
            #if os(iOS)
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        timeScale = min(max(value, 0.5), 3.0)
                    }
            )
            #endif
        }
    }

    // MARK: - Header HUD

    private func headerHUD(_ timeline: SessionTimeline) -> some View {
        HStack(spacing: 8) {
            statCard(
                icon: "clock",
                value: formatDurationCompact(timeline.totalDurationSeconds),
                label: "duration"
            )

            statCard(
                icon: "hammer",
                value: "\(timeline.toolCallsCount)",
                label: "tools"
            )

            let totalTokens = timeline.inputTokens + timeline.outputTokens
            statCard(
                icon: "bolt.fill",
                value: formatTokensCompact(totalTokens),
                label: "tokens"
            )

            if let cost = timeline.costUSD, cost > 0 {
                statCard(
                    icon: "dollarsign.circle",
                    value: String(format: "$%.3f", cost),
                    label: "cost"
                )
            }
        }
    }

    private func statCard(icon: String, value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(Theme.accent)
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(Theme.tertiary)

            TextField("Filter by tool name or content…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .foregroundStyle(Theme.primary)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Chart Section

    private func chartSection(_ timeline: SessionTimeline) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Timeline")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.primary)
                .padding(.horizontal, 16)

            PlaybackTimelineChart(
                events: timeline.events,
                totalDuration: timeline.totalDurationSeconds,
                selectedEventID: $selectedEventID
            )
        }
    }

    // MARK: - Event List Section

    private func eventListSection(_ timeline: SessionTimeline, scrollProxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Events")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.primary)
                Spacer()
                Text("\(visibleEvents.count) of \(timeline.events.filter { $0.type != .turnBoundary }.count)")
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            LazyVStack(spacing: 2) {
                let firstTimestamp = timeline.events.first?.timestamp.timeIntervalSince1970 ?? 0

                ForEach(Array(visibleEvents.enumerated()), id: \.element.id) { index, event in
                    PlaybackEventRow(
                        event: event,
                        firstTimestamp: firstTimestamp,
                        isSelected: selectedEventID == event.id,
                        onTap: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedEventID = (selectedEventID == event.id) ? nil : event.id
                            }
                        }
                    )
                    .id(event.id)
                    .background(
                        isPlaying && index == playheadIndex
                            ? Theme.accent.opacity(0.08)
                            : Color.clear
                    )
                    .overlay(alignment: .leading) {
                        if isPlaying && index == playheadIndex {
                            Rectangle()
                                .fill(Theme.accent)
                                .frame(width: 3)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 40)
        }
    }

    // MARK: - Playback Controls

    private func togglePlayback() {
        isPlaying.toggle()
        if isPlaying {
            playheadIndex = 0
            withAnimation {
                // auto-scroll starts via timer
            }
        }
    }

    // MARK: - Loading / Error / Empty States

    private var loadingState: some View {
        VStack(spacing: 16) {
            HermesProgressView()
                .scaleEffect(1.2)
            Text("Loading timeline…")
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
        }
    }

    private func errorState(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(Theme.tertiary)
            Text("Failed to Load")
                .font(.headline)
                .foregroundStyle(Theme.secondary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("Retry") {
                Task { await loadTimeline() }
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 48))
                .foregroundStyle(Theme.tertiary)
            Text("No Events Recorded")
                .font(.headline)
                .foregroundStyle(Theme.secondary)
            Text("This session has no timeline events to display.")
                .font(.subheadline)
                .foregroundStyle(Theme.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    // MARK: - Data Loading

    private func loadTimeline() async {
        isLoading = true
        errorMessage = nil
        selectedEventID = nil

        do {
            let result = try await gatewayClientWrapper.client.sessionTimeline(sessionID: sessionID)
            timeline = result
        } catch let error as GatewayError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = "Could not load timeline: \(error.localizedDescription)"
        }

        isLoading = false
    }

    // MARK: - Formatting Helpers

    private func formatDurationCompact(_ total: TimeInterval) -> String {
        let seconds = abs(total)
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        }
        let mins = Int(seconds / 60)
        let secs = Int(seconds.truncatingRemainder(dividingBy: 60))
        if secs == 0 {
            return "\(mins)m"
        }
        return "\(mins)m \(secs)s"
    }

    private func formatTokensCompact(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }
}

// MARK: - Export Sheet

struct ExportSheet: View {
    let timeline: SessionTimeline
    let onDismiss: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(exportText)
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.primary)
                    .textSelection(.enabled)
                    .padding()
            }
            .background(Theme.background)
            .navigationTitle("Export Timeline")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                        onDismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        copyToClipboard(exportText)
                        dismiss()
                        onDismiss()
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var exportText: String {
        var lines: [String] = []
        lines.append("Session Playback — \(timeline.sessionID)")
        lines.append("Duration: \(formatDurationCompact(timeline.totalDurationSeconds))")
        lines.append("Tool Calls: \(timeline.toolCallsCount)")
        lines.append("Tokens: \(timeline.inputTokens) in / \(timeline.outputTokens) out")
        if let cost = timeline.costUSD {
            lines.append(String(format: "Cost: $%.5f", cost))
        }
        lines.append(String(repeating: "─", count: 60))
        lines.append("")

        let visibleEvents = timeline.events.filter { $0.type != .turnBoundary }
        let firstTimestamp = timeline.events.first?.timestamp.timeIntervalSince1970 ?? 0

        for event in visibleEvents {
            let relative = event.timestamp.timeIntervalSince1970 - firstTimestamp
            let timeStr = String(format: "+%.1fs", relative)
            var line = "[\(timeStr)] \(eventTypeLabel(event.type))"

            if let name = event.toolName {
                line += " — \(name)"
            }
            if let durMs = event.durationMs {
                if durMs < 1000 {
                    line += " (\(String(format: "%.0fms", durMs)))"
                } else {
                    line += " (\(String(format: "%.1fs", durMs / 1000)))"
                }
            }
            if let content = event.content {
                line += "\n   \(content.prefix(200))"
            }
            if let summary = event.summary {
                line += "\n   Summary: \(summary)"
            }
            lines.append(line)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private func eventTypeLabel(_ type: EventType) -> String {
        switch type {
        case .userMessage:      return "[User]"
        case .assistantMessage: return "[Assistant]"
        case .toolStart:        return "[Tool Start]"
        case .toolEnd:          return "[Tool End]"
        case .reasoningBlock:   return "[Reasoning]"
        case .turnBoundary:     return "[Boundary]"
        }
    }

    private func formatDurationCompact(_ total: TimeInterval) -> String {
        let seconds = abs(total)
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        }
        let mins = Int(seconds / 60)
        let secs = Int(seconds.truncatingRemainder(dividingBy: 60))
        if secs == 0 {
            return "\(mins)m"
        }
        return "\(mins)m \(secs)s"
    }

    private func copyToClipboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    SessionPlaybackViewPreviews.previews
}

enum SessionPlaybackViewPreviews {
    static var previews: some View {
        SessionPlaybackViewInternalPreview()
            .preferredColorScheme(.dark)
    }
}

private struct SessionPlaybackViewInternalPreview: View {
    var body: some View {
        SessionPlaybackView(sessionID: "preview-session")
            .environmentObject(GatewayClientWrapper())
    }
}
#endif
