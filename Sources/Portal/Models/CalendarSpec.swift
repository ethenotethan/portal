import Foundation

/// JSON contract for ```calendar fenced blocks — agent-maintained schedules
/// laid out on a month grid (content calendars, release schedules, itineraries):
/// ```json
/// {
///   "title": "August",
///   "events": [
///     {"id": "ga", "date": "2026-08-20", "title": "GA release", "tag": "launch"},
///     {"id": "review", "date": "2026-08-12", "title": "Design review", "time": "14:00"}
///   ]
/// }
/// ```
/// Distinct from ```timeline (that fence renders a gantt of duration bars); a
/// calendar plots discrete dated events on a month grid with an agenda list.
/// Events are keyed by `id` (falls back to title) so the store unions events
/// across agent re-emits. Dates use "yyyy-MM-dd" or full ISO-8601 (shared with
/// `TimelineSpec.parseDate`).
internal struct CalendarSpec {
    internal struct Event: Identifiable {
        internal let id: String
        internal let date: Date
        internal let title: String
        internal let time: String?
        internal let tag: String?
        internal let note: String?
    }

    internal let title: String?
    internal let events: [Event]

    /// Events sharing a calendar day, in chronological order.
    internal func events(on day: Date, calendar: Calendar = .current) -> [Event] {
        events.filter { calendar.isDate($0.date, inSameDayAs: day) }
            .sorted { $0.date < $1.date }
    }

    /// Distinct months (first-of-month) the events span, ascending.
    internal func months(calendar: Calendar = .current) -> [Date] {
        var seen = Set<Date>()
        return events
            .compactMap { calendar.dateInterval(of: .month, for: $0.date)?.start }
            .filter { seen.insert($0).inserted }
            .sorted()
    }

    private static let parseMemo = RenderMemo<CalendarSpec?>(limit: 32)

    internal static func parse(_ json: String) -> CalendarSpec? {
        parseMemo.value(for: json) { parseUncached(json) }
    }

    private static func parseUncached(_ json: String) -> CalendarSpec? {
        guard let obj = JSONObjectParse.object(from: json),
              let rawEvents = obj["events"] as? [[String: Any]] else { return nil }

        let events: [Event] = rawEvents
            .filter { ($0["_deleted"] as? Bool) != true }
            .compactMap { raw in
                guard let title = (raw["title"] as? String)?.trimmingCharacters(in: .whitespaces),
                      !title.isEmpty,
                      let date = (raw["date"] as? String).flatMap(TimelineSpec.parseDate) else { return nil }
                let id = ((raw["id"] as? String)?.trimmingCharacters(in: .whitespaces)).flatMap {
                    $0.isEmpty ? nil : $0
                } ?? title
                let time = (raw["time"] as? String)?.trimmingCharacters(in: .whitespaces)
                let tag = (raw["tag"] as? String)?.trimmingCharacters(in: .whitespaces)
                let note = (raw["note"] as? String)?.trimmingCharacters(in: .whitespaces)
                return Event(id: id, date: date, title: title,
                             time: (time?.isEmpty ?? true) ? nil : time,
                             tag: (tag?.isEmpty ?? true) ? nil : tag,
                             note: (note?.isEmpty ?? true) ? nil : note)
            }
        guard !events.isEmpty else { return nil }
        return CalendarSpec(title: (obj["title"] as? String)?.trimmingCharacters(in: .whitespaces),
                            events: events)
    }
}
