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
            checkConfigured: d["check_configured"]?.boolValue ?? false
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

/// What `architecture.describe` returns: the service, the revision the model
/// was read at, its summary, the last check, and the model itself — kept as the
/// JSON the observatory renderer consumes rather than re-modelled natively.
internal struct ArchitectureModelDocument: Hashable {
    internal let service: ArchitectureServiceRef
    internal let revision: String
    internal let source: String
    internal let storedAt: String?
    internal let summary: ArchitectureModelSummary
    internal var check: ArchitectureCheckResult?
    internal let modelJSON: String

    /// What the service is and where its model comes from, for the title's tooltip.
    internal var tooltip: String {
        var lines = [service.description]
        let title = summary.title.isEmpty ? "architecture model" : summary.title
        lines.append("\(title) · schema \(summary.schemaVersion.isEmpty ? "?" : summary.schemaVersion)")
        lines.append("\(service.modelPath) at \(revision) (\(source))")
        if let storedAt { lines.append("stored \(storedAt)") }
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
            modelJSON: modelJSON
        )
    }
}

/// A request to present a service's architecture model, handed from a graph
/// node (the inline dock or the expanded inspector) to the surface that shows it.
internal struct ArchitectureRequest: Identifiable, Hashable {
    internal let service: String
    internal let label: String
    internal let revision: String

    internal var id: String { service }
}
