import Testing
import Foundation
@testable import Portal

/// Pins the three artifact kinds added for issue #41 — checklist, kanban,
/// calendar. Covers spec parsing, fence-language routing (including the mermaid
/// `kanban` content-disambiguation), per-kind merge (union by id so user edits
/// survive an agent re-emit), and the live action paths (checklist toggle,
/// kanban column move) through `ArtifactActionEngine`.

@Suite("Checklist Spec")
private struct ChecklistSpecTests {

    @Test("Parses items; id falls back to label; done accepts bool/string")
    private func parses() {
        let spec = ChecklistSpec.parse("""
        {"title": "Launch", "items": [
          {"id": "dns", "label": "Cut over DNS", "done": true},
          {"label": "Smoke test", "note": "prod", "done": "1"},
          {"id": "ann", "label": "Announce"}
        ]}
        """)
        #expect(spec?.title == "Launch")
        #expect(spec?.items.count == 3)
        #expect(spec?.items[0].done == true)
        #expect(spec?.items[1].id == "Smoke test")   // falls back to label
        #expect(spec?.items[1].done == true)          // "1" is truthy
        #expect(spec?.items[1].note == "prod")
        #expect(spec?.items[2].done == false)         // absent → false
        #expect(spec?.completedCount == 2)
    }

    @Test("Tombstoned items drop; empty/malformed return nil")
    private func filtersAndFails() {
        let spec = ChecklistSpec.parse("""
        {"items": [{"label": "kept"}, {"label": "gone", "_deleted": true}]}
        """)
        #expect(spec?.items.count == 1)
        #expect(spec?.items.first?.label == "kept")
        #expect(ChecklistSpec.parse("{\"items\": []}") == nil)
        #expect(ChecklistSpec.parse("not json") == nil)
    }
}

@Suite("Kanban Spec")
private struct KanbanSpecTests {

    @Test("Parses artifact-level overview markdown separately from cards")
    private func parsesOverview() throws {
        let spec = try #require(KanbanSpec.parse("""
        {"title": "Engineering", "overview": "## Goal\\nPay down **lint debt**.",
         "columns": ["Todo"], "cards": [{"id": "A", "title": "Fix lint", "column": "Todo"}]}
        """))

        #expect(spec.overview == "## Goal\nPay down **lint debt**.")
        #expect(spec.cards.count == 1)
    }

    @Test("Parses cards; undeclared columns append; id falls back to title")
    private func parses() {
        let spec = KanbanSpec.parse("""
        {"title": "Sprint", "columns": ["Todo", "Doing"], "cards": [
          {"id": "A", "title": "First", "column": "Doing", "tag": "feat"},
          {"title": "Second", "column": "Todo"},
          {"id": "C", "title": "Third", "column": "Review"}
        ]}
        """)
        #expect(spec?.cards.count == 3)
        // Review referenced but not declared → appended after declared columns.
        #expect(spec?.columns == ["Todo", "Doing", "Review"])
        #expect(spec?.cards(in: "Doing").count == 1)
        #expect(spec?.cards[1].id == "Second")   // falls back to title
        #expect(spec?.cards[0].tag == "feat")
    }

    @Test("Card detail + extra scalar fields populate for inline expansion")
    private func expandableDetail() throws {
        let spec = try #require(KanbanSpec.parse("""
        {"cards": [
          {"id": "A", "title": "Rich", "column": "Todo", "desc": "long body",
           "assignee": "me", "points": 3, "blocked": true, "sub": {"x": 1}},
          {"id": "B", "title": "Bare", "column": "Todo"}
        ]}
        """))
        let rich = try #require(spec.cards.first { $0.id == "A" })
        #expect(rich.detail == "long body")           // desc → detail
        #expect(rich.hasDetail)
        // Extras are sorted by key; reserved keys and nested objects excluded.
        #expect(rich.extra.map(\.key) == ["assignee", "blocked", "points"])
        #expect(rich.extra.first { $0.key == "points" }?.value == "3")
        #expect(rich.extra.first { $0.key == "blocked" }?.value == "true")
        let bare = try #require(spec.cards.first { $0.id == "B" })
        #expect(!bare.hasDetail)                       // nothing to expand
        #expect(bare.extra.isEmpty)
    }

    @Test("No columns declared derives from cards; malformed returns nil")
    private func derivesColumns() {
        let spec = KanbanSpec.parse("""
        {"cards": [{"title": "x", "column": "B"}, {"title": "y", "column": "A"}]}
        """)
        #expect(spec?.columns == ["B", "A"])   // first-appearance order
        #expect(KanbanSpec.parse("{\"cards\": []}") == nil)
        #expect(KanbanSpec.parse("kanban\n  Todo") == nil)  // mermaid text, not JSON
    }
}

@Suite("Calendar Spec")
private struct CalendarSpecTests {

    @Test("Parses dated events; id falls back to title; requires a date")
    private func parses() throws {
        let spec = CalendarSpec.parse("""
        {"title": "August", "events": [
          {"id": "ga", "date": "2026-08-20", "title": "GA", "tag": "launch"},
          {"date": "2026-08-12", "title": "Review", "time": "14:00"},
          {"title": "No date", "note": "dropped"}
        ]}
        """)
        #expect(spec?.events.count == 2)   // dateless event dropped
        #expect(spec?.events.first { $0.id == "Review" }?.time == "14:00")
        let aug = spec?.months().first
        #expect(aug != nil)
        let gaDay = try #require(TimelineSpec.parseDate("2026-08-20"))
        let onGA = spec?.events(on: gaDay) ?? []
        #expect(onGA.count == 1)
    }

    @Test("Day lookup sorts events and months are distinct and chronological")
    private func eventOrdering() throws {
        let spec = try #require(CalendarSpec.parse("""
        {"events": [
          {"id": "sep", "date": "2026-09-01T12:00:00Z", "title": "September"},
          {"id": "late", "date": "2026-08-20T18:00:00Z", "title": "Late"},
          {"id": "jul", "date": "2026-07-31T12:00:00Z", "title": "July"},
          {"id": "early", "date": "2026-08-20T09:00:00Z", "title": "Early"}
        ]}
        """))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let augustDay = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 20
        )))

        #expect(spec.events(on: augustDay, calendar: calendar).map(\.id) == ["early", "late"])
        #expect(spec.months(calendar: calendar).map { calendar.component(.month, from: $0) } == [7, 8, 9])
    }

    @Test("Empty/malformed return nil")
    private func fails() {
        #expect(CalendarSpec.parse("{\"events\": []}") == nil)
        #expect(CalendarSpec.parse("not json") == nil)
    }
}

@Suite("New kind fence routing")
private struct NewKindRoutingTests {

    @Test("checklist/calendar route by language; kanban disambiguates by JSON")
    private func routes() {
        #expect(MarkdownParser.isChecklistLanguage("checklist"))
        #expect(MarkdownParser.isChecklistLanguage(" Checklist "))
        #expect(!MarkdownParser.isChecklistLanguage("check"))
        #expect(MarkdownParser.isCalendarLanguage("calendar"))
        #expect(!MarkdownParser.isCalendarLanguage("timeline"))
        // kanban JSON → native; kanban mermaid text → falls through.
        #expect(MarkdownParser.isKanbanBlock(language: "kanban", code: "{\"cards\": []}"))
        #expect(!MarkdownParser.isKanbanBlock(language: "kanban", code: "kanban\n  Todo[Task]"))
        #expect(!MarkdownParser.isKanbanBlock(language: "mermaid", code: "{\"cards\": []}"))
    }
}

@Suite("New kind merge")
private struct NewKindMergeTests {

    @Test("Checklist unions items by id; user's done survives agent re-emit")
    private func checklistMerge() throws {
        // User toggled "dns" done; agent re-emits the list without that flag.
        let existing = "{\"items\": [{\"id\": \"dns\", \"label\": \"DNS\", \"done\": true}]}"
        let incoming = """
        {"items": [{"id": "dns", "label": "DNS"}, {"id": "smoke", "label": "Smoke"}]}
        """
        let merged = ArtifactMerge.merge(kind: "checklist", existing: existing, incoming: incoming)
        let spec = try #require(ChecklistSpec.parse(merged))
        #expect(spec.items.count == 2)
        #expect(spec.items.first { $0.id == "dns" }?.done == true)  // preserved
    }

    @Test("Kanban unions cards by id; deleted card is not resurrected")
    private func kanbanMerge() throws {
        let existing = "{\"cards\": [{\"id\": \"A\", \"title\": \"a\", \"column\": \"Todo\", \"_deleted\": true}]}"
        let incoming = "{\"columns\": [\"Todo\"], \"cards\": [{\"id\": \"A\", \"title\": \"a\", \"column\": \"Todo\"}]}"
        let merged = ArtifactMerge.merge(kind: "kanban", existing: existing, incoming: incoming)
        // Parse strips tombstones, so the resurrected-but-tombstoned card is gone.
        #expect(KanbanSpec.parse(merged) == nil)
    }

    @Test("Kanban overview is board context and follows top-level merge semantics")
    private func kanbanOverviewMerge() throws {
        let existing = """
        {"overview": "Persistent goal", "cards": [{"id": "A", "title": "a", "column": "Todo"}]}
        """
        let omitting = """
        {"cards": [{"id": "A", "title": "a", "column": "Done"}]}
        """
        let replacing = """
        {"overview": "Updated goal", "cards": [{"id": "A", "title": "a", "column": "Done"}]}
        """

        let preserved = ArtifactMerge.merge(kind: "kanban", existing: existing, incoming: omitting)
        #expect(KanbanSpec.parse(preserved)?.overview == "Persistent goal")
        let updated = ArtifactMerge.merge(kind: "kanban", existing: existing, incoming: replacing)
        #expect(KanbanSpec.parse(updated)?.overview == "Updated goal")
    }

    @Test("Calendar unions events by id across re-emits")
    private func calendarMerge() throws {
        let existing = "{\"events\": [{\"id\": \"a\", \"date\": \"2026-08-01\", \"title\": \"A\"}]}"
        let incoming = "{\"events\": [{\"id\": \"b\", \"date\": \"2026-08-02\", \"title\": \"B\"}]}"
        let merged = ArtifactMerge.merge(kind: "calendar", existing: existing, incoming: incoming)
        let spec = try #require(CalendarSpec.parse(merged))
        #expect(spec.events.count == 2)
    }
}

@Suite("New kind actions")
private struct NewKindActionTests {

    @Test("Checklist toggle sets done on the item by id")
    private func checklistToggle() throws {
        let content = "{\"items\": [{\"id\": \"dns\", \"label\": \"DNS\", \"done\": false}]}"
        let toggled = try #require(
            ArtifactActionEngine.setField(in: content, kind: "checklist",
                                          entryKey: "dns", field: "done", value: true)
        )
        let spec = try #require(ChecklistSpec.parse(toggled))
        #expect(spec.items.first?.done == true)
    }

    @Test("Checklist toggle matches an item lacking an id by its label")
    private func checklistToggleByLabel() throws {
        let content = "{\"items\": [{\"label\": \"Smoke test\", \"done\": false}]}"
        let toggled = try #require(
            ArtifactActionEngine.setField(in: content, kind: "checklist",
                                          entryKey: "Smoke test", field: "done", value: true)
        )
        #expect(ChecklistSpec.parse(toggled)?.items.first?.done == true)
    }

    @Test("Kanban move sets the card's column")
    private func kanbanMove() throws {
        let content = "{\"columns\": [\"Todo\", \"Done\"], \"cards\": [{\"id\": \"A\", \"title\": \"a\", \"column\": \"Todo\"}]}"
        let moved = try #require(
            ArtifactActionEngine.setField(in: content, kind: "kanban",
                                          entryKey: "A", field: "column", value: "Done")
        )
        #expect(KanbanSpec.parse(moved)?.cards.first?.column == "Done")
    }

    @Test("Unknown entry key returns nil (no mutation)")
    private func missingEntry() {
        let content = "{\"items\": [{\"id\": \"dns\", \"label\": \"DNS\"}]}"
        #expect(ArtifactActionEngine.setField(in: content, kind: "checklist",
                                              entryKey: "ghost", field: "done", value: true) == nil)
    }
}
