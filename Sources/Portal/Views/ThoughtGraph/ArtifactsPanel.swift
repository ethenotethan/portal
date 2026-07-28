import SwiftUI

/// The session's living artifacts as a canvas panel: a compact list of the
/// artifacts the agent maintains (maps, datasets, docs, HTML pages), tap one to
/// render it inline. Backed by `ArtifactStore.shared`, so it is **session-
/// global** — it shows the same artifacts no matter where the transcript is
/// scrolled or which turn the canvas has selected. This is what makes artifacts
/// "persist through scrolling": they live on the canvas, not inline in the
/// transcript that scrolls away.
///
/// Timer-free: it re-renders only when the store publishes (an artifact is
/// created or updated), never on a clock, so it costs nothing alongside the
/// singleton flamechart.
internal struct ArtifactsPanel: View {
    @ObservedObject private var store = ArtifactStore.shared
    /// The artifact currently expanded inline. Nil = list view. Kept by id (not
    /// the value) so a live update to the open artifact flows through.
    @State private var openID: String?

    internal var body: some View {
        if store.sortedArtifacts.isEmpty {
            PanelEmptyState(
                icon: "shippingbox",
                message: "No artifacts yet — the agent's maps, datasets, and docs will collect here"
            )
        } else if let openID, let artifact = store.artifacts[openID] {
            detail(artifact)
        } else {
            list
        }
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(store.sortedArtifacts) { artifact in
                    Button {
                        openID = artifact.id
                    } label: {
                        row(artifact)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
        }
    }

    private func row(_ artifact: LivingArtifact) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon(for: artifact.kind))
                .font(.system(size: 12))
                .foregroundStyle(Theme.accent)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(artifact.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                Text(artifact.kind)
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.tertiary)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.system(size: 9))
                .foregroundStyle(Theme.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(Theme.surface.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Detail

    private func detail(_ artifact: LivingArtifact) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    openID = nil
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
                .help("Back to the artifact list")

                Image(systemName: icon(for: artifact.kind))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.accent)
                Text(artifact.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Theme.surface.opacity(0.5))

            Divider().overlay(Theme.border)

            ScrollView {
                // Live render — pass the artifact id so declared per-entry
                // actions (dataset/map/html) stay actionable in the panel.
                ArtifactKindRenderer(
                    kind: artifact.kind,
                    content: artifact.content,
                    actionableArtifactID: artifact.id,
                    topLevelActions: artifact.topLevelActions
                )
                .padding(8)
            }
        }
    }

    private func icon(for kind: String) -> String {
        switch kind {
        case "map": return "map"
        case "chart": return "chart.xyaxis.line"
        case "graph": return "point.3.connected.trianglepath.dotted"
        case "stats": return "square.grid.2x2"
        case "dataset": return "tablecells"
        case "timeline": return "calendar.day.timeline.left"
        case "sankey": return "arrow.triangle.branch"
        case "model": return "cube.transparent"
        case "html": return "globe"
        default: return "doc.text"
        }
    }
}
