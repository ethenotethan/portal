import SwiftUI
import Combine

// MARK: - Observer Message

struct ObserverMessage: Identifiable {
    let id = UUID()
    let role: String
    var content: String
    let toolName: String?
    let toolContext: String?  // Gateway sends "context" for tool messages
}

// MARK: - Live Feed Model

/// Streaming machinery for the Explorer's "Live" tab, lifted from the old
/// SessionObserverView: loads the transcript via session.history (with a
/// peekSession fallback for stale/foreign Hermes sessions), then keeps
/// appending from the backend's event stream so a running session updates
/// in place. Backend-generic: any AgentBackend's normalized GatewayEvents
/// render here, so a Centaur session's adapted SSE stream works unchanged.
@MainActor
final class SessionLiveFeedModel: ObservableObject {
    @Published var messages: [ObserverMessage] = []
    @Published var isLoading = true
    @Published var loadError: String?

    private var cancellable: AnyCancellable?
    private weak var client: (any AgentBackend)?
    private var sessionKey = ""
    private var runtimeSessionID = ""
    /// The assistant message currently accumulating message.delta text.
    private var streamingMessageID: UUID?

    func start(client: any AgentBackend, sessionKey: String, runtimeSessionID: String, isOwned: Bool) async {
        // Re-entrant .task (tab switches) must not reload or resubscribe.
        guard self.client !== client || self.sessionKey != sessionKey else { return }
        self.client = client
        self.sessionKey = sessionKey
        self.runtimeSessionID = runtimeSessionID
        subscribe(to: client)
        await loadHistory(client: client, isOwned: isOwned)
    }

    // MARK: History (lifted from SessionObserverView)

    private func loadHistory(client: any AgentBackend, isOwned: Bool) async {
        guard case .connected = client.connectionState else {
            loadError = "Not connected to gateway."
            isLoading = false
            return
        }
        isLoading = true
        loadError = nil

        if isOwned || !(client is GatewayClient) {
            // Try session.history (lightweight; on Hermes it requires a live
            // short hex). If the session ended and the gateway cleaned up the
            // runtime, the short hex may be stale -> 4001. Fall back to
            // peekSession — a Hermes-only RPC; other backends surface the
            // error directly.
            do {
                let response = try await client.sessionHistory(sessionID: runtimeSessionID)
                messages = Self.parse(response)
            } catch let error as GatewayError {
                if case .rpcError(let rpcErr) = error, rpcErr.code == 4001,
                   let gateway = client as? GatewayClient {
                    await loadViaPeek(client: gateway)
                } else {
                    loadError = "History unavailable: \(error.localizedDescription)"
                }
            } catch {
                loadError = "History unavailable: \(error.localizedDescription)"
            }
        } else if let gateway = client as? GatewayClient {
            await loadViaPeek(client: gateway)
        }

        isLoading = false
    }

    /// peekSession (resume -> get data -> close) works for sessions from other
    /// transports, but is expensive — only used when session.history can't.
    /// Hermes-only: no other backend has a peek RPC.
    private func loadViaPeek(client: GatewayClient) async {
        do {
            let result = try await client.peekSession(sessionKey: sessionKey)
            messages = Self.parse(result.messages)
        } catch let error as GatewayError {
            loadError = "Session not accessible: \(error.localizedDescription)"
        } catch {
            loadError = "Could not load session: \(error.localizedDescription)"
        }
    }

    /// Gateway format: {"role": "user"|"assistant"|"system", "text": "..."} or
    /// {"role": "tool", "name": "...", "context": "..."}
    private static func parse(_ raw: [[String: AnyCodable]]) -> [ObserverMessage] {
        raw.compactMap { d -> ObserverMessage? in
            guard let role = d["role"]?.stringValue else { return nil }
            let content = d["text"]?.stringValue ?? d["content"]?.stringValue ?? ""
            guard !content.isEmpty || role == "tool" else { return nil }
            return ObserverMessage(
                role: role,
                content: String(content.prefix(2000)),
                toolName: d["name"]?.stringValue ?? d["tool_name"]?.stringValue,
                toolContext: d["context"]?.stringValue.map { String($0.prefix(2000)) }
            )
        }
    }

    // MARK: Live Stream

    private func subscribe(to client: any AgentBackend) {
        cancellable = client.eventStream
            .collect(.byTimeOrCount(RunLoop.main, .milliseconds(48), 30))
            .sink { [weak self] batch in
                DispatchQueue.main.async {
                    for (event, sessionID) in batch {
                        self?.handleEvent(event, sessionID: sessionID)
                    }
                }
            }
    }

    private func handleEvent(_ event: GatewayEvent, sessionID: String?) {
        // Events are multiplexed over one app-level socket; only apply the
        // ones for this session (runtime short hex or database key).
        guard let sessionID, sessionID == runtimeSessionID || sessionID == sessionKey else { return }
        switch event {
        case .messageDelta(let text, _):
            appendStreamingText(text)
        case .messageComplete(let payload):
            finalizeStreamingMessage(with: payload.text)
        case .toolStart(let payload):
            messages.append(ObserverMessage(
                role: "tool",
                content: String(payload.context.prefix(2000)),
                toolName: payload.name,
                toolContext: String(payload.context.prefix(2000))
            ))
        default:
            break
        }
    }

    private func appendStreamingText(_ text: String) {
        if let id = streamingMessageID, let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].content += text
        } else {
            let message = ObserverMessage(role: "assistant", content: text, toolName: nil, toolContext: nil)
            streamingMessageID = message.id
            messages.append(message)
        }
    }

    private func finalizeStreamingMessage(with text: String) {
        defer { streamingMessageID = nil }
        guard !text.isEmpty else { return }
        if let id = streamingMessageID, let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].content = String(text.prefix(2000))
        } else {
            messages.append(ObserverMessage(
                role: "assistant", content: String(text.prefix(2000)), toolName: nil, toolContext: nil
            ))
        }
    }
}

// MARK: - Live Feed View

/// The Explorer's "Live" pane: read-only transcript that follows a running
/// session in real time. When the session ends while open, a banner offers
/// the Timeline (playback) tab instead of streaming into the void.
struct SessionLiveFeedView: View {
    let sessionID: String
    let runtimeSessionID: String
    let isOwned: Bool
    let isSessionLive: Bool
    /// Backend serving this session; nil = the home Hermes gateway.
    var backend: (any AgentBackend)?
    var onViewTimeline: (() -> Void)?

    @EnvironmentObject var gatewayClientWrapper: GatewayClientWrapper
    @StateObject private var feed = SessionLiveFeedModel()

    var body: some View {
        VStack(spacing: 0) {
            if !isSessionLive {
                endedBanner
            }
            content
        }
        .task(id: sessionID) {
            await feed.start(
                client: backend ?? gatewayClientWrapper.client,
                sessionKey: sessionID,
                runtimeSessionID: runtimeSessionID,
                isOwned: isOwned
            )
        }
    }

    private var endedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "flag.checkered")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Session ended")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            // Hidden when the backend has no timeline RPC (Centaur).
            if let onViewTimeline {
                Button("View Timeline", action: onViewTimeline)
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.surface)
    }

    private var content: some View {
        Group {
            if feed.isLoading {
                HermesProgressView(label: "Loading transcript…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = feed.loadError {
                emptyState(icon: "exclamationmark.triangle", title: "Cannot Load Transcript",
                           subtitle: error)
            } else if feed.messages.isEmpty {
                emptyState(icon: "dot.radiowaves.left.and.right", title: "Waiting for Activity",
                           subtitle: "This session has no messages yet. New events will appear here as they stream in.")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(feed.messages) { msg in
                                messageRow(msg)
                                    .id(msg.id)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: feed.messages.last?.id) { _, lastID in
                        guard let lastID else { return }
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private func messageRow(_ msg: ObserverMessage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(msg.role.uppercased())
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(msg.role == "user" ? Theme.accent : .secondary)

            // Content (for tool messages, show context if available)
            let displayText = msg.role == "tool" ? (msg.toolContext ?? msg.content) : msg.content
            if !displayText.isEmpty {
                Text(displayText)
                    .font(.subheadline)
                    .foregroundStyle(Theme.primary)
                    .textSelection(.enabled)
            }

            if let toolName = msg.toolName {
                HStack(spacing: 4) {
                    Image(systemName: "wrench")
                        .font(.caption2)
                    Text(toolName)
                        .font(.caption2)
                }
                .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(msg.role == "user" ? Theme.accent.opacity(0.08) : Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
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
