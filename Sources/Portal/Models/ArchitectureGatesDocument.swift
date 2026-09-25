import Foundation

// MARK: - The `ci` section of the hermes.architecture contract, typed

/// What a job is for in the pipeline. Open: a contract minor may add a role,
/// which decodes as `.custom` rather than failing the whole section.
internal enum ArchitectureGateRole: Hashable {
    case gate
    case postMerge
    case manual
    case disabled
    case local
    case custom(String)

    internal init(rawValue: String) {
        switch rawValue {
        case "gate": self = .gate
        case "post-merge": self = .postMerge
        case "manual": self = .manual
        case "disabled": self = .disabled
        case "local": self = .local
        default: self = .custom(rawValue)
        }
    }

    internal var rawValue: String {
        switch self {
        case .gate: return "gate"
        case .postMerge: return "post-merge"
        case .manual: return "manual"
        case .disabled: return "disabled"
        case .local: return "local"
        case .custom(let value): return value
        }
    }

    /// A job that stands between a change and the merge: a pull-request gate on
    /// GitHub, or a local service's own check that guards its snapshot.
    internal var guardsTheMerge: Bool {
        self == .gate || self == .local
    }

    /// A job that runs once the change is in: after the merge, or disabled but declared.
    internal var runsAfterMerge: Bool {
        self == .postMerge || self == .disabled
    }
}

/// What a wire between two pipeline nodes means.
internal enum ArchitectureGateWireKind: Hashable {
    case needs
    case artifact
    case gates
    case trigger
    case release
    case custom(String)

    internal init(rawValue: String) {
        switch rawValue {
        case "needs": self = .needs
        case "artifact": self = .artifact
        case "gates": self = .gates
        case "trigger": self = .trigger
        case "release": self = .release
        default: self = .custom(rawValue)
        }
    }

    internal var rawValue: String {
        switch self {
        case .needs: return "needs"
        case .artifact: return "artifact"
        case .gates: return "gates"
        case .trigger: return "trigger"
        case .release: return "release"
        case .custom(let value): return value
        }
    }
}

/// A file and line a pipeline fact was read from.
internal struct ArchitectureSourceLine: Hashable {
    internal let path: String
    internal let line: Int

    internal var display: String { "\(path):\(line)" }

    internal static func decode(_ value: AnyCodable?) -> ArchitectureSourceLine? {
        guard let d = value?.dictionaryValue, let path = d["path"]?.stringValue else { return nil }
        return ArchitectureSourceLine(path: path, line: d["line"]?.intValue ?? 0)
    }
}

/// One step of a job: a `run:` command or a `uses:` action, with its line.
internal struct ArchitectureGateStep: Hashable {
    internal let name: String
    internal let command: String?
    internal let uses: String?
    internal let condition: String?
    internal let line: Int?

    internal static func decode(_ value: AnyCodable) -> ArchitectureGateStep? {
        guard let d = value.dictionaryValue else { return nil }
        let command = d["command"]?.stringValue
        let uses = d["uses"]?.stringValue
        return ArchitectureGateStep(
            name: d["name"]?.stringValue ?? uses ?? command ?? "step",
            command: command,
            uses: uses,
            condition: d["condition"]?.stringValue,
            line: d["line"]?.intValue
        )
    }
}

/// A tool version the job pins through its environment (`SWIFTLINT_VERSION=…`).
internal struct ArchitectureGatePin: Hashable {
    internal let name: String
    internal let value: String

    internal var display: String { "\(name)=\(value)" }

    internal static func decode(_ value: AnyCodable) -> ArchitectureGatePin? {
        if let d = value.dictionaryValue, let name = d["name"]?.stringValue {
            return ArchitectureGatePin(name: name, value: d["value"]?.stringValue ?? "")
        }
        if let text = value.stringValue {
            let parts = text.split(separator: "=", maxSplits: 1).map(String.init)
            return ArchitectureGatePin(name: parts.first ?? text, value: parts.count > 1 ? parts[1] : "")
        }
        return nil
    }
}

/// One job of one workflow: a gate in the circuit.
internal struct ArchitectureGateJob: Hashable, Identifiable {
    internal let id: String
    internal let key: String
    internal let name: String
    internal let workflow: String
    internal let family: String
    internal let role: ArchitectureGateRole
    internal let needs: [String]
    internal let runsOn: String
    internal let condition: String?
    internal let steps: [ArchitectureGateStep]
    internal let stepCount: Int
    internal let scripts: [String]
    internal let artifactsIn: [String]
    internal let artifactsOut: [String]
    internal let pins: [ArchitectureGatePin]
    internal let evidence: ArchitectureSourceLine?

    internal static func decode(_ value: AnyCodable) -> ArchitectureGateJob? {
        guard let d = value.dictionaryValue, let id = d["id"]?.stringValue, !id.isEmpty else { return nil }
        let steps = (d["steps"]?.arrayValue ?? []).compactMap(ArchitectureGateStep.decode)
        return ArchitectureGateJob(
            id: id,
            key: d["key"]?.stringValue ?? id,
            name: d["name"]?.stringValue ?? id,
            workflow: d["workflow"]?.stringValue ?? "",
            family: d["family"]?.stringValue ?? "",
            role: ArchitectureGateRole(rawValue: d["role"]?.stringValue ?? "gate"),
            needs: ArchitectureGatesDocument.strings(d["needs"]),
            runsOn: d["runs_on"]?.stringValue ?? "",
            condition: d["condition"]?.stringValue,
            steps: steps,
            stepCount: d["step_count"]?.intValue ?? steps.count,
            scripts: ArchitectureGatesDocument.strings(d["scripts"]),
            artifactsIn: ArchitectureGatesDocument.strings(d["artifacts_in"]),
            artifactsOut: ArchitectureGatesDocument.strings(d["artifacts_out"]),
            pins: (d["pins"]?.arrayValue ?? []).compactMap(ArchitectureGatePin.decode),
            evidence: ArchitectureSourceLine.decode(d["evidence"])
        )
    }
}

/// A workflow file: the lane its gate jobs are drawn in.
internal struct ArchitectureGateWorkflow: Hashable, Identifiable {
    internal let id: String
    internal let label: String
    internal let name: String
    internal let family: String
    internal let jobs: [String]
    internal let events: [String]
    internal let path: String?
    internal let question: String

    internal static func decode(_ value: AnyCodable) -> ArchitectureGateWorkflow? {
        guard let d = value.dictionaryValue, let id = d["id"]?.stringValue, !id.isEmpty else { return nil }
        return ArchitectureGateWorkflow(
            id: id,
            label: d["label"]?.stringValue ?? id,
            name: d["name"]?.stringValue ?? d["label"]?.stringValue ?? id,
            family: d["family"]?.stringValue ?? "",
            jobs: ArchitectureGatesDocument.strings(d["jobs"]),
            events: ArchitectureGatesDocument.strings(d["events"]),
            path: d["path"]?.stringValue,
            question: d["question"]?.stringValue ?? ""
        )
    }
}

/// A wire of the circuit: `needs`, an artifact hand-off, a gate feeding the
/// merge, an event starting a root job, or a release job after the merge.
internal struct ArchitectureGateWire: Hashable {
    internal let source: String
    internal let target: String
    internal let kind: ArchitectureGateWireKind
    internal let label: String?

    internal static func decode(_ value: AnyCodable) -> ArchitectureGateWire? {
        guard let d = value.dictionaryValue, let source = d["source"]?.stringValue, let target = d["target"]?.stringValue else { return nil }
        return ArchitectureGateWire(
            source: source,
            target: target,
            kind: ArchitectureGateWireKind(rawValue: d["kind"]?.stringValue ?? "needs"),
            label: d["label"]?.stringValue
        )
    }
}

/// An event and the workflows listening to it.
internal struct ArchitectureGateTrigger: Hashable, Identifiable {
    internal let id: String
    internal let event: String
    internal let workflows: [String]

    internal static func decode(_ value: AnyCodable) -> ArchitectureGateTrigger? {
        guard let d = value.dictionaryValue, let id = d["id"]?.stringValue else { return nil }
        return ArchitectureGateTrigger(
            id: id,
            event: d["event"]?.stringValue ?? id,
            workflows: ArchitectureGatesDocument.strings(d["workflows"])
        )
    }
}

/// The AND gate every pull-request gate feeds.
internal struct ArchitectureMergeGate: Hashable {
    internal let id: String
    internal let label: String
    internal let inputs: [String]

    internal static func decode(_ value: AnyCodable?) -> ArchitectureMergeGate? {
        guard let d = value?.dictionaryValue, let id = d["id"]?.stringValue else { return nil }
        return ArchitectureMergeGate(
            id: id,
            label: d["label"]?.stringValue ?? "Merge",
            inputs: ArchitectureGatesDocument.strings(d["inputs"])
        )
    }
}

/// One line of a ratchet's baseline breakdown: a layer's coverage or a category's count.
internal struct ArchitectureRatchetEntry: Hashable {
    internal let key: String
    internal let value: String
}

/// A metric floor CI compares the tree against, with the committed baseline it
/// currently holds.
internal struct ArchitectureRatchet: Hashable, Identifiable {
    internal let id: String
    internal let title: String
    internal let job: String
    internal let measures: String
    internal let floor: String
    internal let patch: String?
    internal let sourcePath: String?
    internal let current: [String: AnyCodable]

    internal static func == (lhs: ArchitectureRatchet, rhs: ArchitectureRatchet) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.job == rhs.job && lhs.measures == rhs.measures
            && lhs.floor == rhs.floor && lhs.patch == rhs.patch && lhs.sourcePath == rhs.sourcePath
            && lhs.currentSummary == rhs.currentSummary && lhs.breakdown == rhs.breakdown
    }

    internal func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(currentSummary)
    }

    internal var currentKind: String { current["kind"]?.stringValue ?? "" }

    /// The baseline on one line: coverage as a percentage over covered/total,
    /// counters as a count of counters, counts as the total (and in how many
    /// categories), anything else as a dash.
    internal var currentSummary: String {
        switch currentKind {
        case "coverage":
            let percent = current["percent"]?.doubleValue ?? 0
            let covered = current["covered"]?.intValue ?? 0
            let count = current["count"]?.intValue ?? 0
            return String(format: "%.2f%% (%@ / %@)", percent, Self.grouped(covered), Self.grouped(count))
        case "counters":
            return "\(current["counts"]?.dictionaryValue?.count ?? 0) counters"
        case "count":
            let total = current["total"]?.intValue ?? 0
            let categories = current["counts"]?.dictionaryValue?.count ?? 0
            guard categories > 0 else { return Self.grouped(total) }
            return "\(Self.grouped(total)) in \(categories) \(id == "lint" ? "rules" : "kinds")"
        default:
            return "—"
        }
    }

    /// The baseline broken down: coverage by layer, counts by category (largest first).
    internal var breakdown: [ArchitectureRatchetEntry] {
        if currentKind == "coverage" {
            let layers = current["layers"]?.dictionaryValue ?? [:]
            return layers.keys.sorted().map { layer in
                let percent = layers[layer]?.dictionaryValue?["percent"]?.doubleValue ?? 0
                return ArchitectureRatchetEntry(key: layer, value: String(format: "%.1f%%", percent))
            }
        }
        guard let counts = current["counts"]?.dictionaryValue else { return [] }
        return counts
            .map { (key: $0.key, count: $0.value.intValue ?? Int($0.value.doubleValue ?? 0)) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.key < $1.key }
            .map { ArchitectureRatchetEntry(key: $0.key, value: Self.grouped($0.count)) }
    }

    internal static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.locale = Locale(identifier: "en_US")
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    internal static func decode(_ value: AnyCodable) -> ArchitectureRatchet? {
        guard let d = value.dictionaryValue, let id = d["id"]?.stringValue else { return nil }
        return ArchitectureRatchet(
            id: id,
            title: d["title"]?.stringValue ?? id,
            job: d["job"]?.stringValue ?? "",
            measures: d["measures"]?.stringValue ?? "",
            floor: d["floor"]?.stringValue ?? "",
            patch: d["patch"]?.stringValue,
            sourcePath: d["source_path"]?.stringValue,
            current: d["current"]?.dictionaryValue ?? [:]
        )
    }
}

/// A check that recompiles an artifact and fails on drift between it and the tree.
internal struct ArchitectureStaticCheck: Hashable, Identifiable {
    internal let name: String
    internal let command: String
    internal let job: String
    internal let scripts: [String]
    internal let evidence: ArchitectureSourceLine?

    internal var id: String { "\(job)#\(name)" }

    internal static func decode(_ value: AnyCodable) -> ArchitectureStaticCheck? {
        guard let d = value.dictionaryValue, let name = d["name"]?.stringValue else { return nil }
        return ArchitectureStaticCheck(
            name: name,
            command: d["command"]?.stringValue ?? "",
            job: d["job"]?.stringValue ?? "",
            scripts: ArchitectureGatesDocument.strings(d["scripts"]),
            evidence: ArchitectureSourceLine.decode(d["evidence"])
        )
    }
}

/// A custom SwiftLint rule the tree must satisfy.
internal struct ArchitectureLintRule: Hashable, Identifiable {
    internal let id: String
    internal let message: String
    internal let severity: String
    internal let baselined: Int
    internal let excludedCount: Int
    internal let evidence: ArchitectureSourceLine?

    internal static func decode(_ value: AnyCodable) -> ArchitectureLintRule? {
        guard let d = value.dictionaryValue, let id = d["id"]?.stringValue else { return nil }
        return ArchitectureLintRule(
            id: id,
            message: d["message"]?.stringValue ?? "",
            severity: d["severity"]?.stringValue ?? "warning",
            baselined: d["baselined"]?.intValue ?? 0,
            excludedCount: d["excluded_count"]?.intValue ?? 0,
            evidence: ArchitectureSourceLine.decode(d["evidence"])
        )
    }
}

/// One architecture test the suite asserts on every run.
internal struct ArchitectureTestCase: Hashable, Identifiable {
    internal let title: String
    internal let evidence: ArchitectureSourceLine?

    internal var id: String { title }

    internal static func decode(_ value: AnyCodable) -> ArchitectureTestCase? {
        guard let d = value.dictionaryValue, let title = d["title"]?.stringValue else { return nil }
        return ArchitectureTestCase(title: title, evidence: ArchitectureSourceLine.decode(d["evidence"]))
    }
}

/// An invariant the compiler checks on every build, and whether it held.
internal struct ArchitectureCheckedInvariant: Hashable, Identifiable {
    internal let id: String
    internal let kind: String
    internal let status: String
    internal let why: String

    internal var holds: Bool { status == "holds" }

    internal static func decode(_ value: AnyCodable) -> ArchitectureCheckedInvariant? {
        guard let d = value.dictionaryValue, let id = d["id"]?.stringValue else { return nil }
        return ArchitectureCheckedInvariant(
            id: id,
            kind: d["kind"]?.stringValue ?? "",
            status: d["status"]?.stringValue ?? "unchecked",
            why: d["why"]?.stringValue ?? ""
        )
    }
}

/// The checks that pin the shape of the code rather than a metric.
internal struct ArchitectureArchitecturalChecks: Hashable {
    internal let lintRules: [ArchitectureLintRule]
    internal let tests: [ArchitectureTestCase]
    internal let invariants: [ArchitectureCheckedInvariant]
    internal let runsIn: [String]
    internal let lintConfig: String?
    internal let testsPath: String?

    internal static let empty = ArchitectureArchitecturalChecks(lintRules: [], tests: [], invariants: [], runsIn: [], lintConfig: nil, testsPath: nil)

    internal var count: Int { lintRules.count + tests.count + invariants.count }

    internal static func decode(_ value: AnyCodable?) -> ArchitectureArchitecturalChecks {
        guard let d = value?.dictionaryValue else { return .empty }
        return ArchitectureArchitecturalChecks(
            lintRules: (d["lint_rules"]?.arrayValue ?? []).compactMap(ArchitectureLintRule.decode),
            tests: (d["tests"]?.arrayValue ?? []).compactMap(ArchitectureTestCase.decode),
            invariants: (d["invariants"]?.arrayValue ?? []).compactMap(ArchitectureCheckedInvariant.decode),
            runsIn: ArchitectureGatesDocument.strings(d["runs_in"]),
            lintConfig: d["lint_config"]?.stringValue,
            testsPath: d["tests_path"]?.stringValue
        )
    }
}

/// The counts the compiler summarised for the section header.
internal struct ArchitectureGatesSummary: Hashable {
    internal let workflows: Int
    internal let jobs: Int
    internal let gates: Int
    internal let ratchets: Int
    internal let staticChecks: Int
    internal let lintRules: Int
    internal let architectureTests: Int
    internal let invariants: Int

    internal var architecturalChecks: Int { lintRules + architectureTests + invariants }

    internal static func decode(_ value: AnyCodable?) -> ArchitectureGatesSummary {
        let d = value?.dictionaryValue ?? [:]
        return ArchitectureGatesSummary(
            workflows: d["workflows"]?.intValue ?? 0,
            jobs: d["jobs"]?.intValue ?? 0,
            gates: d["gates"]?.intValue ?? 0,
            ratchets: d["ratchets"]?.intValue ?? 0,
            staticChecks: d["static_checks"]?.intValue ?? 0,
            lintRules: d["lint_rules"]?.intValue ?? 0,
            architectureTests: d["architecture_tests"]?.intValue ?? 0,
            invariants: d["invariants"]?.intValue ?? 0
        )
    }
}

/// The `ci` section decoded: the circuit (workflows, jobs, wires, triggers, the
/// merge) and what the gates defend (ratchets, architectural checks, static
/// checks), plus the compiler's stated limitations.
internal struct ArchitectureGatesDocument: Hashable {
    internal let workflows: [ArchitectureGateWorkflow]
    internal let jobs: [ArchitectureGateJob]
    internal let wires: [ArchitectureGateWire]
    internal let triggers: [ArchitectureGateTrigger]
    internal let merge: ArchitectureMergeGate?
    internal let ratchets: [ArchitectureRatchet]
    internal let staticChecks: [ArchitectureStaticCheck]
    internal let architectural: ArchitectureArchitecturalChecks
    /// Family id → the question that family of workflows answers.
    internal let families: [String: String]
    internal let limitations: [String]
    internal let summary: ArchitectureGatesSummary

    internal var jobsByID: [String: ArchitectureGateJob] {
        Dictionary(jobs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    internal var workflowsByID: [String: ArchitectureGateWorkflow] {
        Dictionary(workflows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    internal func job(_ id: String) -> ArchitectureGateJob? {
        jobs.first { $0.id == id }
    }

    /// The `ci` section of a model, or nil when the model has none or it names no job.
    internal static func decode(_ section: [String: AnyCodable]?) -> ArchitectureGatesDocument? {
        guard let section else { return nil }
        let jobs = (section["jobs"]?.arrayValue ?? []).compactMap(ArchitectureGateJob.decode)
        guard !jobs.isEmpty else { return nil }
        var families: [String: String] = [:]
        for (family, value) in section["families"]?.dictionaryValue ?? [:] {
            families[family] = value.dictionaryValue?["question"]?.stringValue ?? value.stringValue ?? ""
        }
        return ArchitectureGatesDocument(
            workflows: (section["workflows"]?.arrayValue ?? []).compactMap(ArchitectureGateWorkflow.decode),
            jobs: jobs,
            wires: (section["edges"]?.arrayValue ?? []).compactMap(ArchitectureGateWire.decode),
            triggers: (section["triggers"]?.arrayValue ?? []).compactMap(ArchitectureGateTrigger.decode),
            merge: ArchitectureMergeGate.decode(section["merge"]),
            ratchets: (section["ratchets"]?.arrayValue ?? []).compactMap(ArchitectureRatchet.decode),
            staticChecks: (section["static_checks"]?.arrayValue ?? []).compactMap(ArchitectureStaticCheck.decode),
            architectural: ArchitectureArchitecturalChecks.decode(section["architectural"]),
            families: families,
            limitations: strings(section["limitations"]),
            summary: ArchitectureGatesSummary.decode(section["summary"])
        )
    }

    internal static func strings(_ value: AnyCodable?) -> [String] {
        (value?.arrayValue ?? []).compactMap(\.stringValue)
    }
}
