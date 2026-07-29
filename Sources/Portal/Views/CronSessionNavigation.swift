import SwiftUI

/// Client-side bridge from a Cron activation record to the chat session it
/// produced. The gateway exposes no run→session link, so navigation is resolved
/// by firing time — the same ±120s window `CronSessionView` uses in reverse.
///
/// Threading a callback through every Cron section/card/popover would be noisy
/// (the sections are deliberately "dumb"), so the resolver + open action ride the
/// SwiftUI environment: injected once where the Cron surface is presented, and
/// read wherever a run detail wants a "View session" button.
internal struct CronSessionNavigator: Sendable {
    /// All known sessions to correlate against (from `SessionListViewModel`).
    internal var sessions: [Session] = []
    /// Open a session by id. nil when the host isn't wired for navigation
    /// (e.g. a preview), which hides the button rather than dead-ending.
    internal var open: (@MainActor (String) -> Void)?

    /// Best-effort match from an activation to its cron session: the nearest
    /// cron-source session whose start is within ±120s of the run's fire time.
    internal func session(for record: CronRunRecord) -> Session? {
        sessions
            .filter { $0.source?.lowercased() == "cron" }
            .filter { session in
                guard let started = session.startedAt else { return false }
                return abs(started.timeIntervalSince(record.firedAt)) < 120
            }
            .min { lhs, rhs in
                let l = lhs.startedAt.map { abs($0.timeIntervalSince(record.firedAt)) } ?? .infinity
                let r = rhs.startedAt.map { abs($0.timeIntervalSince(record.firedAt)) } ?? .infinity
                return l < r
            }
    }
}

private struct CronSessionNavigatorKey: EnvironmentKey {
    static let defaultValue = CronSessionNavigator()
}

extension EnvironmentValues {
    internal var cronSessionNavigator: CronSessionNavigator {
        get { self[CronSessionNavigatorKey.self] }
        set { self[CronSessionNavigatorKey.self] = newValue }
    }
}

extension View {
    /// Inject the run→session navigator so any nested Cron run detail can offer
    /// a "View session" affordance.
    internal func cronSessionNavigator(_ navigator: CronSessionNavigator) -> some View {
        environment(\.cronSessionNavigator, navigator)
    }
}

/// The "View session" affordance shown at the foot of a run's detail popover.
/// Resolves the run→session match from the environment navigator; shows an
/// honest "no session recorded" note when there's no temporal match (or the
/// host isn't wired for navigation).
internal struct CronOpenSessionButton: View {
    internal let record: CronRunRecord
    @Environment(\.cronSessionNavigator) private var navigator

    internal var body: some View {
        if let open = navigator.open, let match = navigator.session(for: record) {
            Button {
                open(match.id)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 11, weight: .semibold))
                    Text("View session")
                        .font(.caption.weight(.medium))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(Theme.accent)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity)
                .background(Theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            HStack(spacing: 6) {
                Image(systemName: "clock.badge.questionmark")
                    .font(.system(size: 10))
                Text("No session recorded for this run")
                    .font(.caption2)
            }
            .foregroundStyle(Theme.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
        }
    }
}
