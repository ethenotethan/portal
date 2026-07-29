import SwiftUI

/// Renders a ```kanban JSON block: declared columns side by side, each holding
/// its cards. In artifact hosts (`actionableArtifactID` set) each card carries
/// a live column picker — choosing another column moves the card through
/// `ArtifactStore`, the same `choice` path dataset actions use. In chat
/// transcripts it renders read-only. PDF-safe: a fixed HStack of columns, no
/// ScrollView (a board with many columns clips rather than scrolls in export,
/// acceptable for a snapshot).
internal struct KanbanBlockView: View {
    internal let json: String
    internal let isStreaming: Bool
    internal var actionableArtifactID: String?

    internal var body: some View {
        if let spec = KanbanSpec.parse(json) {
            KanbanCard(spec: spec, artifactID: actionableArtifactID)
        } else if isStreaming {
            EmptyView()
        } else {
            ArtifactParseError(kind: "kanban", json: json)
        }
    }
}

private struct KanbanCard: View {
    let spec: KanbanSpec
    let artifactID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = spec.title {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Theme.primary)
            }
            HStack(alignment: .top, spacing: 10) {
                ForEach(spec.columns, id: \.self) { column in
                    columnView(column)
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

    private func columnView(_ column: String) -> some View {
        let cards = spec.cards(in: column)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(column)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.secondary)
                Text("\(cards.count)")
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiary)
                    .monospacedDigit()
            }
            ForEach(cards) { card in
                cardView(card)
            }
            if cards.isEmpty {
                Text("—")
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Theme.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func cardView(_ card: KanbanSpec.Card) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(card.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.primary)
                .fixedSize(horizontal: false, vertical: true)
            if let note = card.note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                if let tag = card.tag {
                    Text(tag)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Theme.accent.opacity(0.12), in: Capsule())
                }
                Spacer(minLength: 0)
                if let artifactID {
                    moveMenu(for: card, artifactID: artifactID)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Theme.border, lineWidth: 0.5)
        )
    }

    /// Column picker → a `choice` action on the card's `column` field.
    private func moveMenu(for card: KanbanSpec.Card, artifactID: String) -> some View {
        let action = ArtifactAction(
            kind: .choice, field: "column", options: spec.columns,
            bindingID: "", label: "", intentName: "", presentationRole: .normal
        )
        return Menu {
            ForEach(spec.columns, id: \.self) { column in
                Button {
                    ArtifactStore.shared.applyAction(
                        artifactID: artifactID, action: action, entryKey: card.id, value: column
                    )
                } label: {
                    if column == card.column {
                        Label(column, systemImage: "checkmark")
                    } else {
                        Text(column)
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 9))
                .foregroundStyle(Theme.tertiary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Move card")
    }
}
