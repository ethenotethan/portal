import Foundation
import Combine

@MainActor
final class ActivityInboxViewModel: ObservableObject {
    @Published private(set) var items: [ActivityItem] = []
    @Published var selectedItem: ActivityItem?
    @Published var isLoading = false
    @Published var errorMessage: String?

    private var gatewayClient: GatewayClient?
    private var cancellables = Set<AnyCancellable>()

    var unreadCount: Int { items.filter { !$0.isRead }.count }

    func setGatewayClient(_ client: GatewayClient?) {
        if gatewayClient === client { return }
        cancellables.removeAll()
        gatewayClient = client
        guard let client else { return }

        client.eventStream
            .sink { [weak self] event, _ in
                Task { @MainActor in
                    self?.handle(event)
                }
            }
            .store(in: &cancellables)
    }

    func refresh() async {
        guard let gatewayClient else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            items = try await gatewayClient.listActivityItems(limit: 200)
            if let selectedItem, let fresh = items.first(where: { $0.id == selectedItem.id }) {
                self.selectedItem = fresh
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func markRead(_ item: ActivityItem, read: Bool = true) async {
        guard let gatewayClient else { return }
        do {
            let updated = try await gatewayClient.markActivityRead(activityID: item.id, read: read)
            upsert(updated)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func dismiss(_ item: ActivityItem) async {
        guard let gatewayClient else { return }
        do {
            let updated = try await gatewayClient.dismissActivity(activityID: item.id)
            items.removeAll { $0.id == updated.id }
            if selectedItem?.id == updated.id { selectedItem = nil }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func artifactContent(id: String) async throws -> ActivityArtifactContent {
        guard let gatewayClient else { throw GatewayError.notConnected }
        return try await gatewayClient.getActivityArtifact(artifactID: id)
    }

    func applyForTesting(_ event: GatewayEvent) {
        handle(event)
    }

    private func handle(_ event: GatewayEvent) {
        switch event {
        case .activityCreated(let item), .activityUpdated(let item):
            upsert(item)
        default:
            break
        }
    }

    private func upsert(_ item: ActivityItem) {
        if item.isDismissed {
            items.removeAll { $0.id == item.id }
            if selectedItem?.id == item.id { selectedItem = nil }
        } else if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx] = item
        } else {
            items.insert(item, at: 0)
        }
        items.sort { $0.createdAt > $1.createdAt }
        if selectedItem?.id == item.id { selectedItem = item }
    }
}
