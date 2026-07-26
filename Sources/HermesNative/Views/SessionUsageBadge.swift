import SwiftUI
import os

private let log = Logger(subsystem: "com.researchoors.HermesNative", category: "SessionUsageBadge")

/// Persistent top-of-session usage metric: cumulative input/output tokens and
/// cost for the active session. This is where the retired Mission Control
/// "Usage" tab landed — an ambient "what is this session costing me" signal
/// that's always visible, rather than a dashboard you navigate to.
///
/// Backed by the `session.usage` RPC (server-computed cumulative totals incl.
/// `costUSD`). Refreshes when a turn completes (streaming → idle) and on
/// session switch. Cost is shown only when the backend returns one; token
/// counts alone otherwise. Renders nothing until there's a session with usage.
internal struct SessionUsageBadge: View {
    @ObservedObject internal var chatViewModel: ChatViewModel
    internal let client: GatewayClient

    @State private var usage: SessionUsage?

    internal var body: some View {
        Group {
            if let usage, usage.totalTokens > 0 {
                HStack(spacing: 8) {
                    metric("\(compact(usage.inputTokens)) in")
                    metric("\(compact(usage.outputTokens)) out")
                    if let cost = usage.costUSD, cost > 0 {
                        Text(formatCost(cost))
                            .foregroundStyle(Theme.accent)
                    }
                    if let pct = usage.contextPercent, pct > 0 {
                        metric("\(pct)% ctx")
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Theme.secondary)
                .help(fullBreakdown(usage))
            }
        }
        // Refresh when a turn finishes and when the session changes.
        .task(id: refreshKey) { await refresh() }
    }

    /// Changes whenever we should re-fetch: session switch, or streaming
    /// ending (a turn just completed → usage grew).
    private var refreshKey: String {
        "\(chatViewModel.currentSessionID ?? "none")|\(chatViewModel.isStreaming)"
    }

    private func refresh() async {
        // Only fetch when idle (a completed turn) and connected.
        guard !chatViewModel.isStreaming,
              let sessionID = chatViewModel.currentSessionID,
              case .connected = client.connectionState else { return }
        do {
            usage = try await client.sessionUsage(sessionID: sessionID)
        } catch {
            log.debug("session usage fetch failed: \(error.localizedDescription)")
        }
    }

    private func metric(_ text: String) -> some View {
        Text(text)
    }

    /// "12.3k" / "1.2M" compact token counts.
    private func compact(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...: return String(format: "%.1fk", Double(n) / 1_000)
        default: return "\(n)"
        }
    }

    /// Sub-cent costs show more precision so a cheap session isn't "$0.00".
    private func formatCost(_ cost: Double) -> String {
        cost < 0.01 ? String(format: "$%.4f", cost) : String(format: "$%.2f", cost)
    }

    private func fullBreakdown(_ u: SessionUsage) -> String {
        var parts = ["\(u.inputTokens) input", "\(u.outputTokens) output", "\(u.totalTokens) total"]
        if let cost = u.costUSD, cost > 0 { parts.append(String(format: "$%.4f", cost)) }
        if let used = u.contextUsed, let max = u.contextMax {
            parts.append("context \(used)/\(max)")
        }
        parts.append("\(u.apiCalls) API calls")
        return parts.joined(separator: " · ")
    }
}
