import SwiftUI

/// Git-style unified diff view for a single wiki changeset.
/// Fetched via `wiki.changeset_diff`; rendered line-by-line with
/// +green / −red / @@hunk coloring like a terminal `git show`.
struct WikiChangesetDiffView: View {
    let changeset: WikiChangeset
    let wiki: String?
    var onOpenPage: ((String) -> Void)?

    @EnvironmentObject var gatewayClientWrapper: GatewayClientWrapper
    @Environment(\.dismiss) private var dismiss

    @State private var diff: String?
    @State private var loadError: String?
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(Theme.background)
        .task { await loadDiff() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: changeset.action.icon)
                .font(.system(size: 14))
                .foregroundStyle(Theme.accent)

            VStack(alignment: .leading, spacing: 1) {
                Text(changeset.title.isEmpty ? changeset.page : changeset.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(changeset.page)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !changeset.gitCommit.isEmpty {
                        Text(changeset.gitCommit)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.secondary)
                    }
                    Text("+\(changeset.linesAdded)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.success)
                    Text("−\(changeset.linesRemoved)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.warning)
                }
            }

            Spacer()

            if onOpenPage != nil {
                Button("Open Page") {
                    dismiss()
                    onOpenPage?(changeset.page)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.tertiary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.surface)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isLoading {
            Spacer()
            HermesProgressView(label: "Loading diff…")
            Spacer()
        } else if let loadError {
            VStack(spacing: 10) {
                Image(systemName: "doc.questionmark")
                    .font(.system(size: 30))
                    .foregroundStyle(Theme.tertiary)
                Text("Diff unavailable")
                    .font(.callout)
                    .foregroundStyle(Theme.primary)
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(Theme.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                if !changeset.summary.isEmpty {
                    Text("“\(changeset.summary)”")
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let diff, !diff.isEmpty {
            diffBody(diff)
        } else {
            Text("No textual changes recorded")
                .font(.callout)
                .foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func diffBody(_ diff: String) -> some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(diff.split(separator: "\n", omittingEmptySubsequences: false).enumerated()),
                        id: \.offset) { _, line in
                    diffLine(String(line))
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.background)
    }

    @ViewBuilder
    private func diffLine(_ line: String) -> some View {
        let (color, background): (Color, Color) = {
            if line.hasPrefix("+++") || line.hasPrefix("---") {
                return (Theme.secondary, .clear)
            } else if line.hasPrefix("@@") {
                return (Theme.accent, Theme.accent.opacity(0.08))
            } else if line.hasPrefix("+") {
                return (Theme.success, Theme.success.opacity(0.10))
            } else if line.hasPrefix("-") {
                return (Theme.warning, Theme.warning.opacity(0.10))
            } else if line.hasPrefix("diff --git") || line.hasPrefix("index ")
                        || line.hasPrefix("new file") || line.hasPrefix("deleted file") {
                return (Theme.tertiary, .clear)
            }
            return (Theme.primary, .clear)
        }()

        Text(line.isEmpty ? " " : line)
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 0.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .textSelection(.enabled)
    }

    // MARK: - Load

    private func loadDiff() async {
        isLoading = true
        defer { isLoading = false }
        do {
            diff = try await gatewayClientWrapper.client.wikiChangesetDiff(
                id: changeset.id, wiki: wiki
            )
        } catch let GatewayError.rpcError(rpcError) {
            // 5057 = wiki not git-initialized at capture time; anything else
            // (older gateway without the RPC, transient) reads the same way.
            loadError = rpcError.message
        } catch {
            loadError = error.localizedDescription
        }
    }
}
