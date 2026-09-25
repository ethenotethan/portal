import Testing
import Foundation
@testable import Portal

/// Why the event plot came up empty while the feed and legend looked fine.
///
/// A plotted event needs a *date*; a feed row and a legend count don't. So a
/// timestamp the client couldn't parse dropped the dots and nothing else, which
/// reads as a broken chart rather than as a parsing problem. wiki-api emits
/// strict RFC3339, but a Hermes event's time comes from a raw source's
/// `ingested` frontmatter — in practice a bare `datetime.isoformat()`, a space
/// separator, or a plain date — and `ISO8601DateFormatter` rejects all three.
@Suite("Wiki timeline date parsing")
internal struct WikiTimelineDateParsingTests {

    /// The instant every whole-second case below denotes.
    private static let instant = WikiTimelineDecoding.parseDate("2026-08-04T16:55:58Z")

    /// Sub-second precision survives the parse, so a fractional input is NOT
    /// equal to its whole-second instant — it's that instant plus the fraction.
    /// Asserted with a tolerance rather than by exact equality, because binary
    /// floating point can't hold `.077734` exactly.
    private static func expectInstant(
        _ parsed: Date?, plus fraction: TimeInterval,
        _ comment: Comment? = nil, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard let parsed, let base = instant else {
            Issue.record(comment ?? "no date parsed", sourceLocation: sourceLocation)
            return
        }
        let drift = abs(parsed.timeIntervalSince(base) - fraction)
        #expect(drift < 0.001, comment, sourceLocation: sourceLocation)
    }

    // MARK: - Strict RFC3339 (must not regress)

    @Test("strict RFC3339, with and without fractional seconds")
    internal func strictFormats() {
        #expect(WikiTimelineDecoding.parseDate("2026-08-04T16:55:58Z") == Self.instant)
        #expect(WikiTimelineDecoding.parseDate("2026-08-04T16:55:58+00:00") == Self.instant)
        Self.expectInstant(WikiTimelineDecoding.parseDate("2026-08-04T16:55:58.077Z"), plus: 0.077)
        Self.expectInstant(WikiTimelineDecoding.parseDate("2026-08-04T16:55:58.077734Z"), plus: 0.077734)
    }

    @Test("a non-UTC offset is honored, not assumed away")
    internal func offsetHonored() {
        // The same instant, written in Pacific. Rewriting this to UTC would be a
        // seven-hour error, so the tolerant path must not touch a zoned input.
        #expect(WikiTimelineDecoding.parseDate("2026-08-04T09:55:58-07:00") == Self.instant)
    }

    // MARK: - Zone-less: what Python actually writes

    @Test("a bare datetime.isoformat() parses as UTC")
    internal func naiveISOFormat() {
        // `datetime.now().isoformat()` — the single most likely thing to be in
        // an `ingested:` field, and the case that emptied the plot.
        #expect(WikiTimelineDecoding.parseDate("2026-08-04T16:55:58") == Self.instant)
        Self.expectInstant(WikiTimelineDecoding.parseDate("2026-08-04T16:55:58.077734"), plus: 0.077734)
    }

    @Test("a space separator parses — legal RFC3339, rejected by the formatter")
    internal func spaceSeparator() {
        #expect(WikiTimelineDecoding.parseDate("2026-08-04 16:55:58") == Self.instant)
        Self.expectInstant(WikiTimelineDecoding.parseDate("2026-08-04 16:55:58.077734"), plus: 0.077734)
    }

    @Test("a date-only value is midnight UTC, so day-granular events still plot")
    internal func dateOnly() {
        #expect(
            WikiTimelineDecoding.parseDate("2026-08-04")
                == WikiTimelineDecoding.parseDate("2026-08-04T00:00:00Z")
        )
    }

    @Test("surrounding whitespace doesn't defeat the parse")
    internal func trimsWhitespace() {
        #expect(WikiTimelineDecoding.parseDate("  2026-08-04T16:55:58Z  ") == Self.instant)
        #expect(WikiTimelineDecoding.parseDate("\t2026-08-04T16:55:58\t") == Self.instant)
    }

    @Test("assuming UTC means the value doesn't shift with the test machine's zone")
    internal func utcAssumptionIsAbsolute() {
        // If the zone-less path went through a local-time formatter this would
        // pass in UTC and fail everywhere else — the worst kind of green.
        let naive = WikiTimelineDecoding.parseDate("2026-08-04T16:55:58")
        #expect(naive == WikiTimelineDecoding.parseDate("2026-08-04T16:55:58Z"))
    }

    // MARK: - Non-dates stay nil

    @Test("absent, empty, and blank values are nil, not the epoch")
    internal func emptyIsNil() {
        // wiki-api encodes a null time as "". Defaulting to a date would plant a
        // dot at 1970 and stretch the axis over half a century.
        #expect(WikiTimelineDecoding.parseDate(nil) == nil)
        #expect(WikiTimelineDecoding.parseDate("") == nil)
        #expect(WikiTimelineDecoding.parseDate("   ") == nil)
    }

    @Test("garbage stays nil rather than becoming a plausible date")
    internal func garbageIsNil() {
        #expect(WikiTimelineDecoding.parseDate("not a date") == nil)
        #expect(WikiTimelineDecoding.parseDate("2026-13-45T99:99:99") == nil)
        #expect(WikiTimelineDecoding.parseDate("tomorrow") == nil)
        // A number is a plausible epoch, but nothing in this protocol sends one,
        // so reading it as a date would be inventing data.
        #expect(WikiTimelineDecoding.parseDate("1780000000") == nil)
        // Right length for the date-only branch, not a date.
        #expect(WikiTimelineDecoding.parseDate("XXXX-XX-XX") == nil)
    }

    @Test("a non-string value is nil, not a crash")
    internal func nonStringIsNil() {
        #expect(WikiTimelineDecoding.parseDate(42) == nil)
        #expect(WikiTimelineDecoding.parseDate(["2026-08-04"]) == nil)
    }

    // MARK: - Through the decoder

    @Test("an event whose ingested time is zone-less becomes a plottable event")
    internal func decodedEventIsPlottable() throws {
        // The end-to-end statement of the bug: this event used to decode with
        // eventDate == nil, so the feed listed it and the plot skipped it.
        let event = try #require(GatewayClient.eventLogEntry(from: .dictionary([
            "key": AnyCodable("raw/email/2026-08-04-thread.md"),
            "kind": AnyCodable("email"),
            "timestamp": AnyCodable("2026-08-04T16:55:58.077734"),
        ])))
        Self.expectInstant(event.eventDate, plus: 0.077734)
    }

    @Test("time_estimated marks an mtime-derived time, and its absence doesn't")
    internal func estimatedFlagDecodes() throws {
        // The gateway falls back to the file's mtime when `ingested` is missing.
        // That's a real time but not the event's own, so it earns the diamond;
        // a recorded `ingested` must not, or every event looks inferred.
        let estimated = try #require(GatewayClient.eventLogEntry(from: .dictionary([
            "key": AnyCodable("raw/a.md"),
            "timestamp": AnyCodable("2026-08-04T16:55:58Z"),
            "time_estimated": AnyCodable(true),
        ])))
        #expect(estimated.eventTimeEstimated)

        let recorded = try #require(GatewayClient.eventLogEntry(from: .dictionary([
            "key": AnyCodable("raw/b.md"),
            "timestamp": AnyCodable("2026-08-04T16:55:58Z"),
            "time_estimated": AnyCodable(false),
        ])))
        #expect(!recorded.eventTimeEstimated)

        // A gateway predating the flag: indistinguishable from "not estimated".
        let legacy = try #require(GatewayClient.eventLogEntry(from: .dictionary([
            "key": AnyCodable("raw/c.md"),
            "timestamp": AnyCodable("2026-08-04T16:55:58Z"),
        ])))
        #expect(!legacy.eventTimeEstimated)
    }
}

// MARK: - Unplotted accounting

/// An event can be in the feed and absent from the plot for two honest reasons:
/// it has no time, or its time is outside the window. Both used to be silent,
/// which made a sparse plot look broken.
///
/// `@MainActor` because `WikiEventsPageView.unplottedSummary` is a static on a
/// SwiftUI `View` and so inherits main-actor isolation from the protocol; a
/// nonisolated test body warns on every call. It is a pure function over two
/// integers, so the annotation costs nothing and matches where the page calls it.
@MainActor
@Suite("Unplotted event accounting")
internal struct WikiEventUnplottedTests {

    private static func timeline(_ stamps: [String?]) -> WikiEventTimeline {
        let events = stamps.enumerated().compactMap { pair in
            GatewayClient.eventLogEntry(from: .dictionary([
                "key": AnyCodable("raw/e\(pair.offset).md"),
                "kind": AnyCodable("email"),
                "timestamp": AnyCodable(pair.element ?? ""),
            ]))
        }
        return WikiEventTimeline(
            since: nil, until: nil, eventCount: events.count,
            eventsByKind: [:], events: events
        )
    }

    @Test("undatedCount counts exactly the events with no usable time")
    internal func countsUndated() {
        let timeline = Self.timeline([
            "2026-08-04T12:00:00Z", nil, "", "   ", "garbage",
        ])
        #expect(timeline.events.count == 5)
        #expect(timeline.undatedCount == 4)
    }

    @Test("outOfWindowCount counts dated events the x-scale would clip")
    internal func countsOutOfWindow() throws {
        let timeline = Self.timeline([
            "2026-08-04T12:00:00Z",   // inside
            "2020-01-01T00:00:00Z",   // long before
            "2030-01-01T00:00:00Z",   // long after
            nil,                      // undated: not "out of window"
        ])
        let since = try #require(WikiTimelineDecoding.parseDate("2026-08-01T00:00:00Z"))
        let until = try #require(WikiTimelineDecoding.parseDate("2026-08-31T00:00:00Z"))
        #expect(timeline.outOfWindowCount(domain: since...until) == 2)
        // Undated events are counted by the other property — double-counting
        // them would overstate the note.
        #expect(timeline.undatedCount == 1)
    }

    @Test("a window containing everything reports nothing unplotted")
    internal func nothingUnplotted() throws {
        let timeline = Self.timeline(["2026-08-04T12:00:00Z", "2026-08-05T12:00:00Z"])
        let since = try #require(WikiTimelineDecoding.parseDate("2026-08-01T00:00:00Z"))
        let until = try #require(WikiTimelineDecoding.parseDate("2026-08-31T00:00:00Z"))
        #expect(timeline.outOfWindowCount(domain: since...until) == 0)
        #expect(timeline.undatedCount == 0)
    }

    @Test("the window's own bounds count as inside it")
    internal func boundsAreInclusive() throws {
        // An event exactly at `until` is the common case for a trailing window
        // ending at now — calling it out-of-window would be an off-by-one that
        // accuses the plot of hiding the newest event.
        let since = try #require(WikiTimelineDecoding.parseDate("2026-08-01T00:00:00Z"))
        let until = try #require(WikiTimelineDecoding.parseDate("2026-08-31T00:00:00Z"))
        let timeline = Self.timeline(["2026-08-01T00:00:00Z", "2026-08-31T00:00:00Z"])
        #expect(timeline.outOfWindowCount(domain: since...until) == 0)
    }

    // MARK: Note wording

    @Test("the note names each cause, and only the causes that apply")
    internal func summaryNamesCauses() {
        #expect(
            WikiEventsPageView.unplottedSummary(undated: 3, outside: 0)
                == "3 events not plotted: 3 with no timestamp"
        )
        #expect(
            WikiEventsPageView.unplottedSummary(undated: 0, outside: 2)
                == "2 events not plotted: 2 dated outside this window"
        )
        #expect(
            WikiEventsPageView.unplottedSummary(undated: 3, outside: 2)
                == "5 events not plotted: 3 with no timestamp, 2 dated outside this window"
        )
    }

    @Test("one event reads as singular")
    internal func summarySingular() {
        #expect(
            WikiEventsPageView.unplottedSummary(undated: 1, outside: 0)
                == "1 event not plotted: 1 with no timestamp"
        )
    }
}
