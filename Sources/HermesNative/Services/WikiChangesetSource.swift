import Foundation

// MARK: - WikiChangesetSource

/// Capability marker for wiki backends that record an edit history
/// (changesets + git-style diffs). The wiki's timeline drawer only shows for
/// sources that conform — a protocol check, not a backend-kind check, so a
/// future source grows the drawer by conforming here.
///
/// Lives in its own file (not CentaurWikiClient.swift, where WikiSource is
/// declared) so capability growth doesn't churn the shared protocol file.
@MainActor
protocol WikiChangesetSource: WikiSource {}

/// Hermes gateway: wiki.changesets / wiki.changeset_diff RPCs.
extension GatewayClient: WikiChangesetSource {}
