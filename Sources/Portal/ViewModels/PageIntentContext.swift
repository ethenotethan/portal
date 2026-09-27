import CryptoKit
import Foundation

// MARK: - Page intents: the page as the agent's context

/// The identity of a page context the intent dock can talk to. One scope is one
/// agent session: every individual wiki gets its own, and the cron graph gets
/// one, so a conversation about the research wiki never bleeds into one about
/// the runtime graph.
internal enum PageIntentScope: Hashable, Codable, Sendable {
    case wiki(name: String)
    case cronGraph

    /// A stable key for dictionaries and persistence.
    internal var id: String {
        switch self {
        case .wiki(let name): return "wiki:\(name)"
        case .cronGraph: return "cron-graph"
        }
    }

    /// What the dock's header calls this page.
    internal var title: String {
        switch self {
        case .wiki(let name): return "Wiki: \(name)"
        case .cronGraph: return "Cron graph"
        }
    }
}

/// What the page is showing right now, reduced to the facts the agent needs:
/// where it is (`scope`), what is selected or visible (`stateLines`) and what it
/// should load with its tools before it answers (`preloadSteps`). A pure value
/// built from the page's state so it is testable without a view model, and
/// diffable (`digest`) so the dock only re-sets the session's prompt when the
/// page actually changed.
internal struct PageIntentContext: Equatable, Sendable {
    internal let scope: PageIntentScope
    internal let title: String
    internal let stateLines: [String]
    internal let preloadSteps: [String]

    internal init(scope: PageIntentScope, stateLines: [String], preloadSteps: [String]) {
        self.scope = scope
        self.title = scope.title
        self.stateLines = stateLines
        self.preloadSteps = preloadSteps
    }

    /// Stable across equal contexts; changes when any line changes.
    internal var digest: String {
        let joined = ([scope.id] + stateLines + ["--"] + preloadSteps).joined(separator: "\n")
        return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Builders

    /// The wiki page's context. `name` is the selected wiki (`nil` is the
    /// gateway's default wiki, shown as "default" in the switcher).
    internal static func wiki(
        name: String?,
        availableWikis: [String],
        selectedPage: WikiPage?,
        pinnedPaths: [String],
        searchQuery: String,
        focusedEventKey: String?,
        pageCount: Int
    ) -> PageIntentContext {
        let wikiName = Self.wikiName(name)
        var lines: [String] = ["Wiki: \(wikiName) · \(pageCount) page(s) in the graph"]
        if availableWikis.count > 1 {
            lines.append("Other wikis on this gateway: \(availableWikis.filter { $0 != wikiName }.joined(separator: ", "))")
        }
        var steps: [String] = []
        if let page = selectedPage {
            lines.append("Open page: \(page.path) — \"\(page.title)\" (type \(page.type)\(page.contested ? ", contested" : ""))")
            if !page.tagPath.isEmpty {
                lines.append("Taxonomy: \(page.tagPath.joined(separator: "; "))")
            }
            steps.append("Read the open page \(page.path) in wiki \(wikiName) (the wiki.page RPC or your wiki read tool) so you know its frontmatter and body.")
            steps.append("Scan the wiki graph around it (wiki.scan) and list the pages it links to and that link to it.")
        } else {
            lines.append("No page is open; the user is looking at the whole graph.")
            steps.append("Scan the wiki graph (wiki.scan) for wiki \(wikiName) and summarise its shape: page count, main taxonomy branches, most-linked pages.")
        }
        if !pinnedPaths.isEmpty {
            lines.append("Pinned pages: \(pinnedPaths.joined(separator: ", "))")
            steps.append("Read the pinned pages too: \(pinnedPaths.joined(separator: ", ")).")
        }
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            lines.append("Search filter in effect: \"\(query)\"")
        }
        if let focusedEventKey, !focusedEventKey.isEmpty {
            lines.append("Focused event: \(focusedEventKey)")
            steps.append("Look up the focused event in the wiki's changesets (wiki.changesets) and say what changed.")
        }
        return PageIntentContext(scope: .wiki(name: wikiName), stateLines: lines, preloadSteps: steps)
    }

    /// The cron graph's context.
    internal static func cronGraph(
        selectedNode: CronGraphNode?,
        collapsedGroups: Set<String>,
        showRevisions: Bool,
        nodeCount: Int,
        jobCount: Int
    ) -> PageIntentContext {
        var lines: [String] = ["Cron dataflow graph: \(nodeCount) node(s), \(jobCount) job(s)"]
        var steps: [String] = ["Load the cron dataflow graph (cron.graph) so you have every job, service, resource and sink with their edges."]
        if let node = selectedNode {
            var summary = "Selected node: \(node.label) [\(node.kind)/\(node.type)] id \(node.id)"
            if let schedule = node.schedule, !schedule.isEmpty { summary += ", schedule \(schedule)" }
            if !node.enabled { summary += ", disabled" }
            if let status = node.lastStatus, !status.isEmpty { summary += ", last run \(status)" }
            lines.append(summary)
            if !node.description.isEmpty {
                lines.append("Node description: \(node.description)")
            }
            if let health = node.health {
                lines.append("Service health: \(health.status)")
            }
            steps.append("Describe node \(node.id) from the graph: its inputs, outputs, side effects and what depends on it.")
            if node.kind == "job" {
                steps.append("Read the job's definition and recent runs (cron.manage describe / history) before proposing changes.")
            }
            if let architecture = node.architecture {
                steps.append("This service has an architecture model (\(architecture.ref)): call architecture.describe "
                + "and summarise its components, invariants and the last check.")
            }
            if !node.sourceFiles.isEmpty {
                let paths = node.sourceFiles.prefix(6).map(\.path).joined(separator: ", ")
                steps.append("Its source files are browsable: \(paths)\(node.sourceFiles.count > 6 ? ", …" : ""). Read them if the question is about the code.")
            }
            if let wikiPath = node.wikiPagePath {
                steps.append("It is a wiki resource: read \(wikiPath) (wiki.page).")
            }
        } else {
            lines.append("No node is selected; the user is looking at the whole graph.")
        }
        if !collapsedGroups.isEmpty {
            lines.append("Collapsed groups: \(collapsedGroups.sorted().joined(separator: ", "))")
        }
        if showRevisions {
            lines.append("The revisions (changeset) panel is open.")
            steps.append("Load the recent cron changesets so you can speak to what changed and when.")
        }
        return PageIntentContext(scope: .cronGraph, stateLines: lines, preloadSteps: steps)
    }

    internal static func wikiName(_ name: String?) -> String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "default" : trimmed
    }
}
