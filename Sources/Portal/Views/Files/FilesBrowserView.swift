import SwiftUI

/// Read-only browser for Hermes files: a lazily-walked folder tree over the
/// gateway's `repo` and `hermes` roots on the left, a source/markdown reader
/// on the right. Docked as a macOS overlay and an iOS tab; the layout adapts
/// — a fixed split on regular width, a push-over reader on iPhone compact.
///
/// The tree fills in on demand: each directory's children are fetched the
/// first time it expands (see `FilesBrowserViewModel`), so any path is
/// reachable regardless of how large the checkout is.
internal struct FilesBrowserView: View {
    @EnvironmentObject internal var gatewayClientWrapper: GatewayClientWrapper
    @StateObject private var viewModel = FilesBrowserViewModel()
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    internal var body: some View {
        content
            .background(Theme.background)
            .task {
                viewModel.setClient(gatewayClientWrapper.client)
                if !viewModel.rootsLoaded { await viewModel.loadRoots() }
            }
    }

    private var isCompact: Bool {
        #if os(iOS)
        return horizontalSizeClass == .compact
        #else
        return false
        #endif
    }

    @ViewBuilder private var content: some View {
        if isCompact {
            ZStack {
                sidebar
                if viewModel.selectedFile != nil || viewModel.isLoadingFile {
                    reader
                        .background(Theme.background)
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: viewModel.selectedID)
        } else {
            HStack(spacing: 0) {
                sidebar.frame(width: 300)
                Divider()
                reader
            }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            if let message = viewModel.errorMessage {
                errorBanner(message)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if !viewModel.rootsLoaded {
                        ProgressView()
                            .controlSize(.small)
                            .padding()
                    } else if viewModel.roots.isEmpty {
                        Text("No browsable roots")
                            .font(.caption)
                            .foregroundStyle(Theme.tertiary)
                            .padding()
                    } else {
                        ForEach(viewModel.roots, id: \.self) { root in
                            FileRootRow(root: root, viewModel: viewModel)
                        }
                    }
                }
                .padding(8)
            }
        }
        .frame(maxHeight: .infinity)
        .background(Theme.background)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(Theme.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Theme.surface)
    }

    // MARK: Reader

    @ViewBuilder private var reader: some View {
        if viewModel.isLoadingFile {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading…")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let file = viewModel.selectedFile {
            VStack(spacing: 0) {
                readerHeader(file)
                Divider()
                ScrollView {
                    Group {
                        if file.content.isEmpty {
                            Text("Empty file")
                                .font(.caption)
                                .foregroundStyle(Theme.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else if file.isMarkdown {
                            MarkdownContentView(text: file.content)
                        } else {
                            CodeBlockView(language: file.language, code: file.content)
                        }
                    }
                    .padding(16)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.system(size: 32))
                    .foregroundStyle(Theme.tertiary)
                Text("Select a file to view it")
                    .font(.callout)
                    .foregroundStyle(Theme.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func readerHeader(_ file: FileContent) -> some View {
        HStack(spacing: 8) {
            if isCompact {
                Button {
                    viewModel.clearSelection()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Back to files")
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(file.fileName)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                Text("\(file.root) · \(file.path)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if file.readOnly {
                Label("read-only", systemImage: "lock.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiary)
            }
            Text(byteCount(file.size))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Theme.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.background)
    }

    private func byteCount(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

// MARK: - Tree rows

/// A top-level root (`repo` / `hermes`) rendered as a disclosure over its
/// contents. Roots start expanded so the first thing the user sees is content.
private struct FileRootRow: View {
    let root: String
    @ObservedObject var viewModel: FilesBrowserViewModel

    var body: some View {
        let expanded = viewModel.isExpanded(root: root, path: "")
        VStack(alignment: .leading, spacing: 1) {
            Button {
                Task { await viewModel.toggleDirectory(root: root, path: "") }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.tertiary)
                        .frame(width: 10)
                    Image(systemName: "externaldrive.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                    Text(root)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Theme.primary)
                    Spacer(minLength: 0)
                    if viewModel.isLoading(root: root, path: "") {
                        ProgressView().controlSize(.mini)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                FileChildren(root: root, path: "", depth: 1, viewModel: viewModel)
                    .padding(.leading, 10)
            }
        }
    }
}

/// The listed children of one directory level, recursing into expanded
/// subdirectories.
private struct FileChildren: View {
    let root: String
    let path: String
    let depth: Int
    @ObservedObject var viewModel: FilesBrowserViewModel

    var body: some View {
        if let entries = viewModel.children(root: root, path: path) {
            if entries.isEmpty {
                Text("empty")
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiary)
                    .padding(.leading, 16)
                    .padding(.vertical, 2)
            } else {
                ForEach(entries) { entry in
                    if entry.isDirectory {
                        FileDirRow(entry: entry, depth: depth, viewModel: viewModel)
                    } else {
                        FileLeafRow(entry: entry, viewModel: viewModel)
                    }
                }
            }
        } else if viewModel.isLoading(root: root, path: path) {
            ProgressView()
                .controlSize(.mini)
                .padding(.leading, 16)
                .padding(.vertical, 2)
        }
    }
}

private struct FileDirRow: View {
    let entry: FileEntry
    let depth: Int
    @ObservedObject var viewModel: FilesBrowserViewModel

    var body: some View {
        let expanded = viewModel.isExpanded(root: entry.root, path: entry.path)
        VStack(alignment: .leading, spacing: 1) {
            Button {
                Task { await viewModel.toggleDirectory(root: entry.root, path: entry.path) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(entry.hasChildren ? Theme.tertiary : Color.clear)
                        .frame(width: 10)
                    Image(systemName: expanded ? "folder" : "folder.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                    Text(entry.name)
                        .font(.callout)
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if viewModel.isLoading(root: entry.root, path: entry.path) {
                        ProgressView().controlSize(.mini)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                FileChildren(root: entry.root, path: entry.path, depth: depth + 1, viewModel: viewModel)
                    .padding(.leading, 10)
            }
        }
    }
}

private struct FileLeafRow: View {
    let entry: FileEntry
    @ObservedObject var viewModel: FilesBrowserViewModel

    var body: some View {
        let isSelected = viewModel.selectedID == entry.id
        Button {
            Task { await viewModel.select(entry) }
        } label: {
            HStack(spacing: 6) {
                Spacer().frame(width: 10)
                Image(systemName: FileLeafRow.icon(for: entry.name))
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                Text(entry.name)
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

    /// A file-type glyph from the extension — purely cosmetic.
    static func icon(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "py", "js", "ts", "swift", "go", "rs", "c", "cpp", "h", "java", "rb", "sh":
            return "chevron.left.forwardslash.chevron.right"
        case "md", "markdown", "txt", "rst":
            return "doc.text"
        case "json", "yaml", "yml", "toml", "cfg", "ini", "env":
            return "curlybraces"
        case "png", "jpg", "jpeg", "gif", "svg", "webp":
            return "photo"
        default:
            return "doc"
        }
    }
}
