import SwiftUI

/// The one markdown reader for the wiki: rendered content with clickable
/// wikilinks, frontmatter chips, backlinks, and back/forward history — all
/// driven by the shared selection plane on WikiGraphViewModel. Hosted by the
/// file browser (inline), the graph modes (side panel / sheet), and the
/// timeline.
struct WikiReaderPane: View {
    @ObservedObject var viewModel: WikiGraphViewModel
    @EnvironmentObject var gatewayClientWrapper: GatewayClientWrapper

    /// Compact files-mode: shows a "Files" back button that closes the page.
    var showsCompactBack = false
    /// Sheet/panel hosting: shows a close affordance.
    var onClose: (() -> Void)?
    /// Hidden when the reader already sits next to the 2D graph.
    var showsShowInGraph = true

    var body: some View {
        Group {
            if let path = viewModel.selectedPath {
                pageView(path: path)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "hermeswiki" else { return .systemAction }
            let raw = String(url.absoluteString.dropFirst("hermeswiki://".count))
            if let decoded = raw.removingPercentEncoding, !decoded.isEmpty {
                viewModel.navigate(to: decoded)
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
            if let content = viewModel.cachedContent(for: path) {
                loadedContent(content: content, page: page)
            } else if viewModel.failedPath == path {
                Spacer()
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Text("Failed to load page")
                            .font(.callout)
                            .foregroundStyle(Theme.warning)
                        Button("Retry") {
                            viewModel.failedPath = nil
                            Task {
                                await viewModel.ensureContentLoaded(
                                    client: gatewayClientWrapper.client, path: path)
                            }
                        }
                        .buttonStyle(.borderless)
                    }
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
        .task(id: path) {
            await viewModel.ensureContentLoaded(client: gatewayClientWrapper.client, path: path)
        }
    }

    private func pageHeader(path: String, page: WikiPage?) -> some View {
        HStack(spacing: 10) {
            if showsCompactBack {
                Button {
                    viewModel.closePage()
                } label: {
                    Label("Files", systemImage: "chevron.backward")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
            }

            Button {
                viewModel.goBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .disabled(!viewModel.canGoBack)

            Button {
                viewModel.goForward()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .disabled(!viewModel.canGoForward)

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

            if showsShowInGraph, page != nil {
                Button {
                    viewModel.showCurrentPageInGraph()
                } label: {
                    Label("Show in Graph", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Select and center this page's node in the 2D graph")
            }

            if let onClose {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.borderless)
            }
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
        let sources = viewModel.backlinks(for: page)
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
                        viewModel.navigate(to: src.path)
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
