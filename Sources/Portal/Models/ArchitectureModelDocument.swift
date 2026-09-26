import Foundation

// MARK: - Architecture models (architecture.describe)

/// The service an architecture model describes, as the gateway reports it from
/// the manifest under `~/.hermes/services/architecture/`. `source` is `local`
/// (a checkout the gateway can reach, pushed or not) or `github` (a repository
/// at a ref); Portal treats the two identically except that only a local
/// service can have its `--check` run from here.
internal struct ArchitectureServiceRef: Hashable {
    internal let id: String
    internal let label: String
    internal let description: String
    internal let source: String
    internal let root: String?
    internal let repository: String?
    internal let ref: String?
    internal let modelPath: String
    internal let checkConfigured: Bool
    /// The log sinks the manifest declares (local services); empty when none.
    internal let logs: [ArchitectureLogSink]

    internal init(id: String, label: String, description: String, source: String, root: String?, repository: String?,
                  ref: String?, modelPath: String, checkConfigured: Bool, logs: [ArchitectureLogSink] = []) {
        self.id = id
        self.label = label
        self.description = description
        self.source = source
        self.root = root
        self.repository = repository
        self.ref = ref
        self.modelPath = modelPath
        self.checkConfigured = checkConfigured
        self.logs = logs
    }

    internal var isLocal: Bool { source == "local" }

    /// Where the model came from, for a caption: the checkout path or `owner/name @ ref`.
    internal var origin: String {
        if let repository, !repository.isEmpty {
            return ref.map { "\(repository) @ \($0)" } ?? repository
        }
        return root ?? source
    }

    internal static func decodeGatewayValue(_ value: AnyCodable) -> ArchitectureServiceRef? {
        guard let d = value.dictionaryValue, let id = d["id"]?.stringValue, !id.isEmpty else { return nil }
        return ArchitectureServiceRef(
            id: id,
            label: d["label"]?.stringValue ?? id,
            description: d["description"]?.stringValue ?? "",
            source: d["source"]?.stringValue ?? "local",
            root: d["root"]?.stringValue,
            repository: d["repository"]?.stringValue,
            ref: d["ref"]?.stringValue,
            modelPath: d["model_path"]?.stringValue ?? "architecture/model/model.json",
            checkConfigured: d["check_configured"]?.boolValue ?? false,
            logs: ArchitectureLogSink.decodeList(d["logs"])
        )
    }
}

/// One run of a service's own `--check` (`architecture.check`): `passed`,
/// `failed` (non-zero exit) or `unavailable` (not local, no check declared,
/// spawn failure or timeout — `reason` says which).
internal struct ArchitectureCheckResult: Hashable {
    internal let status: String
    internal let exitCode: Int?
    internal let output: String
    internal let reason: String
    internal let checkedAt: String
    internal let revision: String
    internal let durationSeconds: Double

    internal var passed: Bool { status == "passed" }
    internal var ran: Bool { status == "passed" || status == "failed" }

    /// The tooltip behind the status badge: when, at what revision, and the
    /// command's own words — the tail of its output, or why it could not run.
    internal var detail: String {
        var lines = ["Last check: \(status)"]
        if !checkedAt.isEmpty { lines.append("at \(checkedAt)") }
        if !revision.isEmpty { lines.append("revision \(revision)") }
        if let exitCode { lines.append("exit \(exitCode)") }
        if !reason.isEmpty { lines.append(reason) }
        if !output.isEmpty { lines.append(output) }
        return lines.joined(separator: "\n")
    }

    internal static func decodeGatewayValue(_ value: AnyCodable) -> ArchitectureCheckResult? {
        guard let d = value.dictionaryValue, let status = d["status"]?.stringValue else { return nil }
        return ArchitectureCheckResult(
            status: status,
            exitCode: d["exit_code"]?.intValue,
            output: d["output"]?.stringValue ?? "",
            reason: d["reason"]?.stringValue ?? "",
            checkedAt: d["checked_at"]?.stringValue ?? "",
            revision: d["revision"]?.stringValue ?? "",
            durationSeconds: d["duration_s"]?.doubleValue ?? 0
        )
    }
}

/// The counts a model carries, derived by the gateway so a node can show them
/// without the client loading the model.
internal struct ArchitectureModelSummary: Hashable {
    internal let schemaVersion: String
    internal let title: String
    internal let components: Int
    internal let files: Int
    internal let lines: Int
    internal let nodes: Int
    internal let edges: Int
    internal let flows: Int
    internal let invariantsTotal: Int
    internal let invariantsHolding: Int
    internal let violated: [String]
    internal let stores: Int
    internal let externals: Int
    internal let gates: Int
    internal let ratchets: Int
    internal let workflows: Int

    internal var allInvariantsHold: Bool { violated.isEmpty }

    /// Every count on one line, for the header's tooltip.
    internal var detailLine: String {
        let violatedNote = violated.isEmpty ? "" : " (violated: \(violated.joined(separator: ", ")))"
        return "\(components) components · \(files) files · \(lines) lines · \(nodes) nodes · \(edges) edges · \(flows) flows · "
            + "\(invariantsHolding)/\(invariantsTotal) invariants\(violatedNote) · \(stores) stores · \(externals) externals · "
            + "\(gates) gates · \(ratchets) ratchets · \(workflows) workflows"
    }

    internal static let empty = ArchitectureModelSummary(
        schemaVersion: "", title: "", components: 0, files: 0, lines: 0, nodes: 0, edges: 0, flows: 0,
        invariantsTotal: 0, invariantsHolding: 0, violated: [], stores: 0, externals: 0, gates: 0, ratchets: 0, workflows: 0
    )

    internal static func decodeGatewayValue(_ value: AnyCodable) -> ArchitectureModelSummary {
        guard let d = value.dictionaryValue else { return .empty }
        let invariants = d["invariants"]?.dictionaryValue ?? [:]
        return ArchitectureModelSummary(
            schemaVersion: d["schema_version"]?.stringValue ?? "",
            title: d["title"]?.stringValue ?? "",
            components: d["components"]?.intValue ?? 0,
            files: d["files"]?.intValue ?? 0,
            lines: d["lines"]?.intValue ?? 0,
            nodes: d["nodes"]?.intValue ?? 0,
            edges: d["edges"]?.intValue ?? 0,
            flows: d["flows"]?.intValue ?? 0,
            invariantsTotal: invariants["total"]?.intValue ?? 0,
            invariantsHolding: invariants["holds"]?.intValue ?? 0,
            violated: (invariants["violated"]?.arrayValue ?? []).compactMap(\.stringValue),
            stores: d["stores"]?.intValue ?? 0,
            externals: d["externals"]?.intValue ?? 0,
            gates: d["gates"]?.intValue ?? 0,
            ratchets: d["ratchets"]?.intValue ?? 0,
            workflows: d["workflows"]?.intValue ?? 0
        )
    }
}

/// The contract a document was validated against on the gateway
/// (`hermes.architecture`, semver). Absent from gateways that predate the
/// contract; Portal then treats the document as unvalidated 1.x.
internal struct ArchitectureContractRef: Hashable {
    internal let name: String
    internal let version: String
    internal let major: Int
    internal let minor: Int
    internal let schemaDigest: String?

    internal static let unknown = ArchitectureContractRef(name: "hermes.architecture", version: "", major: 0, minor: 0, schemaDigest: nil)

    /// Whether the gateway said which contract it validated against.
    internal var isKnown: Bool { major > 0 }

    /// `hermes.architecture v1.0`, or `unvalidated` for an older gateway.
    internal var caption: String { isKnown ? "\(name) v\(version)" : "unvalidated (gateway predates the contract)" }

    internal static func decodeGatewayValue(_ value: AnyCodable?) -> ArchitectureContractRef {
        guard let d = value?.dictionaryValue, let name = d["name"]?.stringValue else { return .unknown }
        let version = d["version"]?.stringValue ?? ""
        let parts = version.split(separator: ".").map { Int($0) ?? 0 }
        return ArchitectureContractRef(
            name: name,
            version: version,
            major: d["major"]?.intValue ?? parts.first ?? 0,
            minor: d["minor"]?.intValue ?? (parts.count > 1 ? parts[1] : 0),
            schemaDigest: d["schema_digest"]?.stringValue
        )
    }
}

/// The sections a conforming document carries. The five the contract requires
/// are always present on a validated document; `stores` and `externals` are
/// optional, so the surface derives what it shows from what is there.
internal enum ArchitectureSection: String, CaseIterable, Hashable {
    case components
    case interplay
    case extraction
    case ci
    case inventory
    case stores
    case externals

    internal static let required: [ArchitectureSection] = [.components, .interplay, .extraction, .ci, .inventory]
}

/// What `architecture.describe` returns: the service, the revision the model
/// was read at, its summary, the last check, the contract it conforms to, and
/// the model itself — both as the decoded value the native renderers read and
/// as the JSON the observatory web renderer consumes.
internal struct ArchitectureModelDocument: Hashable {
    internal let service: ArchitectureServiceRef
    internal let revision: String
    internal let source: String
    internal let storedAt: String?
    internal let summary: ArchitectureModelSummary
    internal var check: ArchitectureCheckResult?
    internal let contract: ArchitectureContractRef
    internal let model: AnyCodable
    internal let modelJSON: String
    /// Whether this is the service's latest stored revision (a describe with a
    /// `revision` may return an older snapshot). Absent from older gateways: latest.
    internal let isLatest: Bool

    internal init(service: ArchitectureServiceRef, revision: String, source: String, storedAt: String?, summary: ArchitectureModelSummary,
                  check: ArchitectureCheckResult?, contract: ArchitectureContractRef, model: AnyCodable, modelJSON: String, isLatest: Bool = true) {
        self.service = service
        self.revision = revision
        self.source = source
        self.storedAt = storedAt
        self.summary = summary
        self.check = check
        self.contract = contract
        self.model = model
        self.modelJSON = modelJSON
        self.isLatest = isLatest
    }

    // `AnyCodable` is not Hashable; the JSON text is the model's identity (sorted
    // keys, so equal models serialize identically), which keeps the document
    // Hashable for SwiftUI state without hashing the whole tree twice.
    internal static func == (lhs: ArchitectureModelDocument, rhs: ArchitectureModelDocument) -> Bool {
        lhs.service == rhs.service && lhs.revision == rhs.revision && lhs.source == rhs.source
            && lhs.storedAt == rhs.storedAt && lhs.summary == rhs.summary && lhs.check == rhs.check
            && lhs.contract == rhs.contract && lhs.modelJSON == rhs.modelJSON && lhs.isLatest == rhs.isLatest
    }

    internal func hash(into hasher: inout Hasher) {
        hasher.combine(service)
        hasher.combine(revision)
        hasher.combine(source)
        hasher.combine(storedAt)
        hasher.combine(summary)
        hasher.combine(check)
        hasher.combine(contract)
        hasher.combine(modelJSON)
        hasher.combine(isLatest)
    }

    /// The sections present on the model, in contract order.
    internal var sections: [ArchitectureSection] {
        let keys = model.dictionaryValue ?? [:]
        return ArchitectureSection.allCases.filter { keys[$0.rawValue]?.dictionaryValue != nil || keys[$0.rawValue]?.arrayValue != nil }
    }

    /// The required sections the document lacks: empty for a conforming document.
    internal var missingRequiredSections: [ArchitectureSection] {
        let present = Set(sections)
        return ArchitectureSection.required.filter { !present.contains($0) }
    }

    internal func has(_ section: ArchitectureSection) -> Bool {
        sections.contains(section)
    }

    /// One section of the model as a dictionary, for a native section renderer.
    internal func section(_ section: ArchitectureSection) -> [String: AnyCodable]? {
        model.dictionaryValue?[section.rawValue]?.dictionaryValue
    }

    /// What the service is and where its model comes from, for the title's tooltip.
    internal var tooltip: String {
        var lines = [service.description]
        let title = summary.title.isEmpty ? "architecture model" : summary.title
        lines.append("\(title) · schema \(summary.schemaVersion.isEmpty ? "?" : summary.schemaVersion)")
        lines.append("\(service.modelPath) at \(revision) (\(source))")
        if let storedAt { lines.append("stored \(storedAt)") }
        lines.append("contract \(contract.caption)")
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// A git head abbreviated; a digest or ref name left whole.
    internal var shortRevision: String {
        let isHex = revision.count >= 40 && revision.allSatisfy(\.isHexDigit)
        return isHex ? String(revision.prefix(9)) : revision
    }

    internal static func decodeGatewayValue(_ value: AnyCodable) throws -> ArchitectureModelDocument {
        guard let d = value.dictionaryValue,
              let serviceValue = d["service"],
              let service = ArchitectureServiceRef.decodeGatewayValue(serviceValue),
              let model = d["model"], model.dictionaryValue != nil else {
            throw GatewayError.invalidResponse("architecture.describe missing service or model")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(model)
        guard let modelJSON = String(data: data, encoding: .utf8) else {
            throw GatewayError.invalidResponse("architecture.describe model is not UTF-8 encodable")
        }
        return ArchitectureModelDocument(
            service: service,
            revision: d["revision"]?.stringValue ?? "",
            source: d["source"]?.stringValue ?? service.source,
            storedAt: d["stored_at"]?.stringValue,
            summary: d["summary"].map(ArchitectureModelSummary.decodeGatewayValue) ?? .empty,
            check: d["check"].flatMap(ArchitectureCheckResult.decodeGatewayValue),
            contract: ArchitectureContractRef.decodeGatewayValue(d["contract"]),
            model: model,
            modelJSON: modelJSON,
            isLatest: d["is_latest"]?.boolValue ?? true
        )
    }
}

/// A request to present a service's architecture model, handed from a graph
/// node (the inline dock or the expanded inspector) to the surface that shows it.
/// Carries the service's code-graph reference when it has one, so the surface
/// can offer the code graph from inside the architecture artifact.
internal struct ArchitectureRequest: Identifiable, Hashable {
    internal let service: String
    internal let label: String
    internal let revision: String
    internal let codeGraph: CronServiceCodeGraphRef?

    internal init(service: String, label: String, revision: String, codeGraph: CronServiceCodeGraphRef? = nil) {
        self.service = service
        self.label = label
        self.revision = revision
        self.codeGraph = codeGraph
    }

    internal var id: String { service }

    /// The code-graph request for this service, when the node advertised one.
    internal var codeGraphRequest: CodeGraphRequest? {
        codeGraph.map { CodeGraphRequest(service: $0.ref, label: label, digest: $0.digest) }
    }
}
