import Foundation
import Combine

/// The calls the architecture surface makes. A protocol so the view models
/// never name the concrete client and a test can hand them a stub.
@MainActor
internal protocol ArchitectureReading: AnyObject {
    func architectureDescribe(service: String, revision: String?) async throws -> ArchitectureModelDocument
    func architectureCheck(service: String) async throws -> ArchitectureCheckResult
    func architectureLogs(service: String, sink: String?, lines: Int, cursor: String?) async throws -> ArchitectureLogTail
    func architectureLogsFollow(service: String, sink: String?, enabled: Bool) async throws -> ArchitectureLogFollowState
    func architectureHistory(service: String, limit: Int?) async throws -> ArchitectureRevisionHistory
    func architectureDiff(service: String, from: String?, to: String?) async throws -> ArchitectureRevisionDiff
    /// Global gateway events, for surfaces that follow `architecture.log`.
    var architectureEvents: AnyPublisher<GatewayEvent, Never> { get }
}

/// Drives the architecture surface for one service: fetches the model
/// (`architecture.describe`) for the native section renderers, and runs the
/// service's own `--check` on request (`architecture.check`).
@MainActor
internal final class ArchitectureSurfaceModel: ObservableObject {
    internal enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed
    }

    @Published internal private(set) var phase: Phase = .idle
    @Published internal private(set) var document: ArchitectureModelDocument?
    @Published internal private(set) var errorMessage: String?
    @Published internal private(set) var isChecking = false
    @Published internal private(set) var checkMessage: String?

    internal let reader: any ArchitectureReading
    internal let service: String
    /// The stored revision being viewed, or nil for the latest.
    @Published internal private(set) var revision: String?
    /// Drop-stale guard: a slow older load must not overwrite a newer one.
    private var loadGeneration = 0

    internal init(service: String, revision: String? = nil, reader: any ArchitectureReading) {
        self.service = service
        self.revision = revision
        self.reader = reader
    }

    /// Whether the surface shows an older stored revision rather than the latest.
    internal var isViewingOlderRevision: Bool {
        revision != nil || document?.isLatest == false
    }

    /// Whether the surface can run the service's check from here: a local
    /// service whose manifest declares one.
    internal var canRunCheck: Bool {
        guard let service = document?.service else { return false }
        return service.isLocal && service.checkConfigured
    }

    internal func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        phase = .loading
        errorMessage = nil
        do {
            let fetched = try await reader.architectureDescribe(service: service, revision: revision)
            guard generation == loadGeneration else { return }
            document = fetched
            phase = .loaded
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = Self.friendly(error)
            phase = .failed
        }
    }

    /// Show the model at a stored revision (from the Revisions tab), or the
    /// latest again with nil.
    internal func load(revision: String?) async {
        self.revision = revision
        await load()
    }

    internal func runCheck() async {
        guard !isChecking else { return }
        isChecking = true
        checkMessage = nil
        defer { isChecking = false }
        do {
            let result = try await reader.architectureCheck(service: service)
            document?.check = result
            checkMessage = Self.checkSummary(result)
        } catch {
            checkMessage = Self.friendly(error)
        }
    }

    /// One line for the header: what the last check said.
    internal static func checkSummary(_ result: ArchitectureCheckResult) -> String {
        switch result.status {
        case "passed":
            return "Check passed in \(Self.seconds(result.durationSeconds))"
        case "failed":
            let code = result.exitCode.map { " (exit \($0))" } ?? ""
            return "Check failed\(code) in \(Self.seconds(result.durationSeconds))"
        default:
            return result.reason.isEmpty ? "Check unavailable" : "Check unavailable: \(result.reason)"
        }
    }

    internal static func seconds(_ value: Double) -> String {
        value < 10 ? String(format: "%.1fs", value) : "\(Int(value.rounded()))s"
    }

    /// Gateway errors carry the reason the model could not be read (no model
    /// compiled yet, unknown service, unfetchable repository); show that rather
    /// than the transport's description.
    internal static func friendly(_ error: Error) -> String {
        if case GatewayError.rpcError(let rpc) = error {
            return rpc.message
        }
        return error.localizedDescription
    }
}
