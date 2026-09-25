import Foundation
import Combine
@testable import Portal

/// A scripted `ArchitectureReading` for the Logs and Revisions view models:
/// every call records its arguments and answers from queues the test filled.
@MainActor
internal final class ArchitectureLogsRevisionsStub: ArchitectureReading {
    internal let events = PassthroughSubject<GatewayEvent, Never>()
    internal var tails: [ArchitectureLogTail] = []
    internal var tailError: Error?
    internal var followStates: [ArchitectureLogFollowState] = []
    internal var followError: Error?
    internal var history: ArchitectureRevisionHistory?
    internal var historyError: Error?
    internal var diffs: [String: ArchitectureRevisionDiff] = [:]
    internal var diffError: Error?
    internal var document: ArchitectureModelDocument?

    internal var logCalls: [(sink: String?, lines: Int, cursor: String?)] = []
    internal var followCalls: [(sink: String?, enabled: Bool)] = []
    internal var historyCalls = 0
    internal var diffCalls: [(from: String?, to: String?)] = []
    internal var describeCalls: [String?] = []

    internal var architectureEvents: AnyPublisher<GatewayEvent, Never> { events.eraseToAnyPublisher() }

    internal func architectureDescribe(service: String, revision: String?) async throws -> ArchitectureModelDocument {
        describeCalls.append(revision)
        guard let document else { throw GatewayError.invalidResponse("no document") }
        return document
    }

    internal func architectureCheck(service: String) async throws -> ArchitectureCheckResult {
        throw GatewayError.invalidResponse("check not stubbed")
    }

    internal func architectureLogs(service: String, sink: String?, lines: Int, cursor: String?) async throws -> ArchitectureLogTail {
        logCalls.append((sink, lines, cursor))
        if let tailError { throw tailError }
        guard !tails.isEmpty else { throw GatewayError.invalidResponse("no tail queued") }
        return tails.removeFirst()
    }

    internal func architectureLogsFollow(service: String, sink: String?, enabled: Bool) async throws -> ArchitectureLogFollowState {
        followCalls.append((sink, enabled))
        if let followError { throw followError }
        guard !followStates.isEmpty else {
            return ArchitectureLogFollowState(following: enabled, sink: nil, cursor: "")
        }
        return followStates.removeFirst()
    }

    internal func architectureHistory(service: String, limit: Int?) async throws -> ArchitectureRevisionHistory {
        historyCalls += 1
        if let historyError { throw historyError }
        guard let history else { throw GatewayError.invalidResponse("no history") }
        return history
    }

    internal func architectureDiff(service: String, from: String?, to: String?) async throws -> ArchitectureRevisionDiff {
        diffCalls.append((from, to))
        if let diffError { throw diffError }
        guard let diff = diffs["\(from ?? "")..\(to ?? "")"] else { throw GatewayError.invalidResponse("no diff queued") }
        return diff
    }
}
