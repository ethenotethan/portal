import Foundation

/// JSON contract for ```checklist fenced blocks — agent-maintained task lists,
/// acceptance criteria, launch runbooks:
/// ```json
/// {
///   "title": "Launch checklist",
///   "items": [
///     {"id": "dns", "label": "Cut over DNS", "done": true},
///     {"id": "smoke", "label": "Run smoke tests", "note": "staging + prod"},
///     {"id": "announce", "label": "Post announcement"}
///   ]
/// }
/// ```
/// Each item is keyed by `id` (falls back to the label) so the store can union
/// items across agent re-emits and a user's toggle of `done` survives — the
/// checklist is a living artifact, not a snapshot. `done` accepts bool or the
/// "true"/"1" string convention (see `ArtifactAction.isTruthy`). The toggle is
/// wired through the same action path datasets use.
internal struct ChecklistSpec {
    internal struct Item: Identifiable {
        internal let id: String
        internal let label: String
        internal let done: Bool
        internal let note: String?
    }

    internal let title: String?
    internal let items: [Item]

    internal var completedCount: Int { items.filter(\.done).count }

    /// Memoized: SwiftUI re-runs body per state change; parse is a pure
    /// function of the source string (parity with the other specs).
    private static let parseMemo = RenderMemo<ChecklistSpec?>(limit: 32)

    internal static func parse(_ json: String) -> ChecklistSpec? {
        parseMemo.value(for: json) { parseUncached(json) }
    }

    private static func parseUncached(_ json: String) -> ChecklistSpec? {
        guard let obj = JSONObjectParse.object(from: json),
              let rawItems = obj["items"] as? [[String: Any]] else { return nil }

        let items: [Item] = rawItems
            .filter { ($0["_deleted"] as? Bool) != true }
            .compactMap { raw in
                guard let label = (raw["label"] as? String)?.trimmingCharacters(in: .whitespaces),
                      !label.isEmpty else { return nil }
                let id = ((raw["id"] as? String)?.trimmingCharacters(in: .whitespaces)).flatMap {
                    $0.isEmpty ? nil : $0
                } ?? label
                let note = (raw["note"] as? String)?.trimmingCharacters(in: .whitespaces)
                return Item(id: id, label: label, done: isDone(raw["done"]),
                            note: (note?.isEmpty ?? true) ? nil : note)
            }
        guard !items.isEmpty else { return nil }
        return ChecklistSpec(title: (obj["title"] as? String)?.trimmingCharacters(in: .whitespaces),
                             items: items)
    }

    /// `done` may arrive as a JSON bool or the "true"/"1" string convention
    /// (a user toggle stringifies through ArtifactActionEngine).
    private static func isDone(_ value: Any?) -> Bool {
        if let flag = value as? Bool { return flag }
        if let n = value as? NSNumber { return n.intValue != 0 }
        if let s = value as? String { return ArtifactAction.isTruthy(s) }
        return false
    }
}
