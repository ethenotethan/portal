import SwiftUI

// MARK: - CronSourceFilesSection

/// The "Source files" block of a cron node's inspector: the code behind the
/// job, grouped by the browse root it opens under. Each file is a row that
/// opens in the reader pane, and each row carries a folder disclosure that
/// lists the file's neighbours — so the block behaves like a small file
/// explorer scoped to the job rather than a set of links.
///
/// The files come from the graph node (`CronGraphNode.sourceFiles`): the job's
/// `script` / `monitor_script` plus whatever the creating agent declared under
/// `source_files`. A file the gateway couldn't place under a browsable root is
/// still listed, dimmed, so what the job claims to run is never hidden — it
/// just can't be opened from here.
internal struct CronSourceFilesSection: View {
    internal let files: [CronSourceFile]
    @ObservedObject internal var viewModel: CronSourceFilesViewModel
    /// Open a file in the reader. Injected rather than calling the view model
    /// directly so the surface owning the pane decides what "open" means (a
    /// third column on a wide window, a sheet on a phone).
    internal let onOpen: (CronSourceFile) -> Void

    internal var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label("Source files", systemImage: "chevron.left.forwardslash.chevron.right")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.primary)
                Spacer()
                Text("\(files.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.tertiary)
            }

            ForEach(CronSourceFileGroup.grouping(files)) { group in
                groupHeader(group)
                ForEach(group.files) { file in
                    fileRow(file)
                    if let root = file.root, let dir = file.relativeDirectory,
                       viewModel.isExpanded(root: root, path: dir) {
                        siblings(of: file, root: root, dir: dir)
                    }
                }
            }

            if let message = viewModel.errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(Theme.warning)
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(3)
                }
            }
        }
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Rows

    private func groupHeader(_ group: CronSourceFileGroup) -> some View {
        HStack(spacing: 5) {
            Image(systemName: group.root == nil ? "questionmark.folder" : "externaldrive.fill")
                .font(.system(size: 9))
                .foregroundStyle(group.root == nil ? Theme.tertiary : Theme.accent)
            Text(group.root ?? "outside browsable roots")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.secondary)
        }
        .padding(.top, 2)
    }

    private func fileRow(_ file: CronSourceFile) -> some View {
        let isOpen = viewModel.openSource?.id == file.id
        return HStack(spacing: 6) {
            Button { onOpen(file) } label: {
                HStack(spacing: 6) {
                    Image(systemName: Self.icon(for: file.fileName))
                        .font(.caption)
                        .foregroundStyle(file.isOpenable ? Theme.secondary : Theme.tertiary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.fileName)
                            .font(.caption)
                            .foregroundStyle(file.isOpenable ? Theme.primary : Theme.tertiary)
                            .lineLimit(1)
                        Text(file.relativePath ?? file.declared)
                            .font(.system(size: 9).monospaced())
                            .foregroundStyle(Theme.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    roleBadge(file.role)
                    if !file.exists {
                        Text("missing")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Theme.warning)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Theme.warning.opacity(0.12), in: Capsule())
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
                .background(isOpen ? Theme.surfaceHover : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(!file.isOpenable)
            .help(file.isOpenable ? "Open \(file.fileName)" : "Outside the browsable roots — not readable from here")

            if let root = file.root, let dir = file.relativeDirectory {
                folderToggle(root: root, dir: dir)
            }
        }
    }

    /// The disclosure that lists what else sits in the file's folder.
    private func folderToggle(root: String, dir: String) -> some View {
        let expanded = viewModel.isExpanded(root: root, path: dir)
        return Button {
            Task { await viewModel.toggleFolder(root: root, path: dir) }
        } label: {
            Group {
                if viewModel.isLoading(root: root, path: dir) {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: expanded ? "folder" : "folder.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(expanded ? Theme.accent : Theme.tertiary)
                }
            }
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(expanded ? "Hide the folder" : "Show the other files in \(dir.isEmpty ? "the root" : dir)")
    }

    /// The other files in a disclosed folder, each openable. Subfolders are
    /// left out: the explorer is scoped to the job's code, not the whole tree —
    /// the Files tab is one click away for that.
    @ViewBuilder
    private func siblings(of file: CronSourceFile, root: String, dir: String) -> some View {
        if let entries = viewModel.children(root: root, path: dir) {
            let others = entries.filter { !$0.isDirectory && $0.path != file.relativePath }
            if others.isEmpty {
                Text("nothing else in this folder")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiary)
                    .padding(.leading, 26)
            } else {
                ForEach(others) { entry in
                    siblingRow(entry)
                }
            }
        }
    }

    private func siblingRow(_ entry: FileEntry) -> some View {
        let isOpen = viewModel.openSource?.relativePath == entry.path && viewModel.openSource?.root == entry.root
        return Button {
            Task { await viewModel.open(entry: entry) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: Self.icon(for: entry.name))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiary)
                Text(entry.name)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .padding(.leading, 26)
            .padding(.trailing, 6)
            .contentShape(Rectangle())
            .background(isOpen ? Theme.surfaceHover : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private func roleBadge(_ role: String) -> some View {
        Text(Self.roleTitle(role))
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(Self.roleColor(role))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Self.roleColor(role).opacity(0.14), in: Capsule())
    }

    /// How a job came to have a file, in words a card can spend one badge on.
    internal static func roleTitle(_ role: String) -> String {
        switch role {
        case "script": return "script"
        case "monitor": return "monitor"
        case "browsed": return "nearby"
        default: return "declared"
        }
    }

    private static func roleColor(_ role: String) -> Color {
        switch role {
        case "script": return Color(hex: "7c9cff") ?? .blue
        case "monitor": return Color(hex: "e8a838") ?? .orange
        case "browsed": return Theme.tertiary
        default: return Theme.secondary
        }
    }

    /// A file-type glyph from the extension — purely cosmetic.
    internal static func icon(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "py", "js", "ts", "swift", "go", "rs", "c", "cpp", "h", "java", "rb", "sh", "bash", "zsh":
            return "chevron.left.forwardslash.chevron.right"
        case "md", "markdown", "txt", "rst":
            return "doc.text"
        case "json", "yaml", "yml", "toml", "cfg", "ini", "env":
            return "curlybraces"
        default:
            return "doc"
        }
    }
}

// MARK: - CronSourceFileReaderPane

/// The reader that a source-file row opens into: the file's name, where it
/// lives and how the job came to have it up top, then the contents — prose for
/// markdown, highlighted code for everything else. Read-only, like the Files
/// tab it borrows its plumbing from.
internal struct CronSourceFileReaderPane: View {
    @ObservedObject internal var viewModel: CronSourceFilesViewModel
    internal let onClose: () -> Void

    internal var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.border)
            content
        }
        .background(Theme.background)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: CronSourceFilesSection.icon(for: viewModel.openSource?.fileName ?? ""))
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(viewModel.openSource?.fileName ?? "")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                Text(location)
                    .font(.caption2.monospaced())
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if let source = viewModel.openSource {
                Text(CronSourceFilesSection.roleTitle(source.role))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Theme.surface, in: Capsule())
            }
            if let file = viewModel.openFile {
                Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.tertiary)
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close the file")
            .accessibilityIdentifier("cron.sourceFile.close")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.background)
    }

    private var location: String {
        guard let source = viewModel.openSource else { return "" }
        if let root = source.root, let rel = source.relativePath {
            return "\(root) · \(rel)"
        }
        return source.path
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoadingFile {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading…")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let file = viewModel.openFile {
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 24))
                    .foregroundStyle(Theme.warning)
                Text(viewModel.errorMessage ?? "The file couldn't be read.")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
