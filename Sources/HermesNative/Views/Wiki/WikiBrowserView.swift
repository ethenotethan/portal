import SwiftUI

// MARK: - Folder Tree Model

private struct WikiFolderNode: Identifiable {
    let id: String
    let name: String
    let subfolders: [WikiFolderNode]
    let files: [WikiPage]
    var pageCount: Int { files.count + subfolders.reduce(0) { $0 + $1.pageCount } }
}

private func buildFolderTree(_ pages: [WikiPage]) -> WikiFolderNode {
    let entries = pages.map { (page: $0, comps: $0.path.split(separator: "/").map(String.init)) }
    return buildFolderNode(name: "", id: "", entries: entries, depth: 0)
}

private func buildFolderNode(name: String, id: String, entries: [(page: WikiPage, comps: [String])], depth: Int) -> WikiFolderNode {
    var files: [WikiPage] = []
    var grouped: [String: [(page: WikiPage, comps: [String])]] = [:]
    for entry in entries {
        if entry.comps.count - depth <= 1 {
            files.append(entry.page)
        } else {
            grouped[entry.comps[depth], default: []].append(entry)
        }
    }
    let subfolders = grouped.keys
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        .map { key in
            buildFolderNode(name: key, id: id.isEmpty ? key : id + "/" + key, entries: grouped[key]!, depth: depth + 1)
        }
    files.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    return WikiFolderNode(id: id, name: name, subfolders: subfolders, files: files)
}

// MARK: - WikiBrowserView

/// Obsidian-style file browser over the wiki vault: folder tree sidebar +
/// markdown reader with wikilink navigation, history, and backlinks.
struct WikiBrowserView: View {
    @ObservedObject var viewModel: WikiGraphViewModel
    @EnvironmentObject var gatewayClientWrapper: GatewayClientWrapper
    #if !os(macOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    @State private var searchText = ""
    @State private var selectedPath: String?
    @State private var backStack: [String] = []
    @State private var forwardStack: [String] = []
    @State private var contentCache: [String: WikiPageContent] = [:]
    @State private var failedPath: String?
    @State private var backlinkIndex: [String: [WikiPage]] = [:]

    private var isCompact: Bool {
        #if os(macOS)
        return false
        #else
        return horizontalSizeClass == .compact
        #endif
    }

    var body: some View {
        Group {
            if isCompact {
                compactLayout
            } else {
                regularLayout
            }
        }
        .background(Theme.background)
        .onAppear { rebuildBacklinks() }
        .onChange(of: viewModel.graph.links.count) { _, _ in rebuildBacklinks() }
    }

    // MARK: - Layouts

    private var regularLayout: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 240)
            Divider()
            contentPane
        }
    }

    private var compactLayout: some View {
        ZStack {
            sidebar
            if selectedPath != nil {
                contentPane
                    .background(Theme.background)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: selectedPath != nil)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiary)
                TextField("Search pages…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.callout)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Theme.tertiary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 7))
            .padding(8)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                        let tree = buildFolderTree(viewModel.graph.pages)
                        FolderTreeContent(
                            node: tree,
                            selectedPath: selectedPath,
                            colorFor: { viewModel.color(for: $0) },
                            onSelect: { navigate(to: $0.path) }
                        )
                    } else {
                        let results = filteredPages
                        if results.isEmpty {
                            Text("No matches")
                                .font(.caption)
                                .foregroundStyle(Theme.tertiary)
                                .padding(8)
                        } else {
                            ForEach(results, id: \.id) { page in
                                WikiFileRow(
                                    page: page,
                                    isSelected: page.path == selectedPath,
                                    dotColor: viewModel.color(for: page.type)
                                ) { navigate(to: page.path) }
                            }
                        }
                    }
                }
                .padding(8)
            }
        }
        .frame(maxHeight: .infinity)
        .background(Theme.background)
    }

    private var filteredPages: [WikiPage] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return viewModel.graph.pages
            .filter { $0.title.lowercased().contains(q) || $0.path.lowercased().contains(q) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    // MARK: - Content Pane

    private var contentPane: some View {
        Group {
            if let path = selectedPath {
                pageView(path: path)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "hermeswiki" else { return .systemAction }
            let raw = String(url.absoluteString.dropFirst("hermeswiki://".count))
            if let decoded = raw.removingPercentEncoding, !decoded.isEmpty {
                navigate(to: decoded)
            }
            return .handled
        })
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text")
                .font(.system(size: 34))
                .foregroundStyle(Theme.tertiary)
            Text("Select a page")
                .font(.callout)
                .foregroundStyle(Theme.tertiary)
        }
    }

    @ViewBuilder
    private func pageView(path: String) -> some View {
        let page = viewModel.graph.pages.first { $0.path == path }
        VStack(alignment: .leading, spacing: 0) {
            pageHeader(path: path, page: page)
            Divider()
            if let content = contentCache[path] {
                loadedContent(content: content, page: page)
            } else if failedPath == path {
                Spacer()
                HStack {
                    Spacer()
                    Text("Failed to load page")
                        .font(.callout)
                        .foregroundStyle(Theme.warning)
                    Spacer()
                }
                Spacer()
            } else {
                Spacer()
                HStack {
                    Spacer()
                    HermesProgressView(label: "Loading…")
                    Spacer()
                }
                Spacer()
            }
        }
    }

    private func pageHeader(path: String, page: WikiPage?) -> some View {
        HStack(spacing: 10) {
            if isCompact {
                Button {
                    closePage()
                } label: {
                    Label("Files", systemImage: "chevron.backward")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
            }

            Button {
                goBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .disabled(backStack.isEmpty)

            Button {
                goForward()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .disabled(forwardStack.isEmpty)

            VStack(alignment: .leading, spacing: 2) {
                Text(page?.title ?? displayName(for: path))
                    .font(.headline)
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                Text(path)
                    .font(.caption)
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func loadedContent(content: WikiPageContent, page: WikiPage?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                frontmatterChips(content.frontmatter)
                MarkdownContentView(text: processWikilinks(stripFrontmatter(content.body)))
                backlinksSection(page: page)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func frontmatterChips(_ frontmatter: [String: String]) -> some View {
        let entries = frontmatter
            .filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.key < $1.key }
        if !entries.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(entries, id: \.key) { entry in
                    HStack(spacing: 3) {
                        Text("\(entry.key):")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.tertiary)
                        Text(entry.value)
                            .font(.caption2)
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.surface, in: Capsule())
                }
            }
        }
    }

    @ViewBuilder
    private func backlinksSection(page: WikiPage?) -> some View {
        let sources = page.flatMap { backlinkIndex[$0.id] } ?? []
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("Linked from (\(sources.count))")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.secondary)
            if sources.isEmpty {
                Text("No backlinks")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiary)
            } else {
                ForEach(sources, id: \.id) { src in
                    Button {
                        navigate(to: src.path)
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(viewModel.color(for: src.type))
                                .frame(width: 7, height: 7)
                            Text(src.title)
                                .font(.callout)
                                .foregroundStyle(Theme.accent)
                            Text(src.path)
                                .font(.caption2)
                                .foregroundStyle(Theme.tertiary)
                                .lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Navigation & Loading

    private func navigate(to path: String) {
        if path == selectedPath {
            if failedPath == path { select(path) }
            return
        }
        if let current = selectedPath { backStack.append(current) }
        forwardStack.removeAll()
        select(path)
    }

    private func goBack() {
        guard let previous = backStack.popLast() else { return }
        if let current = selectedPath { forwardStack.append(current) }
        select(previous)
    }

    private func goForward() {
        guard let next = forwardStack.popLast() else { return }
        if let current = selectedPath { backStack.append(current) }
        select(next)
    }

    private func closePage() {
        selectedPath = nil
        backStack.removeAll()
        forwardStack.removeAll()
    }

    private func select(_ path: String) {
        selectedPath = path
        if failedPath == path { failedPath = nil }
        guard contentCache[path] == nil else { return }
        Task { await loadContent(path) }
    }

    private func loadContent(_ path: String) async {
        let content = await viewModel.loadPage(
            client: gatewayClientWrapper.client,
            path: path,
            wiki: viewModel.selectedWikiPath
        )
        if let content {
            contentCache[path] = content
        } else if selectedPath == path {
            failedPath = path
        }
    }

    private func rebuildBacklinks() {
        let byId = Dictionary(viewModel.graph.pages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var index: [String: [WikiPage]] = [:]
        var seen: [String: Set<String>] = [:]
        for link in viewModel.graph.links {
            guard let source = byId[link.source] else { continue }
            if seen[link.target, default: []].insert(source.id).inserted {
                index[link.target, default: []].append(source)
            }
        }
        for key in index.keys {
            index[key]?.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
        backlinkIndex = index
    }

    // MARK: - Wikilink Processing

    /// Rewrites `[[Target]]` / `[[Target|Alias]]` into markdown links with a
    /// `hermeswiki://` scheme so MarkdownContentView renders them clickable.
    private func processWikilinks(_ body: String) -> String {
        let pattern = #"\[\[([^\]\|]+)(?:\|([^\]]+))?\]\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return body }
        let ns = body as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let target = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let aliasRange = match.range(at: 2)
            let alias = aliasRange.location != NSNotFound
                ? ns.substring(with: aliasRange).trimmingCharacters(in: .whitespaces)
                : nil
            let display = (alias?.isEmpty == false ? alias! : target)
            if let page = resolvePage(target),
               let encoded = page.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
                result += "[\(display)](hermeswiki://\(encoded))"
            } else {
                result += display
            }
            last = match.range.location + match.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    /// Resolution order: exact page id, then case-insensitive title,
    /// then slugified title.
    private func resolvePage(_ target: String) -> WikiPage? {
        let pages = viewModel.graph.pages
        if let p = pages.first(where: { $0.id == target }) { return p }
        let lower = target.lowercased()
        if let p = pages.first(where: { $0.title.lowercased() == lower }) { return p }
        let slug = slugify(target)
        if let p = pages.first(where: { slugify($0.title) == slug }) { return p }
        return nil
    }

    private func slugify(_ s: String) -> String {
        s.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
    }

    private func displayName(for path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    private func stripFrontmatter(_ text: String) -> String {
        guard text.hasPrefix("---") else { return text }
        let parts = text.components(separatedBy: "---")
        guard parts.count >= 3 else { return text }
        return parts[2...].joined(separator: "---")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Tree Rows

private struct FolderTreeContent: View {
    let node: WikiFolderNode
    let selectedPath: String?
    let colorFor: (String) -> Color
    let onSelect: (WikiPage) -> Void

    var body: some View {
        ForEach(node.subfolders) { sub in
            FolderDisclosureRow(node: sub, selectedPath: selectedPath, colorFor: colorFor, onSelect: onSelect)
        }
        ForEach(node.files, id: \.id) { page in
            WikiFileRow(
                page: page,
                isSelected: page.path == selectedPath,
                dotColor: colorFor(page.type)
            ) { onSelect(page) }
        }
    }
}

private struct FolderDisclosureRow: View {
    let node: WikiFolderNode
    let selectedPath: String?
    let colorFor: (String) -> Color
    let onSelect: (WikiPage) -> Void
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            FolderTreeContent(node: node, selectedPath: selectedPath, colorFor: colorFor, onSelect: onSelect)
                .padding(.leading, 10)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: expanded ? "folder" : "folder.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
                Text(node.name)
                    .font(.callout)
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(node.pageCount)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.tertiary)
            }
            .contentShape(Rectangle())
        }
    }
}

private struct WikiFileRow: View {
    let page: WikiPage
    let isSelected: Bool
    let dotColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                Text(page.title)
                    .font(.callout)
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
            .background(isSelected ? Theme.surfaceHover : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}
