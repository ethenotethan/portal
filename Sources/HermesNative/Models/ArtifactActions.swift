import Foundation

/// User affordances a dataset/map artifact declares for its own entries.
/// The emitting model (or user request) decides WHAT the verbs are; the
/// renderer only knows how to draw each type. Declared per-artifact:
/// ```json
/// {"id": "tech-confs", "key": "name", "actions": [
///    {"field": "status", "type": "choice", "options": ["going", "not going", "undecided"]},
///    {"field": "reached_out", "type": "toggle"},
///    {"type": "delete"}
///  ], "rows": [...]}
/// ```
/// - `choice`: per-entry menu that sets `field` to one of `options`.
/// - `toggle`: per-entry checkbox that flips `field` true/false.
/// - `delete`: tombstones the entry (`_deleted: true`) — hidden everywhere,
///   but survives merges so an agent re-emitting the row can't resurrect it.
struct ArtifactAction: Equatable, Identifiable {
    enum Kind: String {
        case choice
        case toggle
        case delete
    }

    let kind: Kind
    /// Entry field the action reads/writes (empty for delete).
    let field: String
    /// Allowed values for choice actions.
    let options: [String]

    var id: String { "\(kind.rawValue):\(field)" }

    /// Parse the `actions` value of a spec object. Unknown types and
    /// field-less choice/toggle entries drop silently — a malformed action
    /// never breaks rendering of the data itself.
    static func parse(_ value: Any?) -> [ArtifactAction] {
        guard let raw = value as? [[String: Any]] else { return [] }
        return raw.compactMap { entry in
            guard let kind = (entry["type"] as? String).flatMap(Kind.init(rawValue:)) else { return nil }
            let field = ((entry["field"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            let options = (entry["options"] as? [String]) ?? []
            switch kind {
            case .delete:
                return ArtifactAction(kind: .delete, field: "", options: [])
            case .choice:
                guard !field.isEmpty, !options.isEmpty else { return nil }
                return ArtifactAction(kind: .choice, field: field, options: options)
            case .toggle:
                guard !field.isEmpty else { return nil }
                return ArtifactAction(kind: .toggle, field: field, options: [])
            }
        }
    }

    /// "true"/"1" convention for toggle state — dataset rows stringify all
    /// values, so booleans arrive as either form depending on the writer.
    static func isTruthy(_ value: String?) -> Bool {
        let normalized = (value ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        return normalized == "true" || normalized == "1"
    }
}

/// Pure content mutations for user actions on dataset rows / map markers.
/// String JSON in, string JSON out — the caller (ArtifactStore) owns
/// persistence and sync; these know nothing about either.
enum ArtifactActionEngine {

    /// Set `field` on the entry identified by `entryKey`. For datasets the
    /// key is the declared key field's value; for maps it's the marker label.
    /// Key matching is case-insensitive-trimmed, mirroring ArtifactMerge.
    /// Returns nil when the content doesn't parse or no entry matches.
    static func setField(
        in content: String, kind: String, entryKey: String, field: String, value: Any
    ) -> String? {
        mutateEntry(in: content, kind: kind, entryKey: entryKey) { entry in
            entry[field] = value
        }
    }

    /// Tombstone the entry: sets `_deleted: true` rather than removing, so
    /// per-kind merges (client and gateway) can refuse to resurrect it when
    /// an agent re-emits the same row/marker.
    static func markDeleted(in content: String, kind: String, entryKey: String) -> String? {
        mutateEntry(in: content, kind: kind, entryKey: entryKey) { entry in
            entry["_deleted"] = true
        }
    }

    private static func mutateEntry(
        in content: String, kind: String, entryKey: String,
        _ mutate: (inout [String: Any]) -> Void
    ) -> String? {
        guard let data = content.data(using: .utf8),
              var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }

        // Ensemble model: entryKey is a "set/keyValue" ref; the entry lives
        // at entities[set].items, keyed by that set's declared key field.
        if kind == "model" {
            guard let ref = ModelSpec.EntityRef(entryKey),
                  var sets = obj["entities"] as? [String: [String: Any]],
                  var setObj = sets[ref.set],
                  var items = setObj["items"] as? [[String: Any]] else { return nil }
            let keyField = (setObj["key"] as? String) ?? "id"
            guard let index = items.firstIndex(where: {
                normalize(String(describing: $0[keyField] ?? "")) == ref.key
            }) else { return nil }
            mutate(&items[index])
            setObj["items"] = items
            sets[ref.set] = setObj
            obj["entities"] = sets
            return serialize(obj)
        }

        let listField: String
        let keyField: String
        switch kind {
        case "dataset":
            listField = "rows"
            keyField = (obj["key"] as? String) ?? "id"
        case "map":
            listField = "markers"
            keyField = "label"
        default:
            return nil
        }
        guard var entries = obj[listField] as? [[String: Any]] else { return nil }

        let target = normalize(entryKey)
        guard let index = entries.firstIndex(where: {
            normalize(String(describing: $0[keyField] ?? "")) == target
        }) else { return nil }

        mutate(&entries[index])
        obj[listField] = entries
        return serialize(obj)
    }

    private static func serialize(_ obj: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(obj),
              let out = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let json = String(data: out, encoding: .utf8) else {
            return nil
        }
        return json
    }

    private static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces).lowercased()
    }
}
