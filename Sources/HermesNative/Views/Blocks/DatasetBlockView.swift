import SwiftUI

/// JSON contract for `dataset` artifacts — row-keyed records (contributor
/// tables, client lists, spend entries):
/// ```json
/// {
///   "id": "darkbloom-contributors", "key": "login",
///   "columns": ["login", "name", "commits"],
///   "rows": [{"login": "greg", "name": "Greg", "commits": 44}]
/// }
/// ```
/// `key` names the row-identity field (server merges rows by it). `columns`
/// fixes display order; absent, columns derive from the union of row keys
/// (key field first). Values may be strings, numbers, or bools.
struct DatasetSpec {
    let key: String
    let columns: [String]
    let rows: [[String: String]]

    static func parse(_ json: String) -> DatasetSpec? {
        guard let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawRows = obj["rows"] as? [[String: Any]], !rawRows.isEmpty else { return nil }

        let key = (obj["key"] as? String) ?? "id"
        let rows: [[String: String]] = rawRows.map { row in
            row.mapValues { value in
                if let s = value as? String { return s }
                if let n = value as? NSNumber { return "\(n)" }
                return "\(value)"
            }
        }

        var columns = (obj["columns"] as? [String]) ?? []
        if columns.isEmpty {
            var seen = Set<String>()
            var derived: [String] = []
            for row in rows {
                for field in row.keys.sorted() where seen.insert(field).inserted {
                    derived.append(field)
                }
            }
            // Key field leads.
            if let idx = derived.firstIndex(of: key) {
                derived.remove(at: idx)
                derived.insert(key, at: 0)
            }
            columns = derived
        }
        return DatasetSpec(key: key, columns: columns, rows: rows)
    }
}

/// Renders a dataset through the existing sortable TableView (click-to-sort
/// headers, numeric-aware, CSV copy — all inherited).
struct DatasetBlockView: View {
    let json: String
    let isStreaming: Bool

    var body: some View {
        if let spec = DatasetSpec.parse(json) {
            TableView(
                headers: spec.columns,
                rows: spec.rows.map { row in
                    spec.columns.map { row[$0] ?? "" }
                }
            )
        } else if isStreaming {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Couldn't parse dataset block")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.secondary)
                Text(json)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            .padding(10)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
