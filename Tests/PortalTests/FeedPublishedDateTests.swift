import Testing
import Foundation
@testable import Portal

/// Publication-date handling for feed articles.
///
/// Regression context: the feed showed every article with the same age (e.g.
/// "1h ago") no matter when it was actually written, because the card rendered
/// `ts` (ingest time — identical across an ingest batch) instead of
/// `published_ts` (the real source publication date). Backdated ingests
/// (arXiv/archive backfill) made this obvious: a paper from 2025 read "1h ago".
@Suite("Feed published date")
internal struct FeedPublishedDateTests {

    private func article(ts: String = "", publishedTs: String = "",
                        approx: Bool = false) -> FeedArticle {
        FeedArticle(
            id: "a1", title: "t", url: "https://example.com/a", summary: "s",
            source: "agentic-payments", tags: [], imageUrl: "", ts: ts,
            publishedTs: publishedTs, validTimeApprox: approx
        )
    }

    private func iso(daysAgo: Double) -> String {
        let d = Date().addingTimeInterval(-daysAgo * 86_400)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }

    // MARK: - The core regression

    @Test("Display date is the publication date, not the ingest time")
    internal func prefersPublishedOverIngest() throws {
        // Ingested moments ago, but published two years back.
        let a = article(ts: iso(daysAgo: 0.02), publishedTs: "2024-03-05T12:00:00Z")
        let shown = try #require(a.displayDate)
        let comps = Calendar.current.dateComponents(
            [.year, .month], from: shown)
        #expect(comps.year == 2024)
        #expect(comps.month == 3)
    }

    @Test("Two articles ingested in one batch get DIFFERENT ages")
    internal func batchDoesNotCollapseToOneAge() {
        // The exact shape of the bug: one shared ingest ts, distinct pub dates.
        let sharedIngest = iso(daysAgo: 0.02)
        let recent = article(ts: sharedIngest, publishedTs: iso(daysAgo: 1))
        let old = article(ts: sharedIngest, publishedTs: "2025-07-24T21:14:36Z")
        #expect(recent.relativeTime != old.relativeTime)
        #expect(!recent.relativeTime.isEmpty)
        #expect(!old.relativeTime.isEmpty)
    }

    @Test("Missing published_ts falls back to ingest time (older payloads)")
    internal func fallsBackToIngest() throws {
        let a = article(ts: "2026-01-02T03:04:05Z", publishedTs: "")
        let shown = try #require(a.displayDate)
        #expect(Calendar.current.component(.year, from: shown) == 2026)
    }

    @Test("No usable date yields an empty label rather than a wrong one")
    internal func noDateIsEmpty() {
        #expect(article(ts: "", publishedTs: "").relativeTime.isEmpty)
        #expect(article(ts: "not-a-date", publishedTs: "also-bad").relativeTime.isEmpty)
        #expect(article(ts: "", publishedTs: "").displayDate == nil)
    }

    // MARK: - Timestamp shape tolerance (the backend mixes these)

    @Test("Parses fractional-second, Z, and numeric-offset stamps alike")
    internal func parsesMixedISOShapes() {
        // Real values observed in ~/.hermes/digests/feed.json.
        #expect(article(publishedTs: "2026-08-19T00:30:32.807357+00:00").displayDate != nil)
        #expect(article(publishedTs: "2026-08-14T08:26:19Z").displayDate != nil)
        #expect(article(publishedTs: "2026-06-11T00:00:00Z").displayDate != nil)
        #expect(article(publishedTs: "2026-08-19T05:00:00+00:00").displayDate != nil)
    }

    // MARK: - Label formatting

    @Test("Recent items read relatively; older items show an absolute date")
    internal func switchesToAbsoluteDateWhenOld() {
        // Within a week -> relative phrasing ("2d ago"): contains a digit and
        // is not a month name.
        let recent = article(publishedTs: iso(daysAgo: 2)).relativeTime
        #expect(!recent.isEmpty)
        #expect(!recent.contains(","))

        // Older than a week -> absolute. "8 months ago" is useless for a
        // backfilled paper, so we show the real date instead.
        let old = article(publishedTs: "2025-07-24T21:14:36Z").relativeTime
        #expect(old.contains("2025"))
    }

    @Test("Same-year absolute labels omit the year; other years include it")
    internal func yearOnlyWhenDifferent() {
        let thisYear = Calendar.current.component(.year, from: Date())
        let sameYear = article(publishedTs: "\(thisYear)-01-15T00:00:00Z").relativeTime
        #expect(!sameYear.contains("\(thisYear)"))
        #expect(article(publishedTs: "2025-10-31T15:29:31Z").relativeTime.contains("2025"))
    }

    @Test("Approximate dates are marked, so a guess isn't shown as fact")
    internal func approximateDateIsMarked() {
        // Sources with no date on the index page (e.g. Coinbase) get stamped at
        // fetch time; the UI must not present that as a confirmed date.
        let guessed = article(publishedTs: "2025-05-06T00:00:00Z", approx: true)
        let known = article(publishedTs: "2025-05-06T00:00:00Z", approx: false)
        #expect(guessed.relativeTime.hasPrefix("~"))
        #expect(!known.relativeTime.hasPrefix("~"))
        #expect(guessed.relativeTime.dropFirst() == known.relativeTime)
    }

    // MARK: - Decoding

    @Test("Codable decodes published_ts and valid_time_approx")
    internal func decodesNewFields() throws {
        let jsonString = """
        {"id":"x","title":"t","url":"u","summary":"s","source":"agentic-payments",
         "ts":"2026-08-19T00:30:32.807357+00:00",
         "published_ts":"2026-06-11T00:00:00Z","valid_time_approx":true}
        """
        let json = Data(jsonString.utf8)
        let a = try JSONDecoder().decode(FeedArticle.self, from: json)
        #expect(a.publishedTs == "2026-06-11T00:00:00Z")
        #expect(a.validTimeApprox)
        #expect(Calendar.current.component(.month, from: try #require(a.displayDate)) == 6)
    }

    @Test("Payloads without the new keys still decode (backward compatible)")
    internal func decodesLegacyPayload() throws {
        let jsonString = """
        {"id":"x","title":"t","url":"u","summary":"s","source":"agentic-payments",
         "ts":"2026-08-19T00:30:32.807357+00:00"}
        """
        let json = Data(jsonString.utf8)
        let a = try JSONDecoder().decode(FeedArticle.self, from: json)
        #expect(a.publishedTs.isEmpty)
        #expect(!a.validTimeApprox)
        #expect(a.displayDate != nil)  // falls back to ts
    }

    @Test("withID preserves the publication fields")
    internal func withIDPreservesDates() {
        // The feed de-duplicates ids via withID; dropping these there would
        // silently reset re-keyed articles to ingest-time display.
        let a = article(ts: iso(daysAgo: 0.02),
                       publishedTs: "2025-10-31T15:29:31Z", approx: true)
        let b = a.withID("new-id")
        #expect(b.publishedTs == a.publishedTs)
        #expect(b.validTimeApprox == a.validTimeApprox)
        #expect(b.relativeTime == a.relativeTime)
    }
}
