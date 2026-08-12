import Testing
import Foundation
@testable import Portal

/// Coverage for `SkillCategory` — the `/`-separated folder paths and tree rollup
/// behind the skills canvas's folder panel. Pure logic, no gateway dependency.
@Suite("Skill Category Paths")
internal struct SkillCategoryTests {

    /// Minimal skill; only `name` and `category` matter to categorization.
    private func skill(_ name: String, category: String, source: String = "local", tags: [String] = []) -> SkillInfo {
        SkillInfo(
            name: name,
            description: "",
            category: category,
            source: source,
            identifier: nil,
            tags: tags,
            skillMdPath: nil,
            skillDir: nil,
            skillMdPreview: nil,
            skillMdFullContent: nil,
            slashCommand: "/\(name)"
        )
    }

    // MARK: - Splitting

    @Test("a multi-level category splits into path components")
    internal func splitsNestedCategory() {
        #expect(SkillCategory.split(category: "writing/blog/drafts") == ["writing", "blog", "drafts"])
    }

    @Test("a category with no separator is a single-component path")
    internal func splitsBareCategory() {
        #expect(SkillCategory.split(category: "general") == ["general"])
    }

    @Test("an empty category yields no path — uncategorized, not guessed at")
    internal func splitsEmptyCategory() {
        #expect(SkillCategory.split(category: "").isEmpty)
        #expect(SkillCategory.split(category: "   ").isEmpty)
    }

    /// An agent concatenating category fragments shouldn't produce phantom levels.
    @Test("repeated and trailing separators collapse rather than creating empty levels")
    internal func normalizesRedundantSeparators() {
        #expect(SkillCategory.split(category: "writing//blog/") == ["writing", "blog"])
        #expect(SkillCategory.split(category: "/writing/ blog /") == ["writing", "blog"])
    }

    @Test("uncategorized detection follows the empty path")
    internal func detectsUncategorized() {
        #expect(SkillCategory.isUncategorized(skill("a", category: "")))
        #expect(!SkillCategory.isUncategorized(skill("b", category: "writing")))
    }

    // MARK: - Display

    @Test("a path renders with breadcrumb separators; the root reads as Uncategorized")
    internal func rendersDisplayPath() {
        #expect(SkillCategory.displayPath(["writing", "blog"]) == "writing › blog")
        #expect(SkillCategory.displayPath([]) == "Uncategorized")
    }

    // MARK: - allPaths

    /// Navigating to a parent level is as reasonable as navigating to a leaf, so
    /// `writing` must exist even when only `writing/blog` holds a skill.
    @Test("allPaths includes intermediate levels that hold no skills of their own")
    internal func allPathsIncludesIntermediates() {
        let paths = SkillCategory.allPaths(in: [skill("a", category: "writing/blog/drafts")])
        #expect(paths == [["writing"], ["writing", "blog"], ["writing", "blog", "drafts"]])
    }

    @Test("allPaths is sorted shallowest-first then alphabetically, and deduplicated")
    internal func allPathsSortsAndDeduplicates() {
        let paths = SkillCategory.allPaths(in: [
            skill("a", category: "zebra/tail"),
            skill("b", category: "apple"),
            skill("c", category: "zebra/head"),
            skill("d", category: "zebra/tail")
        ])
        #expect(paths == [["apple"], ["zebra"], ["zebra", "head"], ["zebra", "tail"]])
    }

    @Test("uncategorized skills contribute no paths")
    internal func allPathsSkipsUncategorized() {
        #expect(SkillCategory.allPaths(in: [skill("a", category: "")]).isEmpty)
    }

    // MARK: - Grouping

    @Test("grouping builds a forest of roots sorted by name")
    internal func groupsIntoSortedRoots() {
        let grouping = SkillCategory.group([
            skill("z", category: "zebra"),
            skill("a", category: "apple")
        ])
        #expect(grouping.roots.map(\.name) == ["apple", "zebra"])
        #expect(grouping.uncategorized.isEmpty)
    }

    @Test("grouping nests children under their parent path")
    internal func groupsNestsChildren() {
        let grouping = SkillCategory.group([skill("a", category: "writing/blog")])
        #expect(grouping.roots.count == 1)
        let writing = grouping.roots[0]
        #expect(writing.path == ["writing"])
        #expect(writing.skills.isEmpty, "no skill sits directly at writing/")
        #expect(writing.children.map(\.name) == ["blog"])
        #expect(writing.children[0].skills.map(\.name) == ["a"])
    }

    /// A parent with several child folders exercises the child-level sort inside
    /// `buildNode` (distinct from the root sort): children are alphabetized by
    /// their own folder name, not by insertion order or root order.
    @Test("grouping sorts nested child folders alphabetically under their parent")
    internal func groupsSortsNestedChildren() {
        let grouping = SkillCategory.group([
            skill("z", category: "writing/zebra"),
            skill("a", category: "writing/apple"),
            skill("m", category: "writing/mango"),
        ])
        #expect(grouping.roots.count == 1)
        let writing = grouping.roots[0]
        #expect(writing.path == ["writing"])
        #expect(writing.children.map(\.name) == ["apple", "mango", "zebra"])
    }

    @Test("uncategorized skills land in their own bucket, not a folder")
    internal func groupsUncategorizedSeparately() {
        let grouping = SkillCategory.group([
            skill("filed", category: "writing"),
            skill("loose", category: "")
        ])
        #expect(grouping.roots.map(\.name) == ["writing"])
        #expect(grouping.uncategorized.map(\.name) == ["loose"])
    }

    /// The active sort governs the rows a user sees, so grouping must not
    /// re-sort skills within a level — only folder levels get alphabetized.
    @Test("grouping preserves the incoming skill order within a level")
    internal func groupsPreservesSkillOrder() {
        let grouping = SkillCategory.group([
            skill("zulu", category: "writing"),
            skill("alpha", category: "writing")
        ])
        #expect(grouping.roots[0].skills.map(\.name) == ["zulu", "alpha"])
    }

    @Test("an empty input groups to the empty grouping")
    internal func groupsEmptyInput() {
        let grouping = SkillCategory.group([])
        #expect(grouping.isEmpty)
        #expect(grouping.hasNoCategories)
        #expect(grouping == SkillCategoryGrouping.empty)
    }

    // MARK: - Rollup

    /// A collapsed parent must still summarize everything beneath it — that
    /// rollup is the point of the N-dimensional paths.
    @Test("totalCount rolls the whole subtree up to each ancestor")
    internal func rollsUpTotalCount() {
        let grouping = SkillCategory.group([
            skill("a", category: "writing"),
            skill("b", category: "writing/blog"),
            skill("c", category: "writing/blog/drafts"),
            skill("d", category: "other")
        ])
        let writing = try? #require(grouping.roots.first { $0.name == "writing" })
        #expect(writing?.totalCount == 3)
        #expect(writing?.skills.count == 1)
        let blog = writing?.children.first
        #expect(blog?.totalCount == 2)
        #expect(grouping.roots.first { $0.name == "other" }?.totalCount == 1)
    }

    @Test("hasChildren is true for a leaf folder that holds only skills")
    internal func leafWithSkillsHasChildren() {
        let grouping = SkillCategory.group([skill("a", category: "writing")])
        #expect(grouping.roots[0].hasChildren)
        #expect(grouping.roots[0].children.isEmpty)
    }

    @Test("allFolderIDs walks every depth so expand-all reaches the leaves")
    internal func collectsAllFolderIDs() {
        let grouping = SkillCategory.group([
            skill("a", category: "writing/blog/drafts"),
            skill("b", category: "other")
        ])
        #expect(grouping.allFolderIDs == [
            "writing", "writing/blog", "writing/blog/drafts", "other"
        ])
    }

    // MARK: - Rows

    @Test("a collapsed folder contributes its header only")
    internal func collapsedFolderHidesSubtree() {
        let grouping = SkillCategory.group([skill("a", category: "writing/blog")])
        let rows = grouping.rows(expanded: [])
        #expect(rows.count == 1)
        #expect(rows[0].id == "dir:writing")
    }

    @Test("an expanded folder emits its skills then its child folders, indented one level")
    internal func expandedFolderEmitsSkillsThenChildren() {
        let grouping = SkillCategory.group([
            skill("direct", category: "writing"),
            skill("nested", category: "writing/blog")
        ])
        let rows = grouping.rows(expanded: ["writing"])
        #expect(rows.map(\.id) == ["dir:writing", "skill:direct", "dir:writing/blog"])
        if case .folder(_, let depth, let isExpanded) = rows[0] {
            #expect(depth == 0)
            #expect(isExpanded)
        } else {
            Issue.record("expected the first row to be the writing folder")
        }
        if case .skill(_, let depth) = rows[1] {
            #expect(depth == 1)
        } else {
            Issue.record("expected the second row to be a skill")
        }
    }

    /// Expanding a child whose parent is closed must not leak rows: the subtree
    /// is omitted wholesale, which is what keeps a deep tree cheap to render.
    @Test("expanding a child while its parent is collapsed shows nothing extra")
    internal func collapsedParentSuppressesExpandedChild() {
        let grouping = SkillCategory.group([skill("a", category: "writing/blog")])
        let rows = grouping.rows(expanded: ["writing/blog"])
        #expect(rows.map(\.id) == ["dir:writing"])
    }

    @Test("fully expanding a three-level tree emits every folder and skill in order")
    internal func fullyExpandedTreeEmitsEverything() {
        let grouping = SkillCategory.group([skill("deep", category: "writing/blog/drafts")])
        let rows = grouping.rows(expanded: grouping.allFolderIDs)
        #expect(rows.map(\.id) == [
            "dir:writing", "dir:writing/blog", "dir:writing/blog/drafts", "skill:deep"
        ])
        if case .skill(_, let depth) = rows[3] {
            #expect(depth == 3, "the leaf skill indents one level past its folder")
        } else {
            Issue.record("expected the last row to be the deep skill")
        }
    }

    /// Uncategorized skills are rendered by the panel's own section, not by
    /// `rows(expanded:)` — otherwise they'd appear twice.
    @Test("rows covers only the folder forest, not the uncategorized bucket")
    internal func rowsExcludesUncategorized() {
        let grouping = SkillCategory.group([skill("loose", category: "")])
        #expect(grouping.rows(expanded: grouping.allFolderIDs).isEmpty)
        #expect(grouping.uncategorized.count == 1)
    }
}
