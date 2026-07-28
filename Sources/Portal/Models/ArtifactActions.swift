import Foundation

/// User affordances a dataset/map/model artifact declares for its own entries.
/// The emitting model (or user request) decides WHAT the verbs are; the
/// renderer only knows how to draw each type. Declared per-artifact:
/// ```json
/// {"id": "tech-confs", "key": "name", "actions": [
///    {"field": "status", "type": "choice", "options": ["going", "not going", "undecided"]},
///    {"field": "reached_out", "type": "toggle"},
///    {"type": "delete"},
///    {"type": "intent", "id": "archive-issue", "label": "Archive",
///     "intent": "linear.issue.archive", "presentation": {"role": "destructive"},
///     "target": {"entity_set": "issues", "key_field": "identifier"}}
///  ], "rows": [...]}
/// ```
/// Local actions (`choice`, `toggle`, `delete`) mutate content directly.
/// Backend intents (`intent`) send an opaque binding to the gateway and let
/// the server resolve the registered handler — the artifact never provides
/// executable code, credentials, or arbitrary URLs.
struct ArtifactAction: Equatable, Identifiable {
    enum Kind: String {
        case choice
        case toggle
        case delete
        case intent
    }

    internal enum PresentationRole: String {
        case normal
        case destructive
    }

    internal let kind: Kind
    /// Entry field the action reads/writes (local actions; empty for delete/intent).
    internal let field: String
    /// Allowed values for choice actions.
    internal let options: [String]

    // MARK: Intent-specific fields (populated only when kind == .intent)

    /// Stable binding ID declared in the artifact. The gateway resolves this
    /// against the pinned revision — never sent as the intent name itself.
    internal let bindingID: String
    /// Display label for the intent button.
    internal let label: String
    /// Intent name, for display and debugging only — never trusted by the server.
    internal let intentName: String
    /// Whether the button renders as destructive (red).
    internal let presentationRole: PresentationRole

    internal var id: String {
        kind == .intent ? "intent:\(bindingID)" : "\(kind.rawValue):\(field)"
    }

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
                return ArtifactAction(kind: .delete, field: "", options: [],
                                      bindingID: "", label: "", intentName: "", presentationRole: .normal)
            case .choice:
                guard !field.isEmpty, !options.isEmpty else { return nil }
                return ArtifactAction(kind: .choice, field: field, options: options,
                                      bindingID: "", label: "", intentName: "", presentationRole: .normal)
            case .toggle:
                guard !field.isEmpty else { return nil }
                return ArtifactAction(kind: .toggle, field: field, options: [],
                                      bindingID: "", label: "", intentName: "", presentationRole: .normal)
            case .intent:
                let bindingID = ((entry["id"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
                guard !bindingID.isEmpty else { return nil }
                let label = ((entry["label"] as? String) ?? bindingID).trimmingCharacters(in: .whitespaces)
                let intentName = ((entry["intent"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
                let roleStr = (entry["presentation"] as? [String: Any])?["role"] as? String ?? "normal"
                let role = PresentationRole(rawValue: roleStr) ?? .normal
                return ArtifactAction(kind: .intent, field: "", options: [],
                                      bindingID: bindingID, label: label,
                                      intentName: intentName, presentationRole: role)
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

// MARK: - Backend intent invocation result

/// Result returned by the gateway's artifact.action.invoke RPC.
internal struct ArtifactActionInvokeResult {
    internal enum Outcome {
        /// Handler needs native confirmation before proceeding.
        case needsConfirmation(challenge: String, prompt: String)
        /// Handler completed successfully.
        case succeeded(message: String?)
        /// Handler failed (user-visible reason).
        case failed(reason: String)
        /// Artifact changed since button was rendered — refresh and retry.
        case conflict
        /// Gateway doesn't support this RPC (old deployment).
        case unsupported
    }
    internal let outcome: Outcome

    internal static func from(_ d: [String: AnyCodable]?) -> ArtifactActionInvokeResult {
        guard let d else { return .init(outcome: .unsupported) }
        let status = d["status"]?.stringValue ?? ""
        switch status {
        case "needs_confirmation":
            let challenge = d["challenge"]?.stringValue ?? ""
            let prompt = d["prompt"]?.stringValue ?? "Confirm action?"
            return .init(outcome: .needsConfirmation(challenge: challenge, prompt: prompt))
        case "succeeded":
            return .init(outcome: .succeeded(message: d["message"]?.stringValue))
        case "failed":
            return .init(outcome: .failed(reason: d["reason"]?.stringValue ?? "Action failed"))
        case "conflict":
            return .init(outcome: .conflict)
        default:
            return .init(outcome: .unsupported)
        }
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
