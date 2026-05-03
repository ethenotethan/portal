import SwiftUI

struct GatewayDebugPanelView: View {
    @ObservedObject var client: GatewayClient

    private var snapshot: GatewayDebugSnapshot { client.debugSnapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    connectionSection
                    pendingSection
                    eventSection
                }
                .padding(16)
            }
        }
        .background(Theme.background)
        .foregroundStyle(Theme.primary)
        .frame(minWidth: 420, minHeight: 520)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "wave.3.right.circle.fill")
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Gateway Debug")
                    .font(.headline)
                Text("Single WebSocket transport diagnostics")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
            }
            Spacer()
            statusBadge(snapshot.connectionState)
        }
        .padding(16)
    }

    private var connectionSection: some View {
        debugCard("Connection") {
            debugRow("State", snapshot.connectionState)
            debugRow("Socket", snapshot.socketURL, selectable: true)
            debugRow("Auth", snapshot.isAuthenticated ? "Bearer token set" : "No API key")
            debugRow("CF Access", snapshot.hasCFAuthCookie ? "Cookie set" : "Not set")
            debugRow("Active session", snapshot.activeSessionID ?? "—", selectable: true)
            debugRow("Last session key", snapshot.lastSessionKey ?? "—", selectable: true)
            debugRow("Reconnect attempt", "\(snapshot.reconnectAttempt)")
            debugRow("Last opened", formatDate(snapshot.lastOpenAt))
            debugRow("Last closed", formatDate(snapshot.lastCloseAt))
            if let lastError = snapshot.lastError, !lastError.isEmpty {
                debugRow("Last error", lastError, isError: true, selectable: true)
            }
        }
    }

    private var pendingSection: some View {
        debugCard("Pending RPCs") {
            if snapshot.pendingRequestIDs.isEmpty {
                Text("No pending JSON-RPC continuations")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
            } else {
                ForEach(snapshot.pendingRequestIDs, id: \.self) { id in
                    let method = snapshot.pendingRequestMethods[id] ?? "unknown"
                    debugRow("#\(id)", method, selectable: true)
                }
            }
        }
    }

    private var eventSection: some View {
        debugCard("Recent Transport Events") {
            if snapshot.recentEvents.isEmpty {
                Text("No events recorded yet")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(snapshot.recentEvents) { event in
                        eventRow(event)
                    }
                }
            }
        }
    }

    private func debugCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.primary)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.border, lineWidth: 1)
        )
    }

    private func debugRow(_ label: String, _ value: String, isError: Bool = false, selectable: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.secondary)
                .frame(width: 118, alignment: .leading)
            let valueText = Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(isError ? .red : Theme.primary)
                .lineLimit(3)
                .truncationMode(.middle)
            if selectable {
                valueText.textSelection(.enabled)
            } else {
                valueText
            }
            Spacer(minLength: 0)
        }
    }

    private func eventRow(_ event: GatewayDebugSnapshot.EventRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(formatTime(event.timestamp))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Theme.tertiary)
                Text(event.direction.rawValue.uppercased())
                    .font(.system(.caption2, design: .monospaced).weight(.bold))
                    .foregroundStyle(color(for: event.direction))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(color(for: event.direction).opacity(0.14))
                    .clipShape(Capsule())
                Text(event.name)
                    .font(.system(.caption, design: .monospaced).weight(.medium))
                    .foregroundStyle(Theme.primary)
                Spacer(minLength: 0)
            }
            if let sessionID = event.sessionID, !sessionID.isEmpty {
                Text("session: \(sessionID)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Theme.secondary)
                    .textSelection(.enabled)
            }
            if !event.detail.isEmpty {
                Text(event.detail)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(event.direction == .dropped || event.direction == .error ? .orange : Theme.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.background.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func statusBadge(_ state: String) -> some View {
        let connected = state == "connected"
        return Text(state)
            .font(.system(.caption, design: .monospaced).weight(.semibold))
            .foregroundStyle(connected ? .green : .orange)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background((connected ? Color.green : Color.orange).opacity(0.14))
            .clipShape(Capsule())
    }

    private func color(for direction: GatewayDebugSnapshot.EventRecord.Direction) -> Color {
        switch direction {
        case .inbound: return .green
        case .outbound: return .blue
        case .dropped: return .orange
        case .state: return Theme.accent
        case .error: return .red
        }
    }

    private func formatDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .omitted, time: .standard)
    }

    private func formatTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }
}
