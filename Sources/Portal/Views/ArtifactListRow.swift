import SwiftUI

/// One row of the artifact list sidebar. A value view: everything the body reads
/// arrives as `Inputs`, and `.equatable()` skips the body when they are
/// unchanged — so a live query result landing every few seconds re-renders the
/// rows it changes, not all of them. The maintainers flag comes from the
/// artifact's parsed-once cache; the row never parses content itself.
internal struct ArtifactListRow: View, Equatable {
    internal struct Inputs: Equatable {
        internal let id: String
        internal let displayName: String
        internal let icon: String
        internal let rev: Int
        internal let updatedAt: Date
        internal let writerLabel: String?
        internal let hasMaintainers: Bool
        internal let isSelected: Bool

        internal init(artifact: LivingArtifact, isSelected: Bool) {
            id = artifact.id
            displayName = artifact.displayName
            icon = ArtifactKindGlyph.icon(for: artifact.kind)
            rev = artifact.rev
            updatedAt = artifact.updatedAt
            writerLabel = WriterRef.parse(artifact.updatedBy)?.label(cronName: { (_: String) -> String? in nil })
            hasMaintainers = !artifact.maintainerRefs.isEmpty
            self.isSelected = isSelected
        }
    }

    internal let inputs: Inputs
    internal let onSelect: () -> Void
    /// A plain reference, never observed: the row calls `remove` on it so the
    /// architecture extractor still sees the artifacts page dispatch the store
    /// (a closure hides that), while the row's identity stays its `inputs`.
    internal let store: ArtifactStore

    nonisolated internal static func == (lhs: ArtifactListRow, rhs: ArtifactListRow) -> Bool {
        lhs.inputs == rhs.inputs
    }

    internal var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Image(systemName: inputs.icon)
                    .font(.system(size: 11))
                    .foregroundStyle(inputs.isSelected ? Theme.accent : Theme.secondary)
                    .frame(width: 16)
                Text(inputs.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                Spacer()
                if inputs.rev > 0 {
                    Text("r\(inputs.rev)")
                        .font(.system(size: 9, design: .monospaced))
                        .monospaced()
                        .foregroundStyle(Theme.tertiary)
                }
            }
            HStack(spacing: 5) {
                Text(inputs.updatedAt.formatted(.relative(presentation: .named)))
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiary)
                if let writer = inputs.writerLabel {
                    Text("· \(writer)")
                        .font(.caption2)
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                }
                if inputs.hasMaintainers {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 8))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.leading, 23)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            inputs.isSelected ? Theme.accent.opacity(0.10) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(Rectangle())
        .contextMenu {
            Button(role: .destructive) {
                store.remove(id: inputs.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        // After the context menu on purpose: the extractor attributes the block
        // that follows a trigger to it, and a tap selects — it never removes.
        .onTapGesture(perform: onSelect)
    }
}
