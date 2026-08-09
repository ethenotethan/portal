import SwiftUI

/// Banner for the approvals a session is blocked on. The gateway's choice
/// vocabulary is "once" | "session" | "always" | "deny" (tools/approval.py):
/// once = allow this single command; session = allowlist the command pattern
/// for this session; always = persist the pattern to the permanent allowlist
/// in config.yaml. Approve is a split control — primary tap is the safe
/// "once", broader scopes are a deliberate second gesture in the menu.
///
/// The banner reads a *queue*, not a slot. Parallel subagents can each block
/// at once, and every answer resolves the oldest entry (`approval.respond`
/// carries no request id), so the visible request is always the head and the
/// rest are shown read-only behind a disclosure. Their presence has to be
/// visible: an unanswered approval is resolved as a denial by the gateway's
/// timeout, so a request the user never saw is a silently killed command.
internal struct ApprovalBanner: View {
    @EnvironmentObject internal var chatViewModel: ChatViewModel
    @State private var showUpcoming = false

    private var queue: ApprovalQueue { chatViewModel.approvalQueue }

    internal var body: some View {
        if let approval = queue.head {
            VStack(alignment: .leading, spacing: 8) {
                headerRow(approval: approval)
                if showUpcoming, !queue.upcoming.isEmpty {
                    upcomingList
                }
            }
            .padding(10)
            .background(Theme.warning.opacity(0.1))
            // Collapse the peek when the queue drains, so answering the last
            // one doesn't leave an empty disclosure open for the next arrival.
            .onChange(of: queue.waitingBehind) { _, behind in
                if behind == 0 { showUpcoming = false }
            }
        }
    }

    private func headerRow(approval: ApprovalPayload) -> some View {
        HStack {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(Theme.warning)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Approval Required")
                        .font(.caption)
                        .fontWeight(.semibold)
                    if queue.waitingBehind > 0 {
                        waitingBadge
                    }
                }
                Text(approval.command.truncated(to: 100))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            Spacer()

            denyButton
            approveButton
        }
    }

    /// Tapping the badge reveals what is stacked up — the count alone tells the
    /// user something is hidden without telling them *what*, and "what" is the
    /// difference between a queued `ls` and a queued `rm -rf`.
    private var waitingBadge: some View {
        Button {
            showUpcoming.toggle()
        } label: {
            HStack(spacing: 3) {
                Text("\(queue.waitingBehind) waiting")
                Image(systemName: showUpcoming ? "chevron.up" : "chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.warning.opacity(0.22), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Other agent threads are blocked waiting for approval")
    }

    private var upcomingList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(queue.upcoming.enumerated()), id: \.offset) { index, entry in
                HStack(alignment: .top, spacing: 6) {
                    // Position, not an answerable control: these resolve in
                    // order and cannot be answered out of turn.
                    Text("\(index + 2).")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    if let tool = entry.toolName, !tool.isEmpty {
                        Text(tool)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(entry.command.truncated(to: 80))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.leading, 22)
    }

    private var denyButton: some View {
        Menu {
            Button {
                respond("deny")
            } label: {
                Label("Deny this one", systemImage: "xmark")
            }
            if queue.count > 1 {
                Button {
                    respond("deny", applyToAll: true)
                } label: {
                    Label("Deny all \(queue.count) waiting", systemImage: "xmark.octagon")
                }
            }
        } label: {
            Text("Deny")
        } primaryAction: {
            respond("deny")
        }
        .menuStyle(.button)
        .portalButton(size: .small, tint: .red)
        .fixedSize()
    }

    private var approveButton: some View {
        Menu {
            if offers("once") {
                Button {
                    respond("once")
                } label: {
                    Label("Allow once", systemImage: "checkmark")
                }
            }
            if offers("session") {
                Button {
                    respond("session")
                } label: {
                    Label("Allow for this session", systemImage: "clock")
                }
            }
            if offers("always") {
                Button {
                    respond("always")
                } label: {
                    Label("Always allow this command", systemImage: "infinity")
                }
            }
            if queue.count > 1 {
                Divider()
                // The common case the single slot handled worst: an agent asks
                // about five similar commands in a row. `all: true` resolves
                // every queued entry in one round trip.
                Button {
                    respond("once", applyToAll: true)
                } label: {
                    Label("Allow all \(queue.count) waiting", systemImage: "checkmark.circle.fill")
                }
            }
        } label: {
            Text("Approve")
        } primaryAction: {
            respond("once")
        }
        .menuStyle(.button)
        .portalButton(size: .small, tint: .green)
        .fixedSize()
        .help("Approve runs this once; hold for session/permanent scopes")
    }

    /// The gateway sends the scopes it will actually honour (`choices`) — it
    /// drops "always" when permanent allowlisting is disabled and drops
    /// "session" too for smart-denied commands. Older gateways send nothing,
    /// so an empty list means "offer everything" rather than "offer nothing".
    private func offers(_ choice: String) -> Bool {
        guard let choices = queue.head?.choices, !choices.isEmpty else { return true }
        return choices.contains(choice)
    }

    private func respond(_ choice: String, applyToAll: Bool = false) {
        Task { await chatViewModel.respondApproval(choice: choice, applyToAll: applyToAll) }
    }
}
