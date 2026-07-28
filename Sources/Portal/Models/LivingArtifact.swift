import Foundation

/// A named, persistent artifact the agent maintains across turns and
/// sessions — an arbitrary model, not a message. Any fenced block carrying
/// an `"id"` upserts into the store: a Bangkok apartment map, a comparison
/// table refined over days, an infra graph, a decision doc.
///
/// `kind` is the fence language (map/chart/graph/stats/table/markdown/…);
/// rendering dispatches on it exactly like the chat renderer, and merge
/// behavior is per-kind (ArtifactMerge) — maps merge markers by label,
/// everything else replaces content wholesale (models re-emit full blocks).
struct LivingArtifact: Codable, Equatable, Identifiable {
    let id: String
    var kind: String
    var title: String
    /// The raw fence body (JSON for map/chart/graph/stats, markdown for docs).
    var content: String
    var updatedAt: Date
    /// Device that last wrote it (sync conflict visibility, not resolution).
    var updatedBy: String

    /// Server revision number (0 for purely-local artifacts that have
    /// never round-tripped through the gateway).
    var rev: Int = 0

    /// First-class action declarations on the artifact record — the source of
    /// truth for HTML artifacts (which can't embed trusted action declarations
    /// inside page code) and for any kind that wants actions expressed outside
    /// the content fence. Excluded from Codable (disk cache): repopulated
    /// from the gateway on next pull.
    internal var topLevelActions: [ArtifactAction] = []

    // Explicit memberwise init (required once we add CodingKeys for Codable).
    internal init(id: String, kind: String, title: String, content: String,
                  updatedAt: Date, updatedBy: String, rev: Int = 0,
                  topLevelActions: [ArtifactAction] = []) {
        self.id = id; self.kind = kind; self.title = title
        self.content = content; self.updatedAt = updatedAt
        self.updatedBy = updatedBy; self.rev = rev
        self.topLevelActions = topLevelActions
    }

    // Custom Codable to exclude topLevelActions (ArtifactAction is not Codable;
    // it's always re-parsed from the gateway response, never from disk).
    internal enum CodingKeys: String, CodingKey {
        case id, kind, title, content, updatedAt, updatedBy, rev
    }

    internal init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(String.self, forKey: .kind)
        title = try c.decode(String.self, forKey: .title)
        content = try c.decode(String.self, forKey: .content)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        updatedBy = try c.decode(String.self, forKey: .updatedBy)
        rev = try c.decodeIfPresent(Int.self, forKey: .rev) ?? 0
        topLevelActions = []
    }

    internal func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(title, forKey: .title)
        try c.encode(content, forKey: .content)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(updatedBy, forKey: .updatedBy)
        try c.encode(rev, forKey: .rev)
    }

    /// Human label for pickers: title if present, else the id.
    var displayName: String { title.isEmpty ? id : title }

    /// Maintainers declared in the content's top-level `maintainers` array —
    /// the crons (or other agents) that keep this artifact current. Empty for
    /// an artifact that's merely mutable, not actively tended.
    var maintainerRefs: [MaintainerRef] { MaintainerRef.parseList(from: content) }

    /// Whether the content is a JSON object we can write a `maintainers` key
    /// into. Markdown docs aren't, so they can't declare maintainers.
    var supportsMaintainers: Bool {
        guard let data = content.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
    }

    /// Decode from a gateway artifact.* result payload.
    static func from(_ d: [String: AnyCodable]?) -> LivingArtifact? {
        guard let d, let id = d["id"]?.stringValue, !id.isEmpty else { return nil }
        let rawActions: [[String: Any]]? = d["actions"]?.arrayValue?.compactMap { item in
            guard let dict = item.dictionaryValue else { return nil }
            return dict.compactMapValues { v -> Any? in
                switch v {
                case .string(let s): return s
                case .int(let i): return i
                case .double(let n): return n
                case .bool(let b): return b
                case .array(let arr): return arr.compactMap { e -> Any? in
                    if case .string(let s) = e { return s }
                    if case .int(let i) = e { return i }
                    return nil
                }
                case .dictionary(let inner):
                    return inner.compactMapValues { w -> Any? in
                        if case .string(let s) = w { return s }
                        if case .bool(let b) = w { return b }
                        return nil
                    }
                case .null: return nil
                }
            }
        }
        let actions = ArtifactAction.parse(rawActions)
        return LivingArtifact(
            id: id,
            kind: d["kind"]?.stringValue ?? "markdown",
            title: d["title"]?.stringValue ?? "",
            content: d["content"]?.stringValue ?? "",
            updatedAt: d["updated_at"]?.stringValue.flatMap(Self.parseISO) ?? Date(),
            updatedBy: d["updated_by"]?.stringValue ?? "",
            rev: d["rev"]?.intValue ?? 0,
            topLevelActions: actions
        )
    }

    static func parseISO(_ s: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}

/// One entry in an artifact's revision history (audit trail).
struct ArtifactRevision: Identifiable, Equatable {
    let rev: Int
    let updatedAt: Date?
    let updatedBy: String
    /// Present only from artifact.revision (single fetch); the list RPC
    /// omits content.
    let content: String?

    var id: Int { rev }

    static func from(_ d: [String: AnyCodable]?) -> ArtifactRevision? {
        guard let d, let rev = d["rev"]?.intValue else { return nil }
        return ArtifactRevision(
            rev: rev,
            updatedAt: d["updated_at"]?.stringValue.flatMap(LivingArtifact.parseISO),
            updatedBy: d["updated_by"]?.stringValue ?? "",
            content: d["content"]?.stringValue
        )
    }
}

// MARK: - Per-kind merge

/// Merge an incoming fence body into an existing artifact's content.
/// Default is replace — correct for kinds the model re-emits in full.
/// Structured kinds can do better: maps union markers keyed by label, so
/// the agent may emit only the NEW listing and the pins accumulate.
enum ArtifactMerge {

    static func merge(kind: String, existing: String, incoming: String) -> String {
        switch kind {
        case "map":
            return mergeMap(existing: existing, incoming: incoming)
        case "dataset":
            return mergeDataset(existing: existing, incoming: incoming)
        case "model":
            return mergeModel(existing: existing, incoming: incoming)
        default:
            return incoming
        }
    }

    /// Ensemble models: each entity set unions items by its declared key
    /// (incoming wins field-wise, tombstones carried); sets absent from the
    /// incoming block carry over untouched (agents may update one set).
    /// Relations union by (from, to, type). Views/actions/title come from
    /// incoming when present (declarative config — latest wins wholesale).
    static func mergeModel(existing: String, incoming: String) -> String {
        guard let old = parse(existing), let new = parse(incoming) else { return incoming }
        var merged = old.merging(new) { _, n in n }

        let oldSets = (old["entities"] as? [String: [String: Any]]) ?? [:]
        let newSets = (new["entities"] as? [String: [String: Any]]) ?? [:]
        var mergedSets = oldSets
        for (name, newSet) in newSets {
            guard let oldSet = oldSets[name] else {
                mergedSets[name] = newSet
                continue
            }
            var out = oldSet.merging(newSet) { _, n in n }
            let keyField = (newSet["key"] as? String) ?? (oldSet["key"] as? String) ?? "id"
            out["key"] = keyField
            var byKey: [String: [String: Any]] = [:]
            var order: [String] = []
            let oldItems = (oldSet["items"] as? [[String: Any]]) ?? []
            let newItems = (newSet["items"] as? [[String: Any]]) ?? []
            for item in oldItems + newItems {
                let keyValue = String(describing: item[keyField] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
                guard !keyValue.isEmpty, keyValue != "nil" else { continue }
                if byKey[keyValue] == nil { order.append(keyValue) }
                byKey[keyValue] = carryTombstone(from: byKey[keyValue], into: item)
            }
            out["items"] = order.compactMap { byKey[$0] }
            mergedSets[name] = out
        }
        merged["entities"] = mergedSets

        var byTriple: [String: [String: Any]] = [:]
        var relationOrder: [String] = []
        let oldRelations = (old["relations"] as? [[String: Any]]) ?? []
        let newRelations = (new["relations"] as? [[String: Any]]) ?? []
        for relation in oldRelations + newRelations {
            let from = String(describing: relation["from"] ?? "").lowercased()
            let to = String(describing: relation["to"] ?? "").lowercased()
            guard !from.isEmpty, !to.isEmpty else { continue }
            let triple = "\(from)|\(to)|\(String(describing: relation["type"] ?? "related").lowercased())"
            if byTriple[triple] == nil { relationOrder.append(triple) }
            byTriple[triple] = carryTombstone(from: byTriple[triple], into: relation)
        }
        if !relationOrder.isEmpty {
            merged["relations"] = relationOrder.compactMap { byTriple[$0] }
        }

        guard JSONSerialization.isValidJSONObject(merged),
              let data = try? JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return incoming
        }
        return json
    }

    /// Union rows by the dataset's declared key field (mirror of the
    /// gateway's _merge_dataset so offline captures converge identically).
    static func mergeDataset(existing: String, incoming: String) -> String {
        guard let old = parse(existing), let new = parse(incoming) else { return incoming }
        var merged = old.merging(new) { _, n in n }
        let keyField = (new["key"] as? String) ?? (old["key"] as? String) ?? "id"
        merged["key"] = keyField

        var byKey: [String: [String: Any]] = [:]
        var order: [String] = []
        let oldRows = (old["rows"] as? [[String: Any]]) ?? []
        let newRows = (new["rows"] as? [[String: Any]]) ?? []
        for row in oldRows + newRows {
            let keyValue = String(describing: row[keyField] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            guard !keyValue.isEmpty, keyValue != "nil" else { continue }
            if byKey[keyValue] == nil { order.append(keyValue) }
            byKey[keyValue] = carryTombstone(from: byKey[keyValue], into: row)
        }
        merged["rows"] = order.compactMap { byKey[$0] }

        guard JSONSerialization.isValidJSONObject(merged),
              let data = try? JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return incoming
        }
        return json
    }

    /// Union markers by label (case-insensitive); incoming wins on conflict.
    /// Top-level fields (title/region/…) come from the incoming block when
    /// present, else carry over. Unparseable JSON on either side → incoming
    /// (never brick the artifact on a malformed update).
    static func mergeMap(existing: String, incoming: String) -> String {
        guard let existingObj = parse(existing) else { return incoming }
        guard let incomingObj = parse(incoming) else { return incoming }

        var merged = existingObj.merging(incomingObj) { _, new in new }

        let existingMarkers = (existingObj["markers"] as? [[String: Any]]) ?? []
        let incomingMarkers = (incomingObj["markers"] as? [[String: Any]]) ?? []
        var byLabel: [String: [String: Any]] = [:]
        var order: [String] = []
        for marker in existingMarkers + incomingMarkers {
            let label = ((marker["label"] as? String) ?? "").lowercased()
            guard !label.isEmpty else { continue }
            if byLabel[label] == nil { order.append(label) }
            byLabel[label] = carryTombstone(from: byLabel[label], into: marker)   // later (incoming) wins
        }
        merged["markers"] = order.compactMap { byLabel[$0] }

        guard JSONSerialization.isValidJSONObject(merged),
              let data = try? JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return incoming
        }
        return json
    }

    /// A user's tombstone (`_deleted: true`) survives an agent re-emitting
    /// the same entry WITHOUT the flag — deletes don't resurrect. An
    /// incoming entry that explicitly sets `_deleted` (true or false) wins:
    /// that's a deliberate write, including un-delete.
    private static func carryTombstone(
        from existing: [String: Any]?, into incoming: [String: Any]
    ) -> [String: Any] {
        guard let existing,
              (existing["_deleted"] as? Bool) == true,
              incoming["_deleted"] == nil else {
            return incoming
        }
        var kept = incoming
        kept["_deleted"] = true
        return kept
    }

    private static func parse(_ s: String) -> [String: Any]? {
        guard let data = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
