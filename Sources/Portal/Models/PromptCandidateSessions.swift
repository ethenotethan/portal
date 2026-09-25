import Foundation

/// Session IDs to try for `session.prompt_breakdown`, best candidate first.
///
/// `session.list` answers with history: ended and long-idle sessions come back
/// alongside live ones, in the gateway's own order. `prompt_breakdown` only
/// answers for a session that still has a live in-memory agent (4001
/// otherwise), so taking `list.first` made the System Prompt pane report "no
/// active session, send a message first" whenever a stale entry happened to
/// sort first — with a perfectly live session sitting right behind it.
///
/// Three ranks, with the gateway's own order preserved inside each so the
/// ordering it chose still decides among equals:
///  1. a live run state — `queued` / `streaming` / `tool_running` /
///     `waiting_for_user` all mean an agent is resident right now.
///  2. no `endedAt` — state unknown (or `idle`/`failed`/`canceled`), but the
///     session was never closed, so the agent may well still be there.
///  3. ended — last, and only as a long shot. An ended session cannot have a
///     live agent, so a run state that still reads "streaming" on one is stale
///     by definition and must not outrank an unended session.
internal func promptCandidateSessionIDs(_ sessions: [Session]) -> [String] {
    sessions
        .enumerated()
        .sorted { lhs, rhs in
            let lhsRank = promptCandidateRank(lhs.element)
            let rhsRank = promptCandidateRank(rhs.element)
            // Ties fall back to the gateway's index: `sorted(by:)` is not a
            // stable sort, so equal ranks would otherwise come back in an
            // arbitrary order.
            return lhsRank == rhsRank ? lhs.offset < rhs.offset : lhsRank < rhsRank
        }
        .map(\.element.id)
}

/// Lower ranks are likelier to have a live agent. See
/// `promptCandidateSessionIDs(_:)` for why ended outranks nothing.
private func promptCandidateRank(_ session: Session) -> Int {
    guard session.endedAt == nil else { return 2 }
    switch session.runState {
    case .queued, .streaming, .toolRunning, .waitingForUser:
        return 0
    case .idle, .failed, .canceled, nil:
        return 1
    }
}
