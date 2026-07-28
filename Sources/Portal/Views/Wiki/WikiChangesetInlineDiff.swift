import SwiftUI

/// Git-style unified diff for a single wiki changeset, rendered INLINE
/// beneath its timeline row (GitHub commit-list style) — the diff expands
/// in place under the entry rather than opening a nested sheet.
/// Purely presentational: WikiTimelineViewModel owns the fetch
/// (wiki.changeset_diff) and hands the state in. +green / −red / @@hunk
/// coloring like a terminal `git show`.
struct WikiChangesetInlineDiff: View {
    let changeset: WikiChangeset
    let state: WikiTimelineViewModel.DiffState
    var onRetry: (() -> Void)?

    /// Inline expansion stays bounded; long diffs scroll within the row.
    private let maxDiffHeight: CGFloat = 320

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Theme.border, lineWidth: 1)
            )
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if state.isLoading {
            HStack {
                Spacer()
                HermesProgressView(label: "Loading diff…")
                Spacer()
            }
            .padding(.vertical, 20)
        } else if let message = state.errorMessage {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.questionmark")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.tertiary)
                    Text("Diff unavailable")
                        .font(.callout)
                        .foregroundStyle(Theme.primary)
                }
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Theme.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                if !changeset.summary.isEmpty {
                    Text("“\(changeset.summary)”")
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                }
                if let onRetry {
                    Button("Retry", action: onRetry)
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        } else if let diff = state.diff, !diff.isEmpty {
            diffBody(diff)
        } else {
            Text("No textual changes recorded")
                .font(.callout)
                .foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
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
        .frame(maxHeight: maxDiffHeight)
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
}
