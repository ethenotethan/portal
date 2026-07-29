import Foundation

/// JSON contract for ```kanban fenced blocks — agent-maintained boards
/// (sprint work, triage lanes, pipeline stages):
/// ```json
/// {
///   "title": "Sprint 12",
///   "columns": ["Todo", "Doing", "Done"],
///   "cards": [
///     {"id": "PORT-1", "title": "Kanban artifact", "column": "Doing", "tag": "feat"},
///     {"id": "PORT-2", "title": "Ship it", "column": "Todo", "note": "after review"}
///   ]
/// }
/// ```
/// The fence name collides with mermaid's `kanban` diagram, so it is
/// disambiguated by content: our spec is a JSON object, mermaid's is
/// line-oriented text (see `MarkdownParser.isKanbanBlock`).
///
/// Cards are keyed by `id` (falls back to title) so the store unions cards
/// across agent re-emits and a user's column move survives. A `choice` action
/// on `column` (moving a card between lanes) rides the same action path
/// datasets use. Columns default to first-appearance order of the cards'
/// `column` values when not declared.
internal struct KanbanSpec {
    internal struct Card: Identifiable {
        internal let id: String
        internal let title: String
        internal let column: String
        internal let tag: String?
        internal let note: String?
        /// Longer body shown when the card is expanded (`detail`, `desc`, or
        /// `description`). Distinct from the one-line `note` on the collapsed card.
        internal let detail: String?
        /// Any other scalar fields the agent attached (assignee, due, points…),
        /// sorted by key. Surfaced in the expanded card so an agent can carry
        /// arbitrary ticket metadata without a schema change. Empty when none.
        internal let extra: [(key: String, value: String)]

        /// True when expanding reveals anything the collapsed card doesn't show.
        internal var hasDetail: Bool {
            (detail?.isEmpty == false) || !extra.isEmpty
        }
    }

    /// Card keys the spec renders itself — everything else becomes `extra`.
    private static let reservedCardKeys: Set<String> = [
        "id", "title", "label", "column", "tag", "note",
        "detail", "desc", "description", "_deleted"
    ]

    internal let title: String?
    internal let columns: [String]
    internal let cards: [Card]

    internal func cards(in column: String) -> [Card] {
        cards.filter { $0.column == column }
    }

    private static let parseMemo = RenderMemo<KanbanSpec?>(limit: 32)

    internal static func parse(_ json: String) -> KanbanSpec? {
        parseMemo.value(for: json) { parseUncached(json) }
    }

    private static func parseUncached(_ json: String) -> KanbanSpec? {
        guard let obj = JSONObjectParse.object(from: json),
              let rawCards = obj["cards"] as? [[String: Any]] else { return nil }

        let declaredColumns = (obj["columns"] as? [String])?
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty } ?? []
        let fallbackColumn = declaredColumns.first ?? "Backlog"

        let cards: [Card] = rawCards
            .filter { ($0["_deleted"] as? Bool) != true }
            .compactMap { raw in
                let title = ((raw["title"] as? String) ?? (raw["label"] as? String))?
                    .trimmingCharacters(in: .whitespaces)
                guard let title, !title.isEmpty else { return nil }
                let id = ((raw["id"] as? String)?.trimmingCharacters(in: .whitespaces)).flatMap {
                    $0.isEmpty ? nil : $0
                } ?? title
                let column = ((raw["column"] as? String)?.trimmingCharacters(in: .whitespaces)).flatMap {
                    $0.isEmpty ? nil : $0
                } ?? fallbackColumn
                let tag = (raw["tag"] as? String)?.trimmingCharacters(in: .whitespaces)
                let note = (raw["note"] as? String)?.trimmingCharacters(in: .whitespaces)
                let detail = (["detail", "desc", "description"].lazy
                    .compactMap { raw[$0] as? String }
                    .first)?.trimmingCharacters(in: .whitespaces)
                let extra = raw
                    .filter { !reservedCardKeys.contains($0.key) }
                    .compactMap { key, value -> (key: String, value: String)? in
                        let string = scalarString(value)
                        guard let string, !string.isEmpty else { return nil }
                        return (key: key, value: string)
                    }
                    .sorted { $0.key < $1.key }
                return Card(id: id, title: title, column: column,
                            tag: (tag?.isEmpty ?? true) ? nil : tag,
                            note: (note?.isEmpty ?? true) ? nil : note,
                            detail: (detail?.isEmpty ?? true) ? nil : detail,
                            extra: extra)
            }
        guard !cards.isEmpty else { return nil }

        // Declared columns lead; any column a card references but the spec
        // didn't declare is appended in first-appearance order so no card is
        // orphaned off-board.
        var columns = declaredColumns
        var seen = Set(declaredColumns)
        for card in cards where seen.insert(card.column).inserted {
            columns.append(card.column)
        }

        return KanbanSpec(title: (obj["title"] as? String)?.trimmingCharacters(in: .whitespaces),
                          columns: columns, cards: cards)
    }

    /// Renders a JSON scalar (string/number/bool) for display in an expanded
    /// card. Nested objects/arrays are skipped (nil) — the expanded card shows
    /// flat metadata only, not structured payloads.
    private static func scalarString(_ value: Any) -> String? {
        switch value {
        case let string as String:
            return string.trimmingCharacters(in: .whitespaces)
        case let bool as Bool:
            return bool ? "true" : "false"
        case let number as NSNumber:
            // NSNumber bridges booleans too, but those are caught above.
            return number.stringValue
        default:
            return nil
        }
    }
}
