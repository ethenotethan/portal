import SwiftUI

/// Rich preview card for standalone GitHub links in generated markdown.
struct GitHubLinkCard: View {
    let link: GitHubLink
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            openURL(link.url)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                GitHubMarkView()
                    .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(link.owner)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.secondary)
                        Text("/")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.tertiary)
                        Text(link.repo)
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(Theme.primary)
                    }
                    .lineLimit(1)

                    HStack(spacing: 6) {
                        Text(link.kind.label)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(link.kind.tint)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(link.kind.tint.opacity(0.12), in: Capsule())

                        Text(link.detail)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.tertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Theme.border, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open GitHub \(link.kind.label) \(link.owner)/\(link.repo) \(link.detail)")
        .contextMenu {
            Button("Copy URL") { copy(link.url.absoluteString) }
            Button("Open in Browser") { openURL(link.url) }
        }
    }

    static func extractStandalone(from paragraph: String) -> GitHubLink? {
        let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: String

        if let markdown = parseSingleMarkdownLink(trimmed) {
            candidate = markdown.url
        } else {
            candidate = trimmed
        }

        guard !candidate.contains(" "),
              let url = URL(string: candidate),
              let host = url.host?.lowercased(),
              host == "github.com" || host == "www.github.com" else {
            return nil
        }
        return GitHubLink(url: url)
    }

    private static func parseSingleMarkdownLink(_ text: String) -> (title: String, url: String)? {
        guard text.hasPrefix("[") else { return nil }
        guard let closeTitle = text.firstIndex(of: "]") else { return nil }
        let afterTitle = text.index(after: closeTitle)
        guard afterTitle < text.endIndex, text[afterTitle] == "(" else { return nil }
        guard text.hasSuffix(")") else { return nil }

        let title = String(text[text.index(after: text.startIndex)..<closeTitle])
        let urlStart = text.index(after: afterTitle)
        let urlEnd = text.index(before: text.endIndex)
        let url = String(text[urlStart..<urlEnd])
        guard !title.isEmpty, !url.isEmpty else { return nil }
        return (title, url)
    }

    private func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

struct GitHubLink: Equatable {
    let url: URL
    let owner: String
    let repo: String
    let kind: GitHubLinkKind
    let detail: String

    init?(url: URL) {
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        self.url = url
        self.owner = parts[0]
        self.repo = parts[1]

        if parts.count >= 4, parts[2] == "pull" {
            self.kind = .pullRequest
            self.detail = "#\(parts[3])"
        } else if parts.count >= 4, parts[2] == "issues" {
            self.kind = .issue
            self.detail = "#\(parts[3])"
        } else if parts.count >= 4, parts[2] == "commit" {
            self.kind = .commit
            self.detail = String(parts[3].prefix(8))
        } else if parts.count >= 4, parts[2] == "tree" {
            self.kind = .branch
            self.detail = parts[3]
        } else if parts.count >= 4, parts[2] == "blob" {
            self.kind = .file
            self.detail = parts.dropFirst(3).joined(separator: "/")
        } else if parts.count >= 4, parts[2] == "releases", parts[3] == "tag", parts.count >= 5 {
            self.kind = .release
            self.detail = parts[4]
        } else {
            self.kind = .repository
            self.detail = "Repository"
        }
    }
}

enum GitHubLinkKind: Equatable {
    case repository
    case pullRequest
    case issue
    case commit
    case branch
    case file
    case release

    var label: String {
        switch self {
        case .repository: "REPO"
        case .pullRequest: "PR"
        case .issue: "ISSUE"
        case .commit: "COMMIT"
        case .branch: "BRANCH"
        case .file: "FILE"
        case .release: "RELEASE"
        }
    }

    var tint: Color {
        switch self {
        case .repository: Theme.accent
        case .pullRequest: Color.purple
        case .issue: Theme.success
        case .commit: Theme.warning
        case .branch: Color.cyan
        case .file: Theme.secondary
        case .release: Color.orange
        }
    }
}

private struct GitHubMarkView: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.primary)
            Text("GH")
                .font(.system(size: 10, weight: .black, design: .rounded))
                .foregroundStyle(Theme.background)
                .tracking(-1)
        }
        .overlay(Circle().stroke(Theme.border, lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}
