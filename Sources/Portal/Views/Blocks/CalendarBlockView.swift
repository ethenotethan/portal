import SwiftUI

/// Renders a ```calendar JSON block: a month grid (weeks × weekdays) with dots
/// on days that have events, plus an agenda list of every event in date order.
/// When events span more than one month, the grid shows the first month and the
/// agenda covers them all — a snapshot surface, not an interactive navigator.
/// PDF-safe: pure layout, no ScrollView or representables. Read-only (a calendar
/// is a projection; edits go through the emitting agent).
internal struct CalendarBlockView: View {
    internal let json: String
    internal let isStreaming: Bool

    internal var body: some View {
        if let spec = CalendarSpec.parse(json) {
            CalendarCard(spec: spec)
        } else if isStreaming {
            EmptyView()
        } else {
            ArtifactParseError(kind: "calendar", json: json)
        }
    }
}

private struct CalendarCard: View {
    let spec: CalendarSpec
    private let calendar = Calendar.current

    private var monthStart: Date {
        spec.months(calendar: calendar).first
            ?? calendar.dateInterval(of: .month, for: spec.events.first?.date ?? Date())?.start
            ?? Date()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(spec.title ?? monthStart.formatted(.dateTime.month(.wide).year()))
                    .font(.headline)
                    .foregroundStyle(Theme.primary)
                Spacer(minLength: 8)
                Text("\(spec.events.count) event\(spec.events.count == 1 ? "" : "s")")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.secondary)
            }
            monthGrid
            agenda
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.border, lineWidth: 0.5)
        )
    }

    // MARK: Month grid

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        let shift = calendar.firstWeekday - 1
        return Array(symbols[shift...] + symbols[..<shift])
    }

    /// Days to lay out: leading blanks for the first week's offset, then each
    /// day of the month. `nil` renders an empty cell.
    private var gridDays: [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: monthStart) else { return [] }
        let firstWeekday = calendar.component(.weekday, from: monthStart)
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7
        var days: [Date?] = Array(repeating: nil, count: leading)
        for day in range {
            days.append(calendar.date(byAdding: .day, value: day - 1, to: monthStart))
        }
        return days
    }

    private var monthGrid: some View {
        VStack(spacing: 4) {
            HStack(spacing: 0) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            let rows = stride(from: 0, to: gridDays.count, by: 7).map {
                Array(gridDays[$0..<min($0 + 7, gridDays.count)])
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, week in
                HStack(spacing: 0) {
                    ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                        dayCell(day)
                    }
                    // Pad a short final week so cells keep their width.
                    ForEach(week.count..<7, id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func dayCell(_ day: Date?) -> some View {
        if let day {
            let count = spec.events(on: day, calendar: calendar).count
            let isToday = calendar.isDateInToday(day)
            VStack(spacing: 2) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.system(size: 11, weight: isToday ? .bold : .regular))
                    .foregroundStyle(isToday ? Theme.accent : Theme.primary)
                Circle()
                    .fill(count > 0 ? Theme.accent : Color.clear)
                    .frame(width: 4, height: 4)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(
                isToday ? Theme.accent.opacity(0.1) : Color.clear,
                in: RoundedRectangle(cornerRadius: 5)
            )
        } else {
            Color.clear.frame(maxWidth: .infinity).frame(height: 30)
        }
    }

    // MARK: Agenda

    private var agenda: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(spec.events.sorted { $0.date < $1.date }) { event in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(event.date.formatted(.dateTime.month(.abbreviated).day()))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 52, alignment: .leading)
                    if let time = event.time {
                        Text(time)
                            .font(.caption2)
                            .foregroundStyle(Theme.tertiary)
                            .monospacedDigit()
                    }
                    Text(event.title)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.primary)
                    if let tag = event.tag {
                        Text(tag)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Theme.accent.opacity(0.12), in: Capsule())
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.top, 2)
    }
}
