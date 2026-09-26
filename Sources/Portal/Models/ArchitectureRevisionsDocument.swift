import Foundation

// MARK: - Revision history (architecture.history / architecture.diff)

/// One git commit the gateway read from a local checkout.
internal struct ArchitectureCommit: Hashable, Identifiable {
    internal let sha: String
    internal let author: String
    internal let date: String
    internal let subject: String

    internal var id: String { sha }
    internal var shortSHA: String { String(sha.prefix(9)) }

    internal static func decodeGatewayValue(_ value: AnyCodable) -> ArchitectureCommit? {
        guard let d = value.dictionaryValue, let sha = d["sha"]?.stringValue, !sha.isEmpty else { return nil }
        return ArchitectureCommit(
            sha: sha,
            author: d["author"]?.stringValue ?? "",
            date: d["date"]?.stringValue ?? "",
            subject: d["subject"]?.stringValue ?? ""
        )
    }

    internal static func decodeList(_ value: AnyCodable?) -> [ArchitectureCommit] {
        (value?.arrayValue ?? []).compactMap(decodeGatewayValue)
    }
}

/// One stored revision of a service's model: when it was stored, its counts,
/// the commit behind it and the commits since the previous stored revision
/// (local checkouts only), and whether it is the revision the checkout is at now.
internal struct ArchitectureRevisionEntry: Hashable, Identifiable {
    internal let revision: String
    internal let storedAt: String
    internal let source: String
    internal let summary: ArchitectureModelSummary
    internal let contract: ArchitectureContractRef?
    internal let check: ArchitectureCheckResult?
    internal let commit: ArchitectureCommit?
    internal let commitsSincePrevious: [ArchitectureCommit]
    internal let deployed: Bool
    internal let deployedAt: String?

    internal var id: String { revision }

    /// A git head abbreviated; a digest or ref name left whole.
    internal var shortRevision: String {
        let isHex = revision.count >= 40 && revision.allSatisfy(\.isHexDigit)
        return isHex ? String(revision.prefix(9)) : revision
    }

    internal static func decodeGatewayValue(_ value: AnyCodable) -> ArchitectureRevisionEntry? {
        guard let d = value.dictionaryValue, let revision = d["revision"]?.stringValue, !revision.isEmpty else { return nil }
        return ArchitectureRevisionEntry(
            revision: revision,
            storedAt: d["stored_at"]?.stringValue ?? "",
            source: d["source"]?.stringValue ?? "",
            summary: d["summary"].map(ArchitectureModelSummary.decodeGatewayValue) ?? .empty,
            contract: d["contract"].map { ArchitectureContractRef.decodeGatewayValue($0) },
            check: d["check"].flatMap(ArchitectureCheckResult.decodeGatewayValue),
            commit: d["commit"].flatMap(ArchitectureCommit.decodeGatewayValue),
            commitsSincePrevious: ArchitectureCommit.decodeList(d["commits_since_previous"]),
            deployed: d["deployed"]?.boolValue ?? false,
            deployedAt: d["deployed_at"]?.stringValue
        )
    }
}

/// The runtime a service is bound to, when the manifest binds one.
internal struct ArchitectureRuntimeInfo: Hashable {
    internal let graphID: String
    internal let provider: String
    internal let startedAt: String?
    internal let pid: Int?
    internal let revision: String?

    internal static func decodeGatewayValue(_ value: AnyCodable) -> ArchitectureRuntimeInfo? {
        guard let d = value.dictionaryValue, let graphID = d["graph_id"]?.stringValue else { return nil }
        return ArchitectureRuntimeInfo(
            graphID: graphID,
            provider: d["provider"]?.stringValue ?? "",
            startedAt: d["started_at"]?.stringValue,
            pid: d["pid"]?.intValue,
            revision: d["revision"]?.stringValue
        )
    }
}

/// What `architecture.history` returns: every stored revision (as the gateway
/// orders them), the latest one, and the bound runtime when there is one.
internal struct ArchitectureRevisionHistory: Hashable {
    internal let service: String
    internal let latest: String
    internal let revisions: [ArchitectureRevisionEntry]
    internal let runtime: ArchitectureRuntimeInfo?

    internal static let empty = ArchitectureRevisionHistory(service: "", latest: "", revisions: [], runtime: nil)

    /// Revisions newest first, by stored time then position, for the timeline.
    internal var newestFirst: [ArchitectureRevisionEntry] {
        revisions.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.storedAt != rhs.element.storedAt { return lhs.element.storedAt > rhs.element.storedAt }
                return lhs.offset > rhs.offset
            }
            .map(\.element)
    }

    internal func entry(_ revision: String) -> ArchitectureRevisionEntry? {
        revisions.first { $0.revision == revision }
    }

    /// The stored revision before `revision` in the timeline (older), if any.
    internal func previous(of revision: String) -> ArchitectureRevisionEntry? {
        let ordered = newestFirst
        guard let index = ordered.firstIndex(where: { $0.revision == revision }), index + 1 < ordered.count else { return nil }
        return ordered[index + 1]
    }

    internal static func decodeGatewayValue(_ value: AnyCodable) throws -> ArchitectureRevisionHistory {
        guard let d = value.dictionaryValue, let revisions = d["revisions"]?.arrayValue else {
            throw GatewayError.invalidResponse("architecture.history returned no revisions")
        }
        return ArchitectureRevisionHistory(
            service: d["service"]?.stringValue ?? "",
            latest: d["latest"]?.stringValue ?? "",
            revisions: revisions.compactMap(ArchitectureRevisionEntry.decodeGatewayValue),
            runtime: d["runtime"].flatMap(ArchitectureRuntimeInfo.decodeGatewayValue)
        )
    }
}

/// A structural diff between two stored revisions (`architecture.diff`):
/// constructions and edges by stable identity, invariant status changes, files
/// with line deltas, gate changes, both summaries, and the git commits and
/// numstat between the two for a local checkout.
internal struct ArchitectureRevisionDiff: Hashable {
    internal struct NodeChange: Hashable, Identifiable {
        internal let id: String
        internal let historyKey: String
        internal let kind: String
        internal let label: String
        internal let component: String?

        internal static func decode(_ value: AnyCodable) -> NodeChange? {
            guard let d = value.dictionaryValue, let id = d["id"]?.stringValue else { return nil }
            return NodeChange(
                id: id,
                historyKey: d["history_key"]?.stringValue ?? id,
                kind: d["kind"]?.stringValue ?? "",
                label: d["label"]?.stringValue ?? id,
                component: d["component"]?.stringValue
            )
        }
    }

    internal struct EdgeChange: Hashable, Identifiable {
        internal let source: String
        internal let target: String
        internal let relation: String
        internal let edgeClass: String

        internal var id: String { "\(source)→\(relation)→\(target)" }

        internal static func decode(_ value: AnyCodable) -> EdgeChange? {
            guard let d = value.dictionaryValue, let source = d["source"]?.stringValue, let target = d["target"]?.stringValue else { return nil }
            return EdgeChange(
                source: source,
                target: target,
                relation: d["relation"]?.stringValue ?? "",
                edgeClass: d["class"]?.stringValue ?? ""
            )
        }
    }

    internal struct InvariantChange: Hashable, Identifiable {
        internal let id: String
        internal let from: String
        internal let to: String

        internal static func decode(_ value: AnyCodable) -> InvariantChange? {
            guard let d = value.dictionaryValue, let id = d["id"]?.stringValue else { return nil }
            return InvariantChange(id: id, from: d["from"]?.stringValue ?? "", to: d["to"]?.stringValue ?? "")
        }
    }

    internal struct FileChange: Hashable, Identifiable {
        internal let path: String
        internal let linesFrom: Int
        internal let linesTo: Int

        internal var id: String { path }
        internal var delta: Int { linesTo - linesFrom }

        internal static func decode(_ value: AnyCodable) -> FileChange? {
            guard let d = value.dictionaryValue, let path = d["path"]?.stringValue else { return nil }
            return FileChange(path: path, linesFrom: d["lines_from"]?.intValue ?? 0, linesTo: d["lines_to"]?.intValue ?? 0)
        }
    }

    internal struct GateChanges: Hashable {
        internal let jobsAdded: [String]
        internal let jobsRemoved: [String]
        internal let ratchetsAdded: [String]
        internal let ratchetsRemoved: [String]

        internal static let empty = GateChanges(jobsAdded: [], jobsRemoved: [], ratchetsAdded: [], ratchetsRemoved: [])

        internal var isEmpty: Bool { jobsAdded.isEmpty && jobsRemoved.isEmpty && ratchetsAdded.isEmpty && ratchetsRemoved.isEmpty }

        internal static func decode(_ value: AnyCodable?) -> GateChanges {
            guard let d = value?.dictionaryValue else { return .empty }
            return GateChanges(
                jobsAdded: strings(d["jobs_added"]),
                jobsRemoved: strings(d["jobs_removed"]),
                ratchetsAdded: strings(d["ratchets_added"]),
                ratchetsRemoved: strings(d["ratchets_removed"])
            )
        }
    }

    internal struct FileStat: Hashable, Identifiable {
        internal let path: String
        internal let additions: Int?
        internal let deletions: Int?

        internal var id: String { path }
        internal var isBinary: Bool { additions == nil && deletions == nil }

        internal static func decode(_ value: AnyCodable) -> FileStat? {
            guard let d = value.dictionaryValue, let path = d["path"]?.stringValue else { return nil }
            return FileStat(path: path, additions: d["additions"]?.intValue, deletions: d["deletions"]?.intValue)
        }
    }

    internal struct GitInfo: Hashable {
        internal let commits: [ArchitectureCommit]
        internal let stat: [FileStat]
        internal let truncated: Bool

        internal var additions: Int { stat.reduce(0) { $0 + ($1.additions ?? 0) } }
        internal var deletions: Int { stat.reduce(0) { $0 + ($1.deletions ?? 0) } }

        internal static func decode(_ value: AnyCodable?) -> GitInfo? {
            guard let d = value?.dictionaryValue else { return nil }
            return GitInfo(
                commits: ArchitectureCommit.decodeList(d["commits"]),
                stat: (d["stat"]?.arrayValue ?? []).compactMap(FileStat.decode),
                truncated: d["truncated"]?.boolValue ?? false
            )
        }
    }

    internal let service: String
    internal let from: String
    internal let to: String
    internal let nodesAdded: [NodeChange]
    internal let nodesRemoved: [NodeChange]
    internal let edgesAdded: [EdgeChange]
    internal let edgesRemoved: [EdgeChange]
    internal let invariantsAdded: [String]
    internal let invariantsRemoved: [String]
    internal let invariantsChanged: [InvariantChange]
    internal let filesAdded: [String]
    internal let filesRemoved: [String]
    internal let filesChanged: [FileChange]
    internal let gates: GateChanges
    internal let summaryFrom: ArchitectureModelSummary
    internal let summaryTo: ArchitectureModelSummary
    internal let git: GitInfo?

    /// Nothing structural moved between the two revisions.
    internal var isEmpty: Bool {
        nodesAdded.isEmpty && nodesRemoved.isEmpty && edgesAdded.isEmpty && edgesRemoved.isEmpty
            && invariantsAdded.isEmpty && invariantsRemoved.isEmpty && invariantsChanged.isEmpty
            && filesAdded.isEmpty && filesRemoved.isEmpty && filesChanged.isEmpty && gates.isEmpty
    }

    /// Node changes grouped by kind, kinds sorted, for the diff panel.
    internal static func byKind(_ changes: [NodeChange]) -> [(kind: String, nodes: [NodeChange])] {
        let grouped = Dictionary(grouping: changes, by: \.kind)
        return grouped.keys.sorted().map { kind in (kind, grouped[kind, default: []].sorted { $0.label < $1.label }) }
    }

    /// One line for the timeline: what moved, in counts.
    internal var headline: String {
        var parts: [String] = []
        if !nodesAdded.isEmpty || !nodesRemoved.isEmpty { parts.append("constructions +\(nodesAdded.count) −\(nodesRemoved.count)") }
        if !edgesAdded.isEmpty || !edgesRemoved.isEmpty { parts.append("edges +\(edgesAdded.count) −\(edgesRemoved.count)") }
        let fileMoves = filesAdded.count + filesRemoved.count + filesChanged.count
        if fileMoves > 0 { parts.append("\(fileMoves) file(s)") }
        if !invariantsChanged.isEmpty || !invariantsAdded.isEmpty || !invariantsRemoved.isEmpty { parts.append("invariants changed") }
        if !gates.isEmpty { parts.append("gates changed") }
        return parts.isEmpty ? "No structural change" : parts.joined(separator: " · ")
    }

    private static func strings(_ value: AnyCodable?) -> [String] {
        (value?.arrayValue ?? []).compactMap(\.stringValue)
    }

    internal static func decodeGatewayValue(_ value: AnyCodable) throws -> ArchitectureRevisionDiff {
        guard let d = value.dictionaryValue, let from = d["from"]?.stringValue, let to = d["to"]?.stringValue else {
            throw GatewayError.invalidResponse("architecture.diff returned no revision pair")
        }
        let nodes = d["nodes"]?.dictionaryValue ?? [:]
        let edges = d["edges"]?.dictionaryValue ?? [:]
        let invariants = d["invariants"]?.dictionaryValue ?? [:]
        let files = d["files"]?.dictionaryValue ?? [:]
        let summary = d["summary"]?.dictionaryValue ?? [:]
        return ArchitectureRevisionDiff(
            service: d["service"]?.stringValue ?? "",
            from: from,
            to: to,
            nodesAdded: (nodes["added"]?.arrayValue ?? []).compactMap(NodeChange.decode),
            nodesRemoved: (nodes["removed"]?.arrayValue ?? []).compactMap(NodeChange.decode),
            edgesAdded: (edges["added"]?.arrayValue ?? []).compactMap(EdgeChange.decode),
            edgesRemoved: (edges["removed"]?.arrayValue ?? []).compactMap(EdgeChange.decode),
            invariantsAdded: strings(invariants["added"]),
            invariantsRemoved: strings(invariants["removed"]),
            invariantsChanged: (invariants["changed"]?.arrayValue ?? []).compactMap(InvariantChange.decode),
            filesAdded: strings(files["added"]),
            filesRemoved: strings(files["removed"]),
            filesChanged: (files["changed"]?.arrayValue ?? []).compactMap(FileChange.decode),
            gates: GateChanges.decode(d["gates"]),
            summaryFrom: summary["from"].map(ArchitectureModelSummary.decodeGatewayValue) ?? .empty,
            summaryTo: summary["to"].map(ArchitectureModelSummary.decodeGatewayValue) ?? .empty,
            git: GitInfo.decode(d["git"])
        )
    }
}
