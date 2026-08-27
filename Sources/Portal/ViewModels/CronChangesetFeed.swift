import Foundation
import os

private let log = Logger(subsystem: "com.ethenotethan.Portal", category: "CronChangesetFeed")

// MARK: - CronChangesetFeed

/// The gateway's recorded cron history, and the honest account of what happened
/// when Portal asked for it.
///
/// Three answers a gateway can give, and they mean different things:
///
/// - **it answers** → the drawer shows recorded changes, with real times, an
///   actor, and provenance.
/// - **it doesn't have the method** → this gateway records no cron history.
///   Portal falls back to its own observed log and says so, rather than showing
///   an empty drawer that reads as "nothing has ever changed".
/// - **the call failed** → nothing is known either way. This must not collapse
///   into the case above: "your gateway doesn't do this" is a claim about the
///   backend, and a timeout is not evidence for it.
///
/// That third distinction is the whole reason this type exists instead of an
/// `[CronChangeset]?`.
@MainActor
internal final class CronChangesetFeed: ObservableObject {

    internal enum Availability: Equatable {
        /// Not asked yet — no claim of any kind.
        case unasked
        /// The gateway records history and answered.
        case recorded
        /// The gateway told us the method doesn't exist.
        case unsupported
        /// The ask failed. Carries the message so the surface can show what went
        /// wrong instead of a shrug.
        case failed(String)
    }

    @Published internal private(set) var availability: Availability = .unasked
    @Published internal private(set) var changesets: [CronChangeset] = []
    @Published internal private(set) var total = 0
    @Published internal private(set) var isLoading = false

    /// Per-changeset diff state, keyed by changeset id. Fetched lazily when a row
    /// expands — a page of 50 changesets is 50 round-trips nobody asked for.
    @Published internal private(set) var diffs: [String: DiffState] = [:]

    internal enum DiffState: Equatable {
        case loading
        case ready(RecordedDiff)
        case failed(String)
    }

    /// One recorded change, resolved into what the drawer draws.
    internal struct RecordedDiff: Equatable {
        /// The typed statements, or nil when they can't be derived honestly (the
        /// gateway sent no `before` for a change that had a parent). Nil is a
        /// state the drawer has words for, not an error.
        internal let statements: CronGraphDiff?
        /// A unified text diff when job definitions are file-backed.
        internal let unifiedText: String?
    }

    // MARK: - Loading

    /// Ask the source for its history. Idempotent while a load is in flight.
    internal func load(from source: any CronChangesetSource, limit: Int = 50) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let page = try await source.cronChangesets(
                limit: limit, offset: 0, since: nil, until: nil, job: nil
            )
            changesets = page.changesets
            total = page.total
            availability = .recorded
        } catch {
            if Self.isUnsupported(error) {
                // A gateway without the method has no history to hold, so
                // whatever was here is wrong now.
                changesets = []
                total = 0
                diffs = [:]
                availability = .unsupported
            } else {
                // Rows already fetched are kept: stale recorded history beats
                // silently demoting the drawer to observations because one
                // refresh timed out. `fallbackNote` says which case this is.
                availability = .failed(Self.message(for: error))
                log.error("cron.changesets failed: \(error.localizedDescription)")
            }
        }
    }

    /// Whether the gateway's answer means "this backend records no cron
    /// history", as opposed to "the ask went wrong".
    ///
    /// JSON-RPC's own method-not-found code is the reliable signal; the message
    /// sniffing behind it is for gateways that report an unknown method as a
    /// generic error, and it's deliberately narrow. Anything not matched here
    /// stays a failure, because the cost of guessing wrong runs one way: telling
    /// someone their gateway doesn't record history when it does, and hiding a
    /// log that exists.
    internal static func isUnsupported(_ error: any Error) -> Bool {
        guard case GatewayError.rpcError(let rpc) = error else { return false }
        if rpc.code == -32601 { return true }
        let message = rpc.message.lowercased()
        return message.contains("method not found")
            || message.contains("unknown method")
            || message.contains("no such method")
            || message.contains("not implemented")
    }

    private static func message(for error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: - Diffs

    /// Fetch one changeset's diff, unless it's already loaded or in flight. A
    /// previous failure is retried — that's the only way a retry button can work.
    internal func loadDiff(for changeset: CronChangeset, from source: any CronChangesetSource) async {
        switch diffs[changeset.id] {
        case .loading, .ready: return
        case .failed, nil: break
        }
        diffs[changeset.id] = .loading
        do {
            let payload = try await source.cronChangesetDiff(id: changeset.id)
            diffs[changeset.id] = .ready(RecordedDiff(
                statements: payload.structural(parentDigest: changeset.parentDigest),
                unifiedText: payload.unifiedText
            ))
        } catch {
            diffs[changeset.id] = .failed(Self.message(for: error))
            log.error("cron.changeset_diff failed: \(error.localizedDescription)")
        }
    }

    internal func diffState(for changeset: CronChangeset) -> DiffState? {
        diffs[changeset.id]
    }

    // MARK: - What the drawer says

    /// Whether to render recorded rows at all. Rows, not availability: a failed
    /// refresh over a loaded page still has real history to show.
    internal var hasRecordedHistory: Bool { !changesets.isEmpty }

    /// The line the drawer prints when it isn't showing plain recorded history —
    /// nil when there's nothing to explain.
    ///
    /// Every branch names the source of what's on screen, because the two
    /// sources answer different questions and a row that doesn't say which it is
    /// invites being read as the stronger one.
    internal var fallbackNote: String? {
        switch availability {
        case .unasked, .recorded:
            return nil
        case .unsupported:
            return "This gateway doesn't record cron configuration history, so these rows are "
                + "Portal's own observations — when it noticed a change, not when it was made, "
                + "and nothing about who made it."
        case .failed(let message):
            return hasRecordedHistory
                ? "Couldn't refresh the gateway's history (\(message)), so these rows may be out of date."
                : "Couldn't read the gateway's history (\(message)), so these rows are Portal's own "
                    + "observations instead."
        }
    }
}
