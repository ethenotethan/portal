import Foundation

/// Pure projections from a ModelSpec's entity sets to the JSON contracts of
/// the existing block renderers. The model view stack is "one content body,
/// N lenses" — each lens reuses a battle-tested renderer by producing the
/// exact fence body that renderer already parses.
enum ModelProjections {

    /// Map view: every item with lat+lon across the view's sets becomes a
    /// marker (label = key value, group = set name — the legend explains
    /// which entity set each pin belongs to).
    static func mapJSON(spec: ModelSpec, view: ModelSpec.View) -> String? {
        var markers: [[String: Any]] = []
        for set in spec.sets(for: view) {
            for item in set.rawItems where (item["_deleted"] as? Bool) != true {
                guard let lat = (item["lat"] as? NSNumber)?.doubleValue,
                      let lon = (item["lon"] as? NSNumber)?.doubleValue else { continue }
                var marker: [String: Any] = [
                    "lat": lat, "lon": lon,
                    "label": stringify(item[set.key] ?? ""),
                    "group": set.name,
                ]
                if let note = item["note"] as? String { marker["note"] = note }
                markers.append(marker)
            }
        }
        guard !markers.isEmpty else { return nil }
        return encode(["markers": markers])
    }

    /// Graph view: entities as nodes (grouped by set), relations as labeled
    /// edges. Ref → node id is "set/key".
    static func graphJSON(spec: ModelSpec, view: ModelSpec.View) -> String? {
        let sets = spec.sets(for: view)
        let included = Set(sets.map(\.name))
        var nodes: [[String: Any]] = []
        for set in sets {
            for item in set.items {
                let keyValue = item[set.key] ?? ""
                guard !keyValue.isEmpty else { continue }
                let ref = ModelSpec.EntityRef(set: set.name, key: keyValue)
                nodes.append([
                    "id": "\(ref.set)/\(ref.key)",
                    "label": keyValue,
                    "group": set.name,
                ])
            }
        }
        guard !nodes.isEmpty else { return nil }
        let nodeIDs = Set(nodes.compactMap { $0["id"] as? String })
        let edges: [[String: Any]] = spec.relations.compactMap { relation in
            guard included.contains(relation.from.set), included.contains(relation.to.set) else { return nil }
            let from = "\(relation.from.set)/\(relation.from.key)"
            let to = "\(relation.to.set)/\(relation.to.key)"
            // Drop edges whose endpoint item is tombstoned/absent — the graph
            // renderer treats unknown node ids as an error, not a ghost.
            guard nodeIDs.contains(from), nodeIDs.contains(to) else { return nil }
            var edge: [String: Any] = ["from": from, "to": to, "label": relation.type]
            if let note = relation.note { edge["note"] = note }
            return edge
        }
        return encode(["directed": false, "nodes": nodes, "edges": edges])
    }

    /// Chart view: one series per entity set, points (x: xField, y: yField).
    /// Items lacking either field drop.
    static func chartJSON(spec: ModelSpec, view: ModelSpec.View) -> String? {
        guard !view.xField.isEmpty, !view.yField.isEmpty else { return nil }
        var series: [[String: Any]] = []
        for set in spec.sets(for: view) {
            let points: [[String: Any]] = set.rawItems.compactMap { item in
                guard (item["_deleted"] as? Bool) != true,
                      let y = (item[view.yField] as? NSNumber)?.doubleValue else { return nil }
                let x = stringify(item[view.xField] ?? "")
                guard !x.isEmpty else { return nil }
                return ["x": x, "y": y]
            }
            if !points.isEmpty {
                series.append(["name": set.name, "points": points])
            }
        }
        guard !series.isEmpty else { return nil }
        return encode(["type": view.chartType, "series": series])
    }

    /// Stats view: one tile per declared field (or per numeric field found),
    /// value = sum across the view's sets. Count tile always leads.
    static func statsJSON(spec: ModelSpec, view: ModelSpec.View) -> String? {
        let sets = spec.sets(for: view)
        let total = sets.reduce(0) { $0 + $1.items.count }
        guard total > 0 else { return nil }
        var tiles: [[String: Any]] = [[
            "label": sets.count == 1 ? sets[0].name : "entities",
            "value": total,
        ]]
        var fields = view.fields
        if fields.isEmpty {
            // Numeric fields present on any item, alphabetical, capped.
            var seen = Set<String>()
            for set in sets {
                for item in set.rawItems {
                    for (field, value) in item
                    where value is NSNumber && !(value is Bool) && field != "lat" && field != "lon" {
                        seen.insert(field)
                    }
                }
            }
            fields = Array(seen.sorted().prefix(4))
        }
        for field in fields {
            var sum = 0.0
            var count = 0
            for set in sets {
                for item in set.rawItems where (item["_deleted"] as? Bool) != true {
                    if let n = (item[field] as? NSNumber)?.doubleValue {
                        sum += n
                        count += 1
                    }
                }
            }
            if count > 0 {
                tiles.append(["label": "Σ \(field)", "value": sum])
            }
        }
        return encode(["tiles": tiles])
    }

    private static func stringify(_ value: Any) -> String {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return "\(n)" }
        return "\(value)"
    }

    private static func encode(_ obj: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
