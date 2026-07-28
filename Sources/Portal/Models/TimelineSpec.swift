import Foundation

/// JSON contract for ```timeline fenced blocks — schedules, project plans,
/// incident chronologies, historical sequences:
/// ```json
/// {
///   "title": "Q3 Launch Plan",
///   "items": [
///     {"label": "Design", "start": "2026-07-01", "end": "2026-07-14", "lane": "Product", "group": "done"},
///     {"label": "Build", "start": "2026-07-10", "end": "2026-08-15", "lane": "Eng"},
///     {"label": "GA", "at": "2026-08-20", "lane": "Launch", "note": "public release"}
///   ]
/// }
/// ```
/// Items with start+end render as duration bars; items with `at` render as
/// point milestones (diamonds). `lane` groups items into swimlanes (defaults
/// to one lane); `group` colors items categorically; `note` shows on select.
/// Dates: ISO "yyyy-MM-dd" or full ISO-8601 timestamps.
struct TimelineSpec {
    struct Item: Identifiable {
        let label: String
        let start: Date
        let end: Date
        let isMilestone: Bool
        let lane: String
        let group: String?
        let note: String?

        var id: String { "\(lane)|\(label)" }
        var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    let title: String?
    let items: [Item]

    /// Lanes in first-appearance order.
    var lanes: [String] {
        var seen = Set<String>()
        return items.map(\.lane).filter { seen.insert($0).inserted }
    }

    /// Groups in first-appearance order.
    var groups: [String] {
        var seen = Set<String>()
        return items.compactMap(\.group).filter { seen.insert($0).inserted }
    }

    var dateRange: ClosedRange<Date>? {
        guard let min = items.map(\.start).min(),
              let max = items.map(\.end).max(), max > min else {
            guard let only = items.first?.start else { return nil }
            // Single instant: pad a day around it so the axis has extent.
            return only.addingTimeInterval(-43_200)...only.addingTimeInterval(43_200)
        }
        return min...max
    }

    /// Runs in TimelineBlockView.body; memoized so resume/scroll don't re-run
    /// JSONSerialization + date parsing. Pure function of the source string.
    private static let parseMemo = RenderMemo<TimelineSpec?>(limit: 32)

    static func parse(_ json: String) -> TimelineSpec? {
        parseMemo.value(for: json) { parseUncached(json) }
    }

    private static func parseUncached(_ json: String) -> TimelineSpec? {
        guard let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawItems = obj["items"] as? [[String: Any]] else { return nil }

        let items: [Item] = rawItems.compactMap { raw in
            guard let label = (raw["label"] as? String)?.trimmingCharacters(in: .whitespaces),
                  !label.isEmpty else { return nil }
            let lane = (raw["lane"] as? String)?.trimmingCharacters(in: .whitespaces) ?? "Timeline"
            let group = raw["group"] as? String
            let note = raw["note"] as? String

            if let at = (raw["at"] as? String).flatMap(parseDate) {
                return Item(label: label, start: at, end: at, isMilestone: true,
                            lane: lane, group: group, note: note)
            }
            guard let start = (raw["start"] as? String).flatMap(parseDate),
                  let end = (raw["end"] as? String).flatMap(parseDate),
                  end >= start else { return nil }
            return Item(label: label, start: start, end: end, isMilestone: false,
                        lane: lane, group: group, note: note)
        }
        guard !items.isEmpty else { return nil }
        return TimelineSpec(title: obj["title"] as? String, items: items)
    }

    /// "yyyy-MM-dd" (rendered as local midnight) or full ISO-8601.
    static func parseDate(_ s: String) -> Date? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.count == 10, trimmed[trimmed.index(trimmed.startIndex, offsetBy: 4)] == "-" {
            var components = DateComponents()
            let parts = trimmed.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            components.year = parts[0]
            components.month = parts[1]
            components.day = parts[2]
            // date(from:) rolls invalid components over (month 13 → January)
            // instead of failing, so validate explicitly.
            guard components.isValidDate(in: Calendar.current) else { return nil }
            return Calendar.current.date(from: components)
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: trimmed) ?? ISO8601DateFormatter().date(from: trimmed)
    }
}
