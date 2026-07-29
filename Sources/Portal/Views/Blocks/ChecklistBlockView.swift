import SwiftUI

/// Renders a ```checklist JSON block: a title, a done/total progress line, and
/// one row per item with a checkbox. In artifact hosts (where
/// `actionableArtifactID` is set) the checkbox is live — tapping it toggles the
/// item's `done` field through `ArtifactStore`, the same path dataset toggles
/// use. In chat transcripts it renders read-only (a snapshot, not the model).
/// PDF-safe: no ScrollView, no representables.
internal struct ChecklistBlockView: View {
    internal let json: String
    internal let isStreaming: Bool
    internal var actionableArtifactID: String?

    internal var body: some View {
        if let spec = ChecklistSpec.parse(json) {
            ChecklistCard(spec: spec, artifactID: actionableArtifactID)
        } else if isStreaming {
            EmptyView()
        } else {
            ArtifactParseError(kind: "checklist", json: json)
        }
    }
}

private struct ChecklistCard: View {
    let spec: ChecklistSpec
    let artifactID: String?

    /// The synthetic verb every checklist item exposes: toggle `done`. Declared
    /// here rather than in the JSON so authors don't have to boilerplate it.
    private static let doneAction = ArtifactAction(
        kind: .toggle, field: "done", options: [],
        bindingID: "", label: "", intentName: "", presentationRole: .normal
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                if let title = spec.title {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(Theme.primary)
                }
                Spacer(minLength: 8)
                Text("\(spec.completedCount)/\(spec.items.count)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.secondary)
                    .monospacedDigit()
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(spec.items) { item in
                    row(for: item)
                }
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.border, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func row(for item: ChecklistSpec.Item) -> some View {
        HStack(alignment: .top, spacing: 8) {
            checkbox(for: item)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.label)
                    .font(.system(size: 13))
                    .foregroundStyle(item.done ? Theme.tertiary : Theme.primary)
                    .strikethrough(item.done, color: Theme.tertiary)
                if let note = item.note {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(Theme.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func checkbox(for item: ChecklistSpec.Item) -> some View {
        let symbol = Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 14))
            .foregroundStyle(item.done ? Theme.accent : Theme.tertiary)
        if let artifactID {
            Button {
                ArtifactStore.shared.applyAction(
                    artifactID: artifactID, action: Self.doneAction, entryKey: item.id
                )
            } label: { symbol }
            .buttonStyle(.plain)
        } else {
            symbol
        }
    }
}
