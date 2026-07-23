import Foundation

/// JSON contract for ```model fenced blocks — the ensemble artifact: named
/// ENTITY SETS, RELATIONS between entities, and stacked VIEWS that are each
/// a projection over the same data. One content body, N lenses:
/// ```json
/// {
///   "id": "bkk-life", "title": "Bangkok Base",
///   "entities": {
///     "apartments": {"key": "name", "items": [
///        {"name": "Seed Mingle", "lat": 13.716, "lon": 100.54, "rent": 22000, "status": "interested"}]},
///     "gyms": {"key": "name", "items": [{"name": "FelixMuayThai", "lat": 13.729, "lon": 100.539}]}
///   },
///   "relations": [
///     {"from": "apartments/Seed Mingle", "to": "gyms/FelixMuayThai", "type": "walkable", "note": "8 min"}
///   ],
///   "views": [
///     {"type": "map", "entities": ["apartments", "gyms"]},
///     {"type": "table", "entities": ["apartments"], "columns": ["name", "rent", "status"]},
///     {"type": "graph"},
///     {"type": "chart", "chart": "bar", "entities": ["apartments"], "x": "name", "y": "rent"},
///     {"type": "stats", "entities": ["apartments"]}
///   ],
///   "actions": {"apartments": [{"field": "status", "type": "choice", "options": ["interested", "viewed"]},
///                              {"type": "delete"}]}
/// }
/// ```
/// Entity refs are "set/keyValue". Items with `_deleted: true` are
/// tombstones — merged, never rendered. Selection is shared across views.
struct ModelSpec {

    /// "set/keyValue" reference to one entity. Key comparison is
    /// trimmed-case-insensitive, matching merge semantics everywhere else.
    struct EntityRef: Hashable {
        let set: String
        let key: String

        init(set: String, key: String) {
            self.set = set
            self.key = key.trimmingCharacters(in: .whitespaces).lowercased()
        }

        /// Parse "apartments/Seed Mingle" (key may contain "/").
        init?(_ raw: String) {
            guard let slash = raw.firstIndex(of: "/") else { return nil }
            let set = String(raw[raw.startIndex..<slash]).trimmingCharacters(in: .whitespaces)
            let key = String(raw[raw.index(after: slash)...])
            guard !set.isEmpty, !key.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            self.init(set: set, key: key)
        }
    }

    struct EntitySet {
        let name: String
        let key: String
        /// Live items (tombstones already filtered), values stringified for
        /// uniform column/control handling; original values kept for charts.
        let items: [[String: String]]
        let rawItems: [[String: Any]]
    }

    struct Relation: Identifiable {
        let from: EntityRef
        let to: EntityRef
        let type: String
        let note: String?

        var id: String { "\(from.set)/\(from.key)→\(to.set)/\(to.key):\(type)" }
    }

    struct View: Identifiable {
        enum Kind: String {
            case map, table, graph, chart, stats
        }

        let kind: Kind
        /// Entity sets this view projects; empty = all sets.
        let entitySets: [String]
        /// table: display columns (empty = derive).
        let columns: [String]
        /// chart: chart type + axis fields.
        let chartType: String
        let xField: String
        let yField: String
        /// stats: fields to tile (empty = numeric fields).
        let fields: [String]

        var id: String { "\(kind.rawValue):\(entitySets.joined(separator: ","))" }
    }

    let id: String?
    let title: String?
    /// Declaration order preserved (JSON object order isn't stable through
    /// JSONSerialization, so sets are ordered by first mention in `order`,
    /// falling back to alphabetical).
    let entitySets: [EntitySet]
    let relations: [Relation]
    let views: [View]
    /// Entity-set name → declared actions.
    let actions: [String: [ArtifactAction]]

    func entitySet(named name: String) -> EntitySet? {
        entitySets.first { $0.name == name }
    }

    /// Sets a view projects: its declared list, else all.
    func sets(for view: View) -> [EntitySet] {
        view.entitySets.isEmpty
            ? entitySets
            : view.entitySets.compactMap { entitySet(named: $0) }
    }

    /// The item behind a ref, if it exists (live items only).
    func item(for ref: EntityRef) -> [String: String]? {
        guard let set = entitySet(named: ref.set) else { return nil }
        return set.items.first {
            ($0[set.key] ?? "").trimmingCharacters(in: .whitespaces).lowercased() == ref.key
        }
    }

    /// Relations touching a ref.
    func relations(touching ref: EntityRef) -> [Relation] {
        relations.filter { $0.from == ref || $0.to == ref }
    }

    // MARK: Parse

    static func parse(_ json: String) -> ModelSpec? {
        guard let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawSets = obj["entities"] as? [String: [String: Any]], !rawSets.isEmpty else {
            return nil
        }

        var sets: [EntitySet] = []
        for name in rawSets.keys.sorted() {
            guard let setObj = rawSets[name] else { continue }
            let key = (setObj["key"] as? String) ?? "id"
            let raw = ((setObj["items"] as? [[String: Any]]) ?? [])
                .filter { ($0["_deleted"] as? Bool) != true }
            guard !raw.isEmpty else { continue }
            let items: [[String: String]] = raw.map { item in
                item.filter { $0.key != "_deleted" }.mapValues(stringify)
            }
            sets.append(EntitySet(name: name, key: key, items: items, rawItems: raw))
        }
        guard !sets.isEmpty else { return nil }
        let liveSetNames = Set(sets.map(\.name))

        // Relations: endpoints must parse; endpoints referencing a missing
        // SET drop (broken data), but a missing ITEM is kept — the item may
        // be tombstoned and the relation should survive an un-delete.
        let relations: [Relation] = ((obj["relations"] as? [[String: Any]]) ?? []).compactMap { raw in
            guard let from = (raw["from"] as? String).flatMap(EntityRef.init),
                  let to = (raw["to"] as? String).flatMap(EntityRef.init),
                  liveSetNames.contains(from.set), liveSetNames.contains(to.set) else { return nil }
            return Relation(
                from: from, to: to,
                type: (raw["type"] as? String) ?? "related",
                note: raw["note"] as? String
            )
        }

        var views: [View] = ((obj["views"] as? [[String: Any]]) ?? []).compactMap { raw in
            guard let kind = (raw["type"] as? String).flatMap(View.Kind.init(rawValue:)) else { return nil }
            return View(
                kind: kind,
                entitySets: ((raw["entities"] as? [String]) ?? []).filter { liveSetNames.contains($0) },
                columns: (raw["columns"] as? [String]) ?? [],
                chartType: (raw["chart"] as? String) ?? "bar",
                xField: (raw["x"] as? String) ?? "",
                yField: (raw["y"] as? String) ?? "",
                fields: (raw["fields"] as? [String]) ?? []
            )
        }
        // No views declared: sensible defaults — map when anything has
        // coordinates, table always, graph when relations exist.
        if views.isEmpty {
            let hasCoords = sets.contains { set in
                set.rawItems.contains { $0["lat"] is NSNumber && $0["lon"] is NSNumber }
            }
            if hasCoords { views.append(View(kind: .map, entitySets: [], columns: [], chartType: "bar", xField: "", yField: "", fields: [])) }
            views.append(View(kind: .table, entitySets: [], columns: [], chartType: "bar", xField: "", yField: "", fields: []))
            if !relations.isEmpty { views.append(View(kind: .graph, entitySets: [], columns: [], chartType: "bar", xField: "", yField: "", fields: [])) }
        }

        var actions: [String: [ArtifactAction]] = [:]
        for (setName, value) in (obj["actions"] as? [String: Any]) ?? [:] where liveSetNames.contains(setName) {
            let parsed = ArtifactAction.parse(value)
            if !parsed.isEmpty { actions[setName] = parsed }
        }

        return ModelSpec(
            id: obj["id"] as? String,
            title: obj["title"] as? String,
            entitySets: sets,
            relations: relations,
            views: views,
            actions: actions
        )
    }

    private static func stringify(_ value: Any) -> String {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return "\(n)" }
        return "\(value)"
    }
}
