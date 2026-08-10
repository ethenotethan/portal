import Testing
import Foundation
@testable import Portal

/// Coverage for `SkillsFilterState` — the shared search/scope/sort state the
/// skills canvas panels all read, plus the seeded canvas layout.
@Suite("Skills Filter State")
@MainActor
internal struct SkillsFilterStateTests {

    private func skill(
        _ name: String,
        category: String = "general",
        source: String = "local",
        description: String = "",
        tags: [String] = [],
        command: String? = nil
    ) -> SkillInfo {
        SkillInfo(
            name: name,
            description: description,
            category: category,
            source: source,
            identifier: nil,
            tags: tags,
            skillMdPath: nil,
            skillDir: nil,
            skillMdPreview: nil,
            skillMdFullContent: nil,
            slashCommand: command ?? "/\(name)"
        )
    }

    // MARK: - Search

    @Test("an empty query keeps everything")
    internal func emptyQueryPassesThrough() {
        let state = SkillsFilterState()
        let skills = [skill("alpha"), skill("beta")]
        #expect(state.filtered(skills).map(\.name) == ["alpha", "beta"])
    }

    @Test("search matches the name case-insensitively")
    internal func searchMatchesName() {
        let state = SkillsFilterState()
        state.searchText = "ALPH"
        #expect(state.filtered([skill("alpha"), skill("beta")]).map(\.name) == ["alpha"])
    }

    /// Searching "review" should find `/code-review` by its command as readily as
    /// by its name — the four fields are the four things a user might remember.
    @Test("search also covers description, slash command, category, and tags")
    internal func searchCoversSecondaryFields() {
        let state = SkillsFilterState()
        let skills = [
            skill("a", description: "summarizes a pull request"),
            skill("b", command: "/code-review"),
            skill("c", category: "engineering/review"),
            skill("d", tags: ["reviewer"]),
            skill("e")
        ]
        state.searchText = "review"
        #expect(state.filtered(skills).map(\.name) == ["b", "c", "d"])
        state.searchText = "pull"
        #expect(state.filtered(skills).map(\.name) == ["a"])
    }

    @Test("a whitespace-only query is treated as no query")
    internal func whitespaceQueryIsIgnored() {
        let state = SkillsFilterState()
        state.searchText = "   "
        #expect(state.filtered([skill("a"), skill("b")]).count == 2)
        #expect(!state.hasActiveFilters)
    }

    // MARK: - Source

    @Test("a source filter keeps only that source")
    internal func filtersBySource() {
        let state = SkillsFilterState()
        state.filterSource = "github"
        let skills = [skill("a", source: "github"), skill("b", source: "official")]
        #expect(state.filtered(skills).map(\.name) == ["a"])
    }

    // MARK: - Scope

    /// Scoping to `writing` must include `writing/blog`, or the tree's rollup
    /// counts disagree with the list beside them.
    @Test("a scope includes nested folders, not just exact matches")
    internal func scopeMatchesNestedPaths() {
        let state = SkillsFilterState()
        state.scopedPath = ["writing"]
        #expect(state.matchesScope(skill("a", category: "writing")))
        #expect(state.matchesScope(skill("b", category: "writing/blog")))
        #expect(state.matchesScope(skill("c", category: "writing/blog/drafts")))
        #expect(!state.matchesScope(skill("d", category: "engineering")))
    }

    @Test("a deeper scope excludes its own ancestors")
    internal func scopeExcludesAncestors() {
        let state = SkillsFilterState()
        state.scopedPath = ["writing", "blog"]
        #expect(!state.matchesScope(skill("a", category: "writing")))
        #expect(state.matchesScope(skill("b", category: "writing/blog")))
    }

    /// A prefix of a *component*, not of a path — "write" must not match "writing".
    @Test("scope matching compares whole components, not string prefixes")
    internal func scopeComparesWholeComponents() {
        let state = SkillsFilterState()
        state.scopedPath = ["write"]
        #expect(!state.matchesScope(skill("a", category: "writing")))
    }

    @Test("no scope, or an empty scope, matches everything")
    internal func absentScopeMatchesAll() {
        let state = SkillsFilterState()
        #expect(state.matchesScope(skill("a", category: "")))
        state.scopedPath = []
        #expect(state.matchesScope(skill("b", category: "writing")))
    }

    @Test("uncategorized skills fall outside any folder scope")
    internal func uncategorizedIsOutsideScope() {
        let state = SkillsFilterState()
        state.scopedPath = ["writing"]
        #expect(!state.matchesScope(skill("loose", category: "")))
    }

    /// Re-selecting the scoped folder is the way *out* of a scope — otherwise the
    /// only escape is a separate affordance the user has to find.
    @Test("toggleScope sets a new scope and clears the one already active")
    internal func toggleScopeRoundTrips() {
        let state = SkillsFilterState()
        state.toggleScope(to: ["writing"])
        #expect(state.scopedPath == ["writing"])
        state.toggleScope(to: ["writing", "blog"])
        #expect(state.scopedPath == ["writing", "blog"])
        state.toggleScope(to: ["writing", "blog"])
        #expect(state.scopedPath == nil)
    }

    @Test("scope narrows the filtered set")
    internal func scopeFiltersTheSet() {
        let state = SkillsFilterState()
        state.scopedPath = ["writing"]
        let skills = [
            skill("a", category: "writing/blog"),
            skill("b", category: "engineering")
        ]
        #expect(state.filtered(skills).map(\.name) == ["a"])
    }

    // MARK: - Sorting

    @Test("name sort is case-insensitive alphabetical")
    internal func sortsByName() {
        let state = SkillsFilterState()
        let sorted = state.sorted([skill("Zebra"), skill("apple"), skill("Mango")])
        #expect(sorted.map(\.name) == ["apple", "Mango", "Zebra"])
    }

    /// Without a name fallback, skills sharing a category shuffle between renders.
    @Test("category sort falls back to name for a total order")
    internal func sortsByCategoryThenName() {
        let state = SkillsFilterState()
        state.sortOrder = .category
        let sorted = state.sorted([
            skill("zulu", category: "writing"),
            skill("alpha", category: "writing"),
            skill("mike", category: "engineering")
        ])
        #expect(sorted.map(\.name) == ["mike", "alpha", "zulu"])
    }

    @Test("source sort falls back to name for a total order")
    internal func sortsBySourceThenName() {
        let state = SkillsFilterState()
        state.sortOrder = .source
        let sorted = state.sorted([
            skill("zulu", source: "local"),
            skill("alpha", source: "local"),
            skill("mike", source: "github")
        ])
        #expect(sorted.map(\.name) == ["mike", "alpha", "zulu"])
    }

    @Test("visible filters before it sorts")
    internal func visibleFiltersThenSorts() {
        let state = SkillsFilterState()
        state.searchText = "a"
        // category "fruit" deliberately shares no letter with the query — the
        // default "general" would match every skill through the category field.
        let visible = state.visible([
            skill("zebra", category: "fruit"),
            skill("apple", category: "fruit"),
            skill("kiwi", category: "fruit")
        ])
        #expect(visible.map(\.name) == ["apple", "zebra"])
    }

    // MARK: - Expansion

    @Test("toggleExpanded opens then closes a folder")
    internal func toggleExpandedRoundTrips() {
        let state = SkillsFilterState()
        let grouping = SkillCategory.group([skill("a", category: "writing/blog")])
        let writing = grouping.roots[0]
        state.toggleExpanded(writing)
        #expect(state.expandedFolders.contains("writing"))
        state.toggleExpanded(writing)
        #expect(!state.expandedFolders.contains("writing"))
    }

    @Test("expandAll opens every depth; collapseAll clears them")
    internal func expandAllThenCollapseAll() {
        let state = SkillsFilterState()
        let grouping = SkillCategory.group([skill("a", category: "writing/blog/drafts")])
        state.expandAll(in: grouping)
        #expect(state.expandedFolders == ["writing", "writing/blog", "writing/blog/drafts"])
        state.collapseAll()
        #expect(state.expandedFolders.isEmpty)
    }

    // MARK: - Clearing

    @Test("hasActiveFilters reports each narrowing filter, and selection is not one")
    internal func reportsActiveFilters() {
        let state = SkillsFilterState()
        #expect(!state.hasActiveFilters)
        state.selectedSkillName = "alpha"
        #expect(!state.hasActiveFilters, "selecting a skill inspects it; it does not filter")
        state.searchText = "x"
        #expect(state.hasActiveFilters)
        state.searchText = ""
        state.filterSource = "github"
        #expect(state.hasActiveFilters)
        state.filterSource = nil
        state.scopedPath = ["writing"]
        #expect(state.hasActiveFilters)
    }

    /// Clearing filters must not drop the selection or the tree's open folders —
    /// those are navigation, and resetting them would collapse the user's place.
    @Test("clearFilters resets the filters and leaves selection and expansion alone")
    internal func clearFiltersPreservesNavigation() {
        let state = SkillsFilterState()
        state.searchText = "x"
        state.filterSource = "github"
        state.scopedPath = ["writing"]
        state.selectedSkillName = "alpha"
        state.expandedFolders = ["writing"]

        state.clearFilters()

        #expect(!state.hasActiveFilters)
        #expect(state.searchText.isEmpty)
        #expect(state.filterSource == nil)
        #expect(state.scopedPath == nil)
        #expect(state.selectedSkillName == "alpha")
        #expect(state.expandedFolders == ["writing"])
    }
}

/// The skills canvas's first-run arrangement. Guards the invariants the canvas
/// host relies on: the four seeded panels, all on-canvas, none overlapping.
@Suite("Skills Dashboard Layout")
internal struct SkillsDashboardLayoutTests {

    private let bounds = CGSize(width: 1400, height: 900)

    @Test("the seed places exactly the four starting panels")
    internal func seedsFourPanels() {
        let layout = DashboardLayout.seededSkillsDashboard(for: bounds)
        #expect(layout.panels.map(\.kind) == [
            .skillsFolders, .skillsStats, .skillsList, .skillsDetail
        ])
    }

    /// The editor and hub are addable but not seeded: both are large, and neither
    /// is useful until a skill is selected or a search is typed.
    @Test("the editor and hub are not seeded")
    internal func doesNotSeedEditorOrHub() {
        let kinds = DashboardLayout.seededSkillsDashboard(for: bounds).panels.map(\.kind)
        #expect(!kinds.contains(.skillsEditor))
        #expect(!kinds.contains(.skillsHub))
    }

    @Test("every seeded panel lies inside the canvas bounds")
    internal func seedStaysInBounds() {
        let layout = DashboardLayout.seededSkillsDashboard(for: bounds)
        for panel in layout.panels {
            #expect(panel.frame.minX >= 0)
            #expect(panel.frame.minY >= 0)
            #expect(panel.frame.maxX <= bounds.width + 0.5)
            #expect(panel.frame.maxY <= bounds.height + 0.5)
            #expect(panel.frame.width >= DashboardPanel.minSize.width)
            #expect(panel.frame.height >= DashboardPanel.minSize.height)
        }
    }

    @Test("no two seeded panels overlap")
    internal func seedDoesNotOverlap() {
        let panels = DashboardLayout.seededSkillsDashboard(for: bounds).panels
        for i in panels.indices {
            for j in panels.indices where j > i {
                let a = panels[i].frame.insetBy(dx: 0.5, dy: 0.5)
                #expect(!a.intersects(panels[j].frame.insetBy(dx: 0.5, dy: 0.5)),
                        "\(panels[i].kind.rawValue) overlaps \(panels[j].kind.rawValue)")
            }
        }
    }

    @Test("stats sits above the list, in the same column")
    internal func statsSitsAboveList() throws {
        let panels = DashboardLayout.seededSkillsDashboard(for: bounds).panels
        let stats = try #require(panels.first { $0.kind == .skillsStats })
        let list = try #require(panels.first { $0.kind == .skillsList })
        #expect(stats.frame.minX == list.frame.minX)
        #expect(stats.frame.width == list.frame.width)
        #expect(stats.frame.maxY <= list.frame.minY)
    }

    @Test("folders sit left of the list and detail sits right of it")
    internal func columnsRunLeftToRight() throws {
        let panels = DashboardLayout.seededSkillsDashboard(for: bounds).panels
        let folders = try #require(panels.first { $0.kind == .skillsFolders })
        let list = try #require(panels.first { $0.kind == .skillsList })
        let detail = try #require(panels.first { $0.kind == .skillsDetail })
        #expect(folders.frame.maxX <= list.frame.minX)
        #expect(list.frame.maxX <= detail.frame.minX)
    }

    /// A window smaller than three min-width columns can't tile cleanly; the seed
    /// must still produce usable panels rather than degenerate or negative frames.
    @Test("a canvas too small for three columns still yields valid frames")
    internal func seedSurvivesTinyBounds() {
        let tiny = CGSize(width: 320, height: 240)
        let layout = DashboardLayout.seededSkillsDashboard(for: tiny)
        #expect(layout.panels.count == 4)
        for panel in layout.panels {
            #expect(panel.frame.width >= DashboardPanel.minSize.width)
            #expect(panel.frame.height >= DashboardPanel.minSize.height)
            #expect(panel.frame.width.isFinite)
            #expect(panel.frame.height.isFinite)
            #expect(panel.frame.minX >= 0)
            #expect(panel.frame.minY >= 0)
        }
    }

    @Test("the skills layout key is distinct from the other canvas surfaces")
    internal func layoutKeyIsDistinct() {
        let keys = [
            DashboardLayout.skillsDashboardKey,
            DashboardLayout.cronDashboardKey,
            DashboardLayout.sessionsDashboardKey,
            DashboardLayout.dashboardKey
        ]
        #expect(Set(keys).count == keys.count, "arranging one surface must not disturb another")
    }
}
