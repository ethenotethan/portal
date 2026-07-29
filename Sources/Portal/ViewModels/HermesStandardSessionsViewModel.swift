import Foundation
import Combine

internal protocol HermesStandardSessionLoading: Sendable {
    func sessions(limit: Int, offset: Int) async throws -> HermesStandardSessionEnvelope
}

extension HermesStandardClient: HermesStandardSessionLoading, @unchecked Sendable {}

/// Read-only Sessions data source for a focused upstream/default Hermes installation.
/// It deliberately does not mutate `SessionListViewModel`: the app-level Hermes Gateway
/// remains connected underneath and continues to own Portal chat sessions.
@MainActor
internal final class HermesStandardSessionsViewModel: ObservableObject {
    @Published internal private(set) var sessions: [Session] = []
    @Published internal private(set) var total = 0
    @Published internal private(set) var isLoading = false
    @Published internal private(set) var errorMessage: String?

    private let loader: (any HermesStandardSessionLoading)?
    private let configurationError: String?
    private var refreshGeneration = 0

    internal init(
        loader: (any HermesStandardSessionLoading)?,
        configurationError: String? = nil
    ) {
        self.loader = loader
        self.configurationError = configurationError
        self.errorMessage = configurationError
    }

    internal convenience init(gateway: SavedGateway) {
        guard let baseURL = URL(string: gateway.url.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            self.init(loader: nil, configurationError: HermesStandardError.invalidBaseURL.errorDescription)
            return
        }
        do {
            let client = try HermesStandardClient(baseURL: baseURL, sessionToken: gateway.apiKey)
            self.init(loader: client)
        } catch {
            self.init(loader: nil, configurationError: Self.message(for: error))
        }
    }

    internal func refresh() async {
        guard let loader else {
            errorMessage = configurationError ?? HermesStandardError.invalidBaseURL.errorDescription
            sessions = []
            total = 0
            return
        }

        refreshGeneration += 1
        let generation = refreshGeneration
        isLoading = true
        errorMessage = nil

        do {
            let envelope = try await loader.sessions(limit: 200, offset: 0)
            guard !Task.isCancelled, generation == refreshGeneration else { return }
            sessions = envelope.sessions.map(Self.mapSession)
            total = envelope.total
            isLoading = false
        } catch is CancellationError {
            guard generation == refreshGeneration else { return }
            isLoading = false
        } catch {
            guard generation == refreshGeneration else { return }
            sessions = []
            total = 0
            errorMessage = Self.message(for: error)
            isLoading = false
        }
    }

    internal func title(for session: Session) -> String {
        if let title = session.title, !title.isEmpty { return title }
        if let preview = session.preview, !preview.isEmpty {
            return String(preview.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(session.id.prefix(8))
    }

    private static func mapSession(_ upstream: HermesStandardSession) -> Session {
        Session(
            id: upstream.id,
            title: upstream.title,
            preview: upstream.preview,
            source: upstream.source,
            messageCount: upstream.messageCount,
            startedAt: upstream.startedAt.map(Date.init(timeIntervalSince1970:)),
            endedAt: upstream.endedAt.map(Date.init(timeIntervalSince1970:)),
            lastActive: upstream.lastActive.map(Date.init(timeIntervalSince1970:)),
            gatewayID: nil,
            localTitle: nil,
            isRunning: upstream.isActive,
            runState: upstream.isActive ? .streaming : .idle,
            isArchived: upstream.archived
        )
    }

    nonisolated private static func message(for error: Error) -> String {
        if let description = (error as? LocalizedError)?.errorDescription, !description.isEmpty {
            return description
        }
        return error.localizedDescription
    }
}
