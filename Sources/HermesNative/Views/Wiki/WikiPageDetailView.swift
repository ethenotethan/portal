import SwiftUI

/// Detail view for a single wiki page.
/// Shows frontmatter metadata + rendered markdown body.
struct WikiPageDetailView: View {
    let page: WikiPage
    @ObservedObject var viewModel: WikiGraphViewModel
    @State private var pageContent: WikiPageContent?
    @State private var isLoading = false
    @State private var loadError: String?
    @EnvironmentObject var gatewayClientWrapper: GatewayClientWrapper
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Back") {
                    dismiss()
                }
                .buttonStyle(.borderless)

                Spacer()

                Text(page.title)
                    .font(.headline)
                    .foregroundStyle(Theme.primary)

                Spacer()
            }
            .padding()

            Divider()

            if isLoading {
                Spacer()
                ProgressView("Loading…")
                Spacer()
            } else if let error = loadError {
                Spacer()
                Text("Error: \(error)")
                    .foregroundStyle(.red)
                Spacer()
            } else if let content = pageContent {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        frontmatterCard(content: content)
                            .padding(.horizontal)

                        Divider()
                            .padding(.horizontal)

                        MarkdownContentView(text: stripFrontmatter(content.body))
                            .padding(.horizontal)
                    }
                    .padding(.vertical)
                }
            } else {
                Spacer()
                Text("No content")
                    .foregroundStyle(Theme.secondary)
                Spacer()
            }
        }
        .background(Theme.background)
        .task {
            await loadContent()
        }
    }

    // MARK: - Frontmatter Card

    @ViewBuilder
    private func frontmatterCard(content: WikiPageContent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(viewModel.color(for: page.type))
                        .frame(width: 8, height: 8)
                    Text(page.type.capitalized)
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                }

                if let updated = page.updated, !updated.isEmpty {
                    Label(updated, systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                }
            }

            if !page.tags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(page.tags, id: \.self) { tag in
                        Text(tag)
                            .font(.caption2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Theme.surface, in: Capsule())
                            .foregroundStyle(Theme.secondary)
                    }
                }
            }

            if let confidence = page.confidence, !confidence.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.shield")
                        .font(.caption2)
                    Text("Confidence: \(confidence)")
                        .font(.caption2)
                }
                .foregroundStyle(Theme.secondary)
            }

            if page.contested {
                Label("Contested", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
            }

            if let source = content.frontmatter["source_url"],
               !source.isEmpty,
               let url = URL(string: source) {
                Link("Source", destination: url)
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(12)
        .background(Theme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Content Loading

    private func loadContent() async {
        isLoading = true
        loadError = nil
        let content = await viewModel.loadPage(client: gatewayClientWrapper.client, path: page.path)
        isLoading = false
        if let content = content {
            pageContent = content
        } else {
            loadError = "Failed to load page"
        }
    }

    private func stripFrontmatter(_ text: String) -> String {
        guard text.hasPrefix("---") else { return text }
        let parts = text.components(separatedBy: "---")
        guard parts.count >= 3 else { return text }
        return parts[2...].joined(separator: "---")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Flow Layout

/// Simple flow layout for tags.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.width ?? 0, subviews: subviews, spacing: spacing)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.positions[index].x,
                                      y: bounds.minY + result.positions[index].y),
                         proposal: .unspecified)
        }
    }

    struct FlowResult {
        var size: CGSize = .zero
        var positions: [CGPoint] = []

        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var x: CGFloat = 0
            var y: CGFloat = 0
            var rowHeight: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                if x + size.width > maxWidth && x > 0 {
                    x = 0
                    y += rowHeight + spacing
                    rowHeight = 0
                }
                positions.append(CGPoint(x: x, y: y))
                rowHeight = max(rowHeight, size.height)
                x += size.width + spacing
            }

            self.size = CGSize(width: maxWidth, height: y + rowHeight)
        }
    }
}
