import Foundation

// MARK: - Cron interflow graph

/// One node in the cron interflow dataflow graph (from the `cron.graph` RPC).
///
/// Six kinds:
/// - `cron` — a scheduled job (id = the bare hex job id; carries schedule and
///   run metadata).
/// - `source` — an external input read by ≥1 cron and written by none.
/// - `artifact` — a data ref written by ≥1 cron: the join node between a
///   producer and its consumers (a produced ref outranks a plain source). A
///   *living* artifact (`artifact:<id>`, a revisioned document in the gateway's
///   artifact store) additionally carries `artifactID`, `artifactKind`, `rev`,
///   `updatedAt`, `updatedBy` and `maintainers`.
/// - `sink` — a terminal side-effect target (telegram / pr / webhook …).
/// - `service` — a long-running process or container the harness tracks (a
///   dashboard, a Postgres, a Redis) that reads/writes the same refs a cron
///   does. Liveness is the tracked process / `docker ps` presence, and it
///   carries a required markdown `description` shown in the node detail card.
/// - `object` — the typed object of an explicit service relationship, such as a
///   runtime, workflow, scheduler, or other topology/control concept.
///
/// Resource and sink ids are `scheme:value` (always contain a colon); cron ids
/// are bare 12-hex, and service ids are `docker:<id>` or a process handle — the
/// id spaces never collide, so shared refs dedupe a service onto a cron's store.
internal struct CronGraphNode: Identifiable, Hashable, Codable {
    internal let id: String
    /// `cron` | `source` | `artifact` | `sink` | `service` | `object` — drives node color.
    internal let kind: String
    /// Fine-grained type: `cron` for jobs, `service` for services, else the ref
    /// scheme (`https`, `wiki`, `telegram`, …).
    internal let type: String
    internal let label: String
    /// Markdown blurb of what a `service` node is / does — required on services
    /// (the server rejects an empty one), empty for every other kind. Rendered
    /// in the node detail card so you can expand a service and read its purpose.
    internal let description: String
    // Cron-only metadata — nil / defaults for resource and sink nodes.
    internal let schedule: String?
    internal let enabled: Bool
    internal let usesLLM: Bool
    internal let lastStatus: String?
    internal let deliver: String?
    internal var health: CronServiceHealth? = nil // swiftlint:disable:this implicit_optional_initialization
    /// The code behind a `cron` node: its `script` / `monitor_script` plus every
    /// path the job declared under `source_files`, each resolved by the gateway
    /// onto a file-browser root so it can be opened with `files.read`. Empty for
    /// every other kind, and for jobs that run no code of their own.
    ///
    /// Node metadata rather than nodes of its own: a script is what a job is
    /// *made of*, not something it exchanges data with, so drawing it as a
    /// resource would clutter the dataflow with edges that carry no data.
    internal var sourceFiles: [CronSourceFile] = []
    /// Present on a `service` node whose declared code the gateway can build a
    /// code knowledge graph for: the `ref` (the service id to pass to
    /// `code.graph`) and a `digest` that changes when the code does — the
    /// change-token a viewer refetches on. `nil` means no code graph is
    /// available (no in-root readable sources), so the "View code graph"
    /// affordance stays hidden. Node metadata, like `sourceFiles`.
    internal var codeGraph: CronServiceCodeGraphRef? = nil // swiftlint:disable:this implicit_optional_initialization
    /// The verified code-control anchor for a `service` node (repository +
    /// revision), when it has one. Undecoded before now; carried so a surface
    /// can show "graph of owner/name @ revision".
    internal var codeControl: CodeGraphProvenance? = nil // swiftlint:disable:this implicit_optional_initialization
    /// Present on a `service` node declared by an architecture manifest on the
    /// gateway: the `ref` for `architecture.describe` plus the cheap status the
    /// graph already knows (source, revision, last check). `nil` for every other
    /// service, so the "View architecture" affordance stays hidden. Node
    /// metadata, like `sourceFiles`: outside the configuration digest.
    internal var architecture: CronServiceArchitectureRef? = nil // swiftlint:disable:this implicit_optional_initialization
    /// Living-artifact fields, present only on an `artifact` node that is a
    /// document in the gateway's artifact store (`artifact:<id>`). `artifactID`
    /// keys `ArtifactStore`, so a node that carries one can be opened; `rev` /
    /// `updatedAt` / `updatedBy` are runtime observations of the last write
    /// (`cron:<jobId>` / `session:<id>` / `agent`) and stay out of the
    /// configuration digest like `health`; `maintainers` is what the artifact's
    /// own content declares (`["cron:<jobId>", …]`), which reaches the digest
    /// through the `maintains` edges the gateway draws from it.
    internal var artifactID: String? = nil // swiftlint:disable:this implicit_optional_initialization
    internal var artifactKind: String? = nil // swiftlint:disable:this implicit_optional_initialization
    internal var rev: Int? = nil // swiftlint:disable:this implicit_optional_initialization
    internal var updatedAt: String? = nil // swiftlint:disable:this implicit_optional_initialization
    internal var updatedBy: String? = nil // swiftlint:disable:this implicit_optional_initialization
    internal var maintainers: [String] = []

    /// The declared maintainers, parsed: a bare entry is a cron job id, a
    /// `type:value` entry keeps its type (`MaintainerRef`).
    internal var maintainerRefs: [MaintainerRef] { maintainers.compactMap(MaintainerRef.init) }

    /// Whether this is a living artifact — one the artifact store can open.
    internal var isLivingArtifact: Bool { kind == "artifact" && !(artifactID ?? "").isEmpty }

    /// `updatedAt` as a date, when the gateway sent one it could parse.
    internal var updatedAtDate: Date? { updatedAt.flatMap(LivingArtifact.parseISO) }

    /// The wiki page addressed by a `wiki:<path>` resource. Cron declarations
    /// omit the Markdown extension (`wiki:reports/daily`), while `wiki.page`
    /// consumes the repository-relative file path (`reports/daily.md`).
    internal var wikiPagePath: String? {
        guard type == "wiki", id.hasPrefix("wiki:") else { return nil }
        let value = String(id.dropFirst("wiki:".count))
        guard !value.isEmpty else { return nil }
        return value.hasSuffix(".md") ? value : "\(value).md"
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, type, label, description, schedule, enabled, usesLLM, lastStatus, deliver, health
        case sourceFiles, codeGraph, codeControl, architecture
        case artifactID, artifactKind, rev, updatedAt, updatedBy, maintainers
    }

    internal init(
        id: String,
        kind: String,
        type: String,
        label: String,
        description: String,
        schedule: String?,
        enabled: Bool,
        usesLLM: Bool,
        lastStatus: String?,
        deliver: String?,
        health: CronServiceHealth? = nil,
        sourceFiles: [CronSourceFile] = [],
        codeGraph: CronServiceCodeGraphRef? = nil,
        codeControl: CodeGraphProvenance? = nil,
        architecture: CronServiceArchitectureRef? = nil,
        artifactID: String? = nil,
        artifactKind: String? = nil,
        rev: Int? = nil,
        updatedAt: String? = nil,
        updatedBy: String? = nil,
        maintainers: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.type = type
        self.label = label
        self.description = description
        self.schedule = schedule
        self.enabled = enabled
        self.usesLLM = usesLLM
        self.lastStatus = lastStatus
        self.deliver = deliver
        self.health = health
        self.sourceFiles = sourceFiles
        self.codeGraph = codeGraph
        self.codeControl = codeControl
        self.architecture = architecture
        self.artifactID = artifactID
        self.artifactKind = artifactKind
        self.rev = rev
        self.updatedAt = updatedAt
        self.updatedBy = updatedBy
        self.maintainers = maintainers
    }

    /// Tolerates a snapshot written before `sourceFiles` existed: the revision
    /// log persists whole graphs (`CronGraphRevisionStore`), and a log that
    /// fails to decode starts over — losing every observed revision for the
    /// sake of one absent key would be the wrong trade.
    internal init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(String.self, forKey: .kind)
        type = try container.decode(String.self, forKey: .type)
        label = try container.decode(String.self, forKey: .label)
        description = try container.decode(String.self, forKey: .description)
        schedule = try container.decodeIfPresent(String.self, forKey: .schedule)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        usesLLM = try container.decode(Bool.self, forKey: .usesLLM)
        lastStatus = try container.decodeIfPresent(String.self, forKey: .lastStatus)
        deliver = try container.decodeIfPresent(String.self, forKey: .deliver)
        health = try container.decodeIfPresent(CronServiceHealth.self, forKey: .health)
        sourceFiles = try container.decodeIfPresent([CronSourceFile].self, forKey: .sourceFiles) ?? []
        codeGraph = try container.decodeIfPresent(CronServiceCodeGraphRef.self, forKey: .codeGraph)
        codeControl = try container.decodeIfPresent(CodeGraphProvenance.self, forKey: .codeControl)
        architecture = try container.decodeIfPresent(CronServiceArchitectureRef.self, forKey: .architecture)
        artifactID = try container.decodeIfPresent(String.self, forKey: .artifactID)
        artifactKind = try container.decodeIfPresent(String.self, forKey: .artifactKind)
        rev = try container.decodeIfPresent(Int.self, forKey: .rev)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        updatedBy = try container.decodeIfPresent(String.self, forKey: .updatedBy)
        maintainers = try container.decodeIfPresent([String].self, forKey: .maintainers) ?? []
    }
}

/// The pointer a `service` node carries to its architecture model. `ref` is
/// the argument for `architecture.describe`; the rest is what the gateway knew
/// cheaply when it built the graph, so the node can say "local · 62911e4 ·
/// check passed" before the model is opened.
internal struct CronServiceArchitectureRef: Hashable, Codable {
    internal let ref: String
    internal let source: String
    internal let revision: String
    internal let checkStatus: String?
    internal let snapshots: Int
    /// Whether the model conforms to the hermes.architecture contract the
    /// gateway validates against; `.unknown` from a gateway that predates it.
    internal var conformance: CronServiceArchitectureConformance = .unknown
    /// The contract version the gateway validated against (`1.0`), when it said.
    internal var contractVersion: String? = nil // swiftlint:disable:this implicit_optional_initialization

    internal init(ref: String, source: String, revision: String, checkStatus: String?, snapshots: Int,
                  conformance: CronServiceArchitectureConformance = .unknown, contractVersion: String? = nil) {
        self.ref = ref
        self.source = source
        self.revision = revision
        self.checkStatus = checkStatus
        self.snapshots = snapshots
        self.conformance = conformance
        self.contractVersion = contractVersion
    }

    private enum CodingKeys: String, CodingKey {
        case ref, source, revision, checkStatus, snapshots, conformance, contractVersion
    }

    internal init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ref = try container.decode(String.self, forKey: .ref)
        source = try container.decode(String.self, forKey: .source)
        revision = try container.decode(String.self, forKey: .revision)
        checkStatus = try container.decodeIfPresent(String.self, forKey: .checkStatus)
        snapshots = try container.decode(Int.self, forKey: .snapshots)
        // Older local snapshots predate the contract: absent means unknown, not an error.
        conformance = try container.decodeIfPresent(CronServiceArchitectureConformance.self, forKey: .conformance) ?? .unknown
        contractVersion = try container.decodeIfPresent(String.self, forKey: .contractVersion)
    }

    internal static func decodeGatewayValue(_ value: AnyCodable) -> CronServiceArchitectureRef? {
        guard let d = value.dictionaryValue, let ref = d["ref"]?.stringValue, !ref.isEmpty else { return nil }
        return CronServiceArchitectureRef(
            ref: ref,
            source: d["source"]?.stringValue ?? "local",
            revision: d["revision"]?.stringValue ?? "",
            checkStatus: d["check"]?.dictionaryValue?["status"]?.stringValue,
            snapshots: d["snapshots"]?.intValue ?? 0,
            conformance: CronServiceArchitectureConformance(gatewayValue: d["conforming"]),
            contractVersion: d["contract"]?.dictionaryValue?["version"]?.stringValue
        )
    }
}

/// What the gateway said about a model against the hermes.architecture contract.
internal enum CronServiceArchitectureConformance: String, Hashable, Codable {
    /// The gateway predates the contract, or did not say.
    case unknown
    case conforming
    case nonConforming

    internal init(gatewayValue: AnyCodable?) {
        switch gatewayValue?.boolValue {
        case .some(true): self = .conforming
        case .some(false): self = .nonConforming
        case .none: self = .unknown
        }
    }
}

/// The pointer a `service` cron node carries to its code knowledge graph.
/// `ref` is the argument for `code.graph`; `digest` is the content change-token.
internal struct CronServiceCodeGraphRef: Hashable, Codable {
    internal let ref: String
    internal let digest: String
}

/// One file of the code behind a cron job, as the gateway resolved it.
///
/// `role` says how the job came to have it: `script` (the job's `script`
/// field — for a no-agent job this *is* the job), `monitor` (its
/// `monitor_script`), or `declared` (listed by the creating agent under
/// `source_files`). `root` + `relativePath` address it for `files.read` when
/// the file lives under a browsable root; both nil means it's listed but not
/// openable from here. `exists` is the gateway host's view at graph-build time.
internal struct CronSourceFile: Identifiable, Hashable, Codable {
    /// Absolute path on the gateway host — the identity.
    internal let path: String
    /// The value as written on the job (`ingest.py`, `~/x.sh`, …).
    internal let declared: String
    internal let role: String
    internal let root: String?
    internal let relativePath: String?
    internal let exists: Bool

    internal var id: String { path }

    /// Leaf name for display.
    internal var fileName: String { (path as NSString).lastPathComponent }

    /// The directory the file sits in, relative to its root — what a folder
    /// disclosure lists. Empty for a file at the root's top level, nil when the
    /// file isn't under any root.
    internal var relativeDirectory: String? {
        guard let relativePath else { return nil }
        return (relativePath as NSString).deletingLastPathComponent
    }

    /// Whether the client can ask the gateway for its contents.
    internal var isOpenable: Bool { root != nil && relativePath != nil }

    /// Roles sort mechanical-first so what the scheduler actually executes
    /// leads the list, then what the agent said it also touches.
    internal var roleRank: Int {
        switch role {
        case "script": return 0
        case "monitor": return 1
        default: return 2
        }
    }

    internal static func decodeGatewayValue(_ value: AnyCodable) -> CronSourceFile? {
        guard let d = value.dictionaryValue,
              let path = d["path"]?.stringValue, !path.isEmpty else { return nil }
        return CronSourceFile(
            path: path,
            declared: d["declared"]?.stringValue ?? path,
            role: d["role"]?.stringValue ?? "declared",
            root: d["root"]?.stringValue,
            relativePath: d["rel"]?.stringValue,
            exists: d["exists"]?.boolValue ?? false
        )
    }
}

/// Source files bucketed by the browse root they open under — how the explorer
/// lists them, one disclosure group per root with the unopenable leftovers
/// last under a nil root.
internal struct CronSourceFileGroup: Identifiable, Equatable {
    internal let root: String?
    internal let files: [CronSourceFile]

    internal var id: String { root ?? "\u{1}outside" }

    /// Group `files` by root, roots alphabetical, the rootless group last;
    /// within a group mechanical roles lead and ties break on path.
    internal static func grouping(_ files: [CronSourceFile]) -> [CronSourceFileGroup] {
        var byRoot: [String?: [CronSourceFile]] = [:]
        for file in files {
            byRoot[file.root, default: []].append(file)
        }
        let sortedRoots = byRoot.keys.sorted { lhs, rhs in
            switch (lhs, rhs) {
            case let (l?, r?): return l < r
            case (nil, _): return false
            case (_, nil): return true
            }
        }
        return sortedRoots.map { root in
            let members = (byRoot[root] ?? []).sorted {
                ($0.roleRank, $0.path) < ($1.roleRank, $1.path)
            }
            return CronSourceFileGroup(root: root, files: members)
        }
    }
}

/// Runtime evidence attached only to service nodes. A status is application
/// health when an explicit probe exists, otherwise supervisor liveness.
internal struct CronServiceHealth: Hashable, Codable {
    internal let status: String
    internal let probe: String
    internal let target: String
    internal let checkedAt: String
    internal let latencyMilliseconds: Double
    internal let message: String

    internal var isHealthy: Bool { status == "healthy" }
    internal var isUnhealthy: Bool { status == "unhealthy" }
}

/// A typed directed edge. Types: `reads` (source/artifact → cron), `writes`
/// (cron → artifact), `maintains` (cron → living artifact whose content names
/// the job), `feeds` (cron → cron, via a `cron-output:<id>` input),
/// a side-effect scheme (`telegram`, `pr`, …) for a cron → sink edge, or an
/// explicit subject-predicate-object edge whose wire class is `relationship`.
internal struct CronGraphEdge: Identifiable, Hashable, Codable {
    internal var id: String { "\(source)->\(target):\(type)" }
    internal let source: String
    internal let target: String
    internal let type: String
    internal let edgeClass: String?

    internal init(source: String, target: String, type: String, edgeClass: String? = nil) {
        self.source = source
        self.target = target
        self.type = type
        self.edgeClass = edgeClass
    }

    private enum CodingKeys: String, CodingKey {
        case source, target, type
        case edgeClass = "class"
    }
}

/// `Codable` here is for **local persistence only** — the revision log stores a
/// snapshot per observed commitment (`CronGraphRevision`). The gateway response
/// is not decoded through it: that path is `decodeGatewayValue(_:)`, which reads
/// the wire's own key names and tolerates its omissions.
///
/// `Equatable` is what lets `CronGraphRevision` synthesize its own — comparing
/// two revisions is comparing the graphs they hold. Synthesized: both member
/// types are already `Hashable`.
internal struct CronGraph: Codable, Equatable {
    internal let nodes: [CronGraphNode]
    internal let edges: [CronGraphEdge]

    internal static let empty = CronGraph(nodes: [], edges: [])

    internal var isEmpty: Bool { nodes.isEmpty }

    internal static func decodeGatewayValue(_ value: AnyCodable) throws -> CronGraph {
        guard let dict = value.dictionaryValue,
              let nodesArray = dict["nodes"]?.arrayValue,
              let edgesArray = dict["edges"]?.arrayValue else {
            throw GatewayError.invalidResponse("cron.graph missing nodes/edges arrays")
        }

        let nodes: [CronGraphNode] = nodesArray.compactMap { item in
            guard let d = item.dictionaryValue,
                  let id = d["id"]?.stringValue, !id.isEmpty,
                  let kind = d["kind"]?.stringValue else { return nil }
            let health: CronServiceHealth?
            if let h = d["health"]?.dictionaryValue,
               let status = h["status"]?.stringValue {
                health = CronServiceHealth(
                    status: status,
                    probe: h["probe"]?.stringValue ?? "unknown",
                    target: h["target"]?.stringValue ?? "",
                    checkedAt: h["checked_at"]?.stringValue ?? "",
                    latencyMilliseconds: h["latency_ms"]?.doubleValue ?? 0,
                    message: h["message"]?.stringValue ?? ""
                )
            } else {
                health = nil
            }
            let sourceFiles = (d["source_files"]?.arrayValue ?? []).compactMap(CronSourceFile.decodeGatewayValue)
            var codeGraph: CronServiceCodeGraphRef?
            if let cg = d["code_graph"]?.dictionaryValue,
               let ref = cg["ref"]?.stringValue {
                codeGraph = CronServiceCodeGraphRef(ref: ref, digest: cg["digest"]?.stringValue ?? "")
            }
            let codeControl = d["code_control"].flatMap(CodeGraphProvenance.decodeGatewayValue)
            let architecture = d["architecture"].flatMap(CronServiceArchitectureRef.decodeGatewayValue)
            // Living-artifact fields: an empty string on the wire means "not said".
            func nonEmpty(_ key: String) -> String? {
                guard let text = d[key]?.stringValue, !text.isEmpty else { return nil }
                return text
            }
            let maintainers = (d["maintainers"]?.arrayValue ?? []).compactMap { entry -> String? in
                guard let text = entry.stringValue, !text.isEmpty else { return nil }
                return text
            }
            return CronGraphNode(
                id: id,
                kind: kind,
                type: d["type"]?.stringValue ?? kind,
                label: d["label"]?.stringValue ?? id,
                description: d["description"]?.stringValue ?? "",
                schedule: d["schedule"]?.stringValue,
                enabled: d["enabled"]?.boolValue ?? true,
                usesLLM: d["uses_llm"]?.boolValue ?? false,
                lastStatus: d["last_status"]?.stringValue,
                deliver: d["deliver"]?.stringValue,
                health: health,
                sourceFiles: sourceFiles,
                codeGraph: codeGraph,
                codeControl: codeControl,
                architecture: architecture,
                artifactID: nonEmpty("artifact_id"),
                artifactKind: nonEmpty("artifact_kind"),
                rev: d["rev"]?.intValue,
                updatedAt: nonEmpty("updated_at"),
                updatedBy: nonEmpty("updated_by"),
                maintainers: maintainers
            )
        }

        let edges: [CronGraphEdge] = edgesArray.compactMap { item in
            guard let d = item.dictionaryValue,
                  let source = d["source"]?.stringValue,
                  let target = d["target"]?.stringValue else { return nil }
            return CronGraphEdge(
                source: source,
                target: target,
                type: d["type"]?.stringValue ?? "reads",
                edgeClass: d["class"]?.stringValue
            )
        }
        return CronGraph(nodes: nodes, edges: edges)
    }
}

// MARK: - Per-job dataflow projection

/// One endpoint in a single job's dataflow: a resource it reads, an artifact it
/// writes, a sink it drives, or another cron in its feed chain. `kind` drives the
/// chip color (matching the graph's node palette); `type` is the fine-grained
/// scheme shown as a badge (`https`, `wiki`, `telegram`, `pr`, …).
internal struct CronDataflowEndpoint: Identifiable, Hashable {
    internal let id: String
    internal let label: String
    internal let kind: String
    internal let type: String
}

/// A single cron's inputs, outputs, and side effects, projected from the graph
/// edges — the same relationships the interflow graph draws, gathered for one job
/// so a cron card can list its own dataflow without holding the whole graph.
internal struct CronJobDataflow: Equatable {
    internal var reads: [CronDataflowEndpoint] = []
    internal var writes: [CronDataflowEndpoint] = []
    /// Living artifacts whose content names this job as a maintainer.
    internal var maintains: [CronDataflowEndpoint] = []
    internal var sideEffects: [CronDataflowEndpoint] = []
    /// Downstream crons that consume this job's output.
    internal var feeds: [CronDataflowEndpoint] = []
    /// Upstream crons whose output this job consumes.
    internal var fedBy: [CronDataflowEndpoint] = []

    internal static let empty = CronJobDataflow()

    internal var isEmpty: Bool {
        reads.isEmpty && writes.isEmpty && maintains.isEmpty && sideEffects.isEmpty && feeds.isEmpty && fedBy.isEmpty
    }
}

extension CronGraph {
    /// Project the graph onto one cron: resolve every edge touching `cronID` into
    /// a typed endpoint (reads / writes / maintains / side-effect / feeds), skipping edges
    /// whose far end isn't a known node. Endpoints dedupe within each bucket,
    /// preserving first-seen order.
    internal func dataflow(forCronID cronID: String) -> CronJobDataflow {
        guard !cronID.isEmpty else { return .empty }
        let nodeByID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var flow = CronJobDataflow()
        var seen: Set<String> = []

        func endpoint(_ node: CronGraphNode, typeOverride: String? = nil) -> CronDataflowEndpoint {
            CronDataflowEndpoint(id: node.id, label: node.label, kind: node.kind, type: typeOverride ?? node.type)
        }
        func add(_ endpoint: CronDataflowEndpoint, to bucket: inout [CronDataflowEndpoint], key: String) {
            guard seen.insert("\(key)\u{1}\(endpoint.id)").inserted else { return }
            bucket.append(endpoint)
        }

        for edge in edges {
            if edge.edgeClass == "relationship" { continue }
            switch edge.type {
            case "reads":
                guard edge.target == cronID, let node = nodeByID[edge.source] else { continue }
                add(endpoint(node), to: &flow.reads, key: "reads")
            case "writes":
                guard edge.source == cronID, let node = nodeByID[edge.target] else { continue }
                add(endpoint(node), to: &flow.writes, key: "writes")
            case "maintains":
                // Tending a living artifact is dataflow, not a delivery: it must
                // not fall into the side-effect bucket below.
                guard edge.source == cronID, let node = nodeByID[edge.target] else { continue }
                add(endpoint(node), to: &flow.maintains, key: "maintains")
            case "feeds":
                if edge.source == cronID, let node = nodeByID[edge.target] {
                    add(endpoint(node), to: &flow.feeds, key: "feeds")
                } else if edge.target == cronID, let node = nodeByID[edge.source] {
                    add(endpoint(node), to: &flow.fedBy, key: "fedBy")
                }
            default:
                // Every other type is a side-effect scheme (telegram / pr / …) on a
                // cron → sink edge; the edge type is the scheme, so it wins over the
                // sink node's generic type for the badge.
                guard edge.source == cronID, let node = nodeByID[edge.target] else { continue }
                add(endpoint(node, typeOverride: edge.type), to: &flow.sideEffects, key: "side")
            }
        }
        return flow
    }
}

// MARK: - Living-artifact actors

extension CronGraph {
    /// A readable name for who wrote or maintains a living artifact, from the
    /// `updated_by` / `maintainers` vocabulary: `cron:<jobId>` resolves to the
    /// job node's label when the graph has that job (else the bare id — a
    /// maintainer naming a deleted job stays visible rather than vanishing),
    /// `session:<id>` reads "session <id>", and a bare word such as `agent` is
    /// shown as itself.
    internal func actorLabel(for ref: String) -> String {
        guard let parsed = MaintainerRef(ref) else { return ref }
        switch parsed {
        case .cron(let jobID):
            return nodes.first { $0.id == jobID && $0.kind == "cron" }?.label ?? jobID
        case .other(let type, let value):
            return "\(type) \(value)"
        }
    }

    /// The maintainer chips for a node: one label per declared maintainer, in
    /// declaration order, resolved through `actorLabel(for:)`.
    internal func maintainerLabels(for node: CronGraphNode) -> [String] {
        node.maintainerRefs.map { actorLabel(for: $0.raw) }
    }
}
