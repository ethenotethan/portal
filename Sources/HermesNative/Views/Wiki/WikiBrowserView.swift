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
/// the shared WikiReaderPane. Selection, history, cache, and backlinks all
/// live on WikiGraphViewModel so they survive mode switches.
struct WikiBrowserView: View {
    @ObservedObject var viewModel: WikiGraphViewModel
    #if !os(macOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    @State private var searchText = ""

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
    }

    // MARK: - Layouts

    private var regularLayout: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 240)
            Divider()
            WikiReaderPane(viewModel: viewModel)
        }
    }

    private var compactLayout: some View {
        ZStack {
            sidebar
            if viewModel.selectedPath != nil {
                WikiReaderPane(viewModel: viewModel, showsCompactBack: true)
                    .background(Theme.background)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: viewModel.selectedPath != nil)
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
                            selectedPath: viewModel.selectedPath,
                            colorFor: { viewModel.color(for: $0) },
                            onSelect: { viewModel.navigate(to: $0.path) }
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
                                    isSelected: page.path == viewModel.selectedPath,
                                    dotColor: viewModel.color(for: page.type)
                                ) { viewModel.navigate(to: page.path) }
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
