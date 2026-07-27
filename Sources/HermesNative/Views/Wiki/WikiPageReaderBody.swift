import SwiftUI

/// The body of a wiki page reader: frontmatter chips, rendered markdown with
/// clickable wikilinks, and backlinks — everything BELOW a host's header.
///
/// Extracted from `WikiReaderPane` so the iOS sheet, the macOS docked reader,
/// and each Compare tile share ONE content path. That matters for more than
/// dedup: the markdown render (block parse + per-block highlight + the wikilink
/// regex) is the expensive, beachball-prone work, and it lives here once,
/// memoized by the shared caches (MarkdownParseCache / CodeHighlighter),
/// instead of being copy-pasted into every host.
///
/// This view is navigation-agnostic: it renders whatever `path` it's given and
/// reports link taps through `onNavigate`, so each host decides what "navigate"
/// means — the body doesn't know or care which.
internal struct WikiPageReaderBody: View {
    @ObservedObject internal var viewModel: WikiGraphViewModel
    @EnvironmentObject internal var gatewayClientWrapper: GatewayClientWrapper

    /// The page this body renders. Its own property (not the shared
    /// `selectedPath`) so multiple cards can each show a different page.
    internal let path: String
    /// Invoked when the reader follows a wikilink or a backlink. The host
    /// decides what "navigate" means (shared plane vs. per-card history).
    internal let onNavigate: (String) -> Void

    internal init(
        viewModel: WikiGraphViewModel,
        path: String,
        onNavigate: @escaping (String) -> Void
    ) {
        self.viewModel = viewModel
        self.path = path
        self.onNavigate = onNavigate
    }

    internal var body: some View {
        let page = viewModel.graph.pages.first { $0.path == path }
        Group {
            if let content = viewModel.cachedContent(for: path) {
                loadedContent(content: content, page: page)
            } else if viewModel.failedPath == path {
                failedState
            } else {
                loadingState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "hermeswiki" else { return .systemAction }
            let raw = String(url.absoluteString.dropFirst("hermeswiki://".count))
            if let decoded = raw.removingPercentEncoding, !decoded.isEmpty {
                onNavigate(decoded)
            }
            return .handled
        })
        .task(id: path) {
            await viewModel.ensureContentLoaded(client: gatewayClientWrapper.client, path: path)
        }
    }

    private var loadingState: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                HermesProgressView(label: "Loading…")
                Spacer()
            }
            Spacer()
        }
    }

    private var failedState: some View {
        VStack {
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
        }
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
                        onNavigate(src.path)
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

    // MARK: - Wikilink processing

    /// Rewrites `[[Target]]` / `[[Target|Alias]]` into markdown links with a
    /// `hermeswiki://` scheme so MarkdownContentView renders them clickable.
    private func processWikilinks(_ body: String) -> String {
        let pattern = #"\[\[([^\]\|]+)(?:\|([^\]]+))?\]\]"#
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern)
        } catch {
            // A literal, compile-time-constant pattern can't fail here; if it
            // ever does, render the body unlinked rather than crash.
            return body
        }
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
            let display = (alias?.isEmpty == false ? alias ?? target : target)
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

    private func stripFrontmatter(_ text: String) -> String {
        guard text.hasPrefix("---") else { return text }
        let parts = text.components(separatedBy: "---")
        guard parts.count >= 3 else { return text }
        return parts[2...].joined(separator: "---")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
