import SwiftUI

/// Dedicated view for a cron-spawned session. Unlike a regular chat session,
/// cron sessions are automated dispatches — there's no user composer, and the
/// transcript is a structured record of what the agent produced.
///
/// Layout (macOS):
///   ┌──────────────────────────────────────┐
///   │ ● Job name          [status badge]   │  ← header
///   │   schedule · last run · duration     │
///   ├──────────────────────────────────────┤
///   │  Output                              │  ← agent's final response
///   │  (collapsible transcript below)      │
///   └──────────────────────────────────────┘
#if os(macOS)
internal struct CronSessionView: View {
    internal let session: Session

    @EnvironmentObject private var chatViewModel: ChatViewModel
    @EnvironmentObject private var gatewayClientWrapper: GatewayClientWrapper
    @ObservedObject private var runHistory = CronRunHistoryStore.shared

    @State private var showFullTranscript = false

    // Best-effort match: find a run record whose firedAt is close to session.startedAt
    private var matchedRun: CronRunRecord? {
        guard let firedAt = session.startedAt else { return nil }
        return runHistory.records.first { abs($0.firedAt.timeIntervalSince(firedAt)) < 120 }
    }

    internal var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                outputPane
            }
        }
        .background(Theme.background)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.2.circlepath")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.accent)

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title ?? matchedRun?.jobName ?? "Cron Run")
                        .font(.title3.weight(.semibold))
                    if let run = matchedRun {
                        Text(run.jobID)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.secondary)
                    }
                }

                Spacer()

                statusBadge
            }

            HStack(spacing: 16) {
                if let run = matchedRun {
                    metaChip("clock", run.firedAt.formatted(date: .abbreviated, time: .shortened))
                    if let dur = run.durationLabel as String?, !dur.isEmpty {
                        metaChip("timer", dur)
                    }
                } else if let start = session.startedAt {
                    metaChip("clock", start.formatted(date: .abbreviated, time: .shortened))
                }
                metaChip("bubble.left.and.bubble.right", "\(session.messageCount) messages")
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    @ViewBuilder
    private var statusBadge: some View {
        let (label, color, icon): (String, Color, String) = {
            if let run = matchedRun {
                if run.isOk {
                    return ("Completed", Theme.success, "checkmark.circle.fill")
                } else {
                    return ("Error", Color.red, "exclamationmark.circle.fill")
                }
            }
            switch session.status {
            case .active:  return ("Running", Theme.accent, "circle.fill")
            case .idle:    return ("Idle", Theme.secondary, "circle")
            case .ended:   return ("Ended", Theme.secondary, "checkmark.circle")
            }
        }()

        HStack(spacing: 5) {
            Image(systemName: icon)
            Text(label)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.12), in: Capsule())
    }

    @ViewBuilder
    private func metaChip(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondary)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
        }
    }

    // MARK: - Output pane

    private var outputPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Error callout
            if let err = matchedRun?.errorMessage {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(err)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.red.opacity(0.85))
                        .textSelection(.enabled)
                }
                .padding(12)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            // Last assistant message = the agent's deliverable
            if let output = lastAssistantMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Output")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                        .textCase(.uppercase)

                    MarkdownContentView(text: output, isStreaming: false)
                        .textSelection(.enabled)
                }
            }

            Divider()

            // Full transcript toggle
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showFullTranscript.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showFullTranscript ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                    Text(showFullTranscript ? "Hide transcript" : "Show full transcript")
                        .font(.system(size: 12))
                    Spacer()
                    Text("\(visibleMessages.count) messages")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                }
                .foregroundStyle(Theme.accent)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showFullTranscript {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(visibleMessages) { msg in
                        transcriptRow(msg)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    // MARK: - Transcript helpers

    private var visibleMessages: [ChatMessage] {
        chatViewModel.messages.filter { !$0.isCronInjection }
    }

    private var lastAssistantMessage: String? {
        visibleMessages.last(where: { $0.role == .assistant })?.contentWithoutAttachments
    }

    @ViewBuilder
    private func transcriptRow(_ message: ChatMessage) -> some View {
        let isUser = message.role == .user
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isUser ? "arrow.right.circle" : "sparkle")
                .font(.system(size: 11))
                .foregroundStyle(isUser ? Theme.secondary : Theme.accent)
                .padding(.top, 2)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 4) {
                Text(isUser ? "Prompt" : "Agent")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isUser ? Theme.secondary : Theme.accent)
                    .textCase(.uppercase)

                Text(message.contentWithoutAttachments)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.primary)
                    .textSelection(.enabled)
                    .lineLimit(isUser ? 4 : nil)
            }
        }
        .padding(12)
        .background(
            isUser
                ? Theme.surface.opacity(0.5)
                : Theme.accent.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }
}
#endif
