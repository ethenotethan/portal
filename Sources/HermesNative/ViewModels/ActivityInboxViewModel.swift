import Foundation
import Combine
import os.log

private let log = Logger(subsystem: "hermes", category: "ActivityInbox")

@MainActor
final class ActivityInboxViewModel: ObservableObject {
    @Published private(set) var items: [ActivityItem] = []
    @Published var selectedItem: ActivityItem?
    @Published var isLoading = false
    @Published var errorMessage: String?

    private var store = ActivityStore.shared
    private var gatewayClient: GatewayClient?
    private var cancellables = Set<AnyCancellable>()

    var unreadCount: Int { items.filter { !$0.isRead }.count }

    init() {
        items = store.items
    }

    func setGatewayClient(_ client: GatewayClient?) {
        if gatewayClient === client { return }
        cancellables.removeAll()
        gatewayClient = client
        guard let client else { return }

        client.eventStream
            .receive(on: RunLoop.main)
            .sink { [weak self] event, sessionID in
                self?.handle(event, eventSessionID: sessionID)
            }
            .store(in: &cancellables)
    }

    func refresh() async {
        guard let gatewayClient else {
            log.info("refresh: no gateway client, using local store")
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await gatewayClient.listActivityItems(limit: 200)
            for item in fetched {
                store.upsert(item)
            }
            items = store.items
            if let selectedItem, let fresh = items.first(where: { $0.id == selectedItem.id }) {
                self.selectedItem = fresh
            }
            errorMessage = nil
            log.info("refresh: fetched \(fetched.count) from gateway, total \(self.items.count)")
        } catch {
            log.info("refresh: gateway RPC failed, using local store — \(error.localizedDescription)")
            items = store.items
        }
    }

    func markRead(_ item: ActivityItem, read: Bool = true) async {
        if let gatewayClient {
            do {
                let updated = try await gatewayClient.markActivityRead(activityID: item.id, read: read)
                store.upsert(updated)
                items = store.items
                return
            } catch {
                log.info("markRead RPC failed, updating locally")
            }
        }
        store.markRead(id: item.id)
        items = store.items
    }

    func dismiss(_ item: ActivityItem) async {
        if let gatewayClient {
            do {
                let _ = try await gatewayClient.dismissActivity(activityID: item.id)
                store.dismiss(id: item.id)
                items = store.items
                if selectedItem?.id == item.id { selectedItem = nil }
                return
            } catch {
                log.info("dismiss RPC failed, dismissing locally")
            }
        }
        store.dismiss(id: item.id)
        items = store.items
        if selectedItem?.id == item.id { selectedItem = nil }
    }

    func markAllRead() {
        store.markAllRead()
        items = store.items
    }

    func clearAll() {
        store.clearAll()
        items = store.items
        selectedItem = nil
    }

    func artifactContent(id: String) async throws -> ActivityArtifactContent {
        guard let gatewayClient else { throw GatewayError.notConnected }
        return try await gatewayClient.getActivityArtifact(artifactID: id)
    }

    func handle(_ event: GatewayEvent, eventSessionID: String? = nil) {
        switch event {
        case .activityCreated(let item):
            store.upsert(item)
            items = store.items
            if !item.isDismissed {
                NotificationService.shared.notifyActivity(item)
            }

        case .activityUpdated(let item):
            store.upsert(item)
            items = store.items

        case .approvalRequest(let payload):
            let item = ActivityItem(
                id: "approval-\(eventSessionID ?? UUID().uuidString)",
                createdAt: Date(),
                kind: "approval.request",
                severity: .warning,
                source: "agent",
                title: "Approval Required",
                summary: payload.command.truncated(to: 120),
                sessionID: eventSessionID,
                isRead: false,
                isDismissed: false,
                actions: [.init(type: "open_session", label: "Open Session", sessionID: eventSessionID)],
                artifacts: [],
                externalRefs: []
            )
            store.upsert(item)
            items = store.items
            NotificationService.shared.notifyActivity(item)

        case .clarifyRequest(let payload):
            let question = payload.question
            let item = ActivityItem(
                id: "clarify-\(payload.requestID.isEmpty ? String(UUID().uuidString.prefix(8)) : payload.requestID)",
                createdAt: Date(),
                kind: "clarify.request",
                severity: .info,
                source: "agent",
                title: "Question",
                summary: question.truncated(to: 120),
                sessionID: eventSessionID,
                isRead: false,
                isDismissed: false,
                actions: [.init(type: "open_session", label: "Open Session", sessionID: eventSessionID)],
                artifacts: [],
                externalRefs: []
            )
            store.upsert(item)
            items = store.items
            NotificationService.shared.notifyActivity(item)

        case .backgroundComplete(let taskID, let text):
            let item = ActivityItem(
                id: "bg-\(taskID)",
                createdAt: Date(),
                kind: "background.complete",
                severity: .info,
                source: "background",
                title: "Background Task Done",
                summary: text.truncated(to: 120),
                sessionID: eventSessionID,
                isRead: false,
                isDismissed: false,
                actions: [],
                artifacts: [],
                externalRefs: []
            )
            store.upsert(item)
            items = store.items
            NotificationService.shared.notifyActivity(item)

        case .sudoRequest:
            let item = ActivityItem(
                id: "sudo-\(eventSessionID ?? UUID().uuidString)",
                createdAt: Date(),
                kind: "sudo.request",
                severity: .warning,
                source: "agent",
                title: "Sudo Required",
                summary: "Agent is requesting sudo privileges",
                sessionID: eventSessionID,
                isRead: false,
                isDismissed: false,
                actions: [.init(type: "open_session", label: "Open Session", sessionID: eventSessionID)],
                artifacts: [],
                externalRefs: []
            )
            store.upsert(item)
            items = store.items
            NotificationService.shared.notifyActivity(item)

        case .secretRequest(let prompt, let envVar):
            let item = ActivityItem(
                id: "secret-\(envVar)-\(UUID().uuidString.prefix(6))",
                createdAt: Date(),
                kind: "secret.request",
                severity: .warning,
                source: "agent",
                title: "Secret Required",
                summary: "\(envVar): \(prompt.truncated(to: 80))",
                sessionID: eventSessionID,
                isRead: false,
                isDismissed: false,
                actions: [.init(type: "open_session", label: "Open Session", sessionID: eventSessionID)],
                artifacts: [],
                externalRefs: []
            )
            store.upsert(item)
            items = store.items
            NotificationService.shared.notifyActivity(item)

        case .error(let message):
            let item = ActivityItem(
                id: "error-\(UUID().uuidString.prefix(8))",
                createdAt: Date(),
                kind: "error",
                severity: .error,
                source: "gateway",
                title: "Gateway Error",
                summary: message.truncated(to: 120),
                sessionID: eventSessionID,
                isRead: false,
                isDismissed: false,
                actions: [],
                artifacts: [],
                externalRefs: []
            )
            store.upsert(item)
            items = store.items
            NotificationService.shared.notifyActivity(item)

        case .subagentComplete(let payload):
            let item = ActivityItem(
                id: "subagent-\(payload.subagentID ?? UUID().uuidString)",
                createdAt: Date(),
                kind: "subagent.complete",
                severity: .info,
                source: "agent",
                title: "Subagent Finished",
                summary: payload.goal.truncated(to: 100),
                sessionID: eventSessionID,
                isRead: false,
                isDismissed: false,
                actions: [.init(type: "open_session", label: "Open Session", sessionID: eventSessionID)],
                artifacts: [],
                externalRefs: []
            )
            store.upsert(item)
            items = store.items

        default:
            break
        }
    }
}
