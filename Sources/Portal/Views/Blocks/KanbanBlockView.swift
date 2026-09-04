import SwiftUI

/// Renders a ```kanban JSON block: declared columns side by side, each holding
/// its cards. In artifact hosts (`actionableArtifactID` set) each card carries
/// a live column picker — choosing another column moves the card through
/// `ArtifactStore`, the same `choice` path dataset actions use. In chat
/// transcripts it renders read-only. Optional board-level `overview` markdown
/// renders above the lanes, keeping durable context outside movable work. A
/// card carrying a `detail`/`desc` body or extra scalar fields (assignee, due,
/// points…) shows a disclosure chevron and expands inline on tap. PDF-safe: a
/// fixed HStack of columns, no
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

    /// Cards the user has expanded, by card id. Local view state — expansion is
    /// a display concern, never written back to the artifact.
    @State private var expanded: Set<String> = []
    /// Column currently under a drag, for drop-target highlight. Nil = none.
    @State private var dropTarget: String?

    /// Board is interactive (drag-to-move, move menu) only in an artifact host,
    /// where `actionableArtifactID` is set. In a chat transcript it's read-only.
    private var isInteractive: Bool { artifactID != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = spec.title {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Theme.primary)
            }
            if let overview = spec.overview {
                MarkdownContentView(text: overview, isStreaming: false)
                    .equatable()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        Theme.background.opacity(0.5),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Theme.border, lineWidth: 0.5)
                    )
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

    @ViewBuilder
    private func columnView(_ column: String) -> some View {
        let cards = spec.cards(in: column)
        let isTarget = dropTarget == column
        VStack(alignment: .leading, spacing: 6) {
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
                Text(isTarget ? "Drop here" : "—")
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(
            (isTarget ? Theme.accent.opacity(0.12) : Theme.background.opacity(0.5)),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.accent.opacity(isTarget ? 0.6 : 0), lineWidth: 1)
        )
        .modifier(ColumnDropTarget(
            enabled: isInteractive,
            onDrop: { cardID in move(cardID: cardID, to: column) },
            onTargeted: { targeted in dropTarget = targeted ? column : (dropTarget == column ? nil : dropTarget) }
        ))
    }

    @ViewBuilder
    private func cardView(_ card: KanbanSpec.Card) -> some View {
        let isExpanded = expanded.contains(card.id)
        let body = VStack(alignment: .leading, spacing: 4) {
            // Header is a Button so the click reliably lands — a whole-card tap
            // gesture fights both the inner move Menu and the drag gesture on
            // macOS. Every card is expandable (the expanded view always shows at
            // least id + column) so a click always does something visible.
            Button {
                if isExpanded { expanded.remove(card.id) } else { expanded.insert(card.id) }
            } label: {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .padding(.top, 2)
                    Text(card.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let note = card.note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isExpanded {
                expandedDetail(card)
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
                if isInteractive {
                    // The ONLY draggable region. Making the whole card draggable
                    // makes macOS's drag gesture win arbitration and swallow the
                    // header Button's click, so expansion never fires. A discrete
                    // grip separates drag (here) from click-to-expand (header).
                    dragHandle(for: card)
                }
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

        body
    }

    /// Grip that carries the card id as a drag payload; columns match it in
    /// their `.dropDestination`. Host-only (never rendered in a transcript).
    private func dragHandle(for card: KanbanSpec.Card) -> some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 9))
            .foregroundStyle(Theme.tertiary)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .contentShape(Rectangle())
            .draggable(card.id) {
                Text(card.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.primary)
                    .padding(8)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
            }
            .help("Drag to move")
    }

    /// Ticket body revealed on tap: a divider, the long `detail` text, then the
    /// card's fields as key/value rows. Always includes id + column as a
    /// baseline so expanding a bare card still shows something.
    private func expandedDetail(_ card: KanbanSpec.Card) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().overlay(Theme.border.opacity(0.6))
            if let detail = card.detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            fieldRow(key: "id", value: card.id)
            fieldRow(key: "column", value: card.column)
            ForEach(card.extra, id: \.key) { field in
                fieldRow(key: field.key, value: field.value)
            }
        }
        .padding(.top, 1)
    }

    private func fieldRow(key: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text(key)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.tertiary)
            Text(value)
                .font(.system(size: 9))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Move a card to a column via the same `choice` action path the move menu
    /// uses. No-ops if the card is already there or the board isn't a host.
    private func move(cardID: String, to column: String) {
        dropTarget = nil
        guard let artifactID,
              let card = spec.cards.first(where: { $0.id == cardID }),
              card.column != column else { return }
        let action = ArtifactAction(
            kind: .choice, field: "column", options: spec.columns,
            bindingID: "", label: "", intentName: "", presentationRole: .normal
        )
        ArtifactStore.shared.applyAction(
            artifactID: artifactID, action: action, entryKey: cardID, value: column
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

/// Makes a column accept a dragged card id (a `String` payload). Gated by
/// `enabled` so read-only transcript boards never register a drop target.
private struct ColumnDropTarget: ViewModifier {
    let enabled: Bool
    let onDrop: (String) -> Void
    let onTargeted: (Bool) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.dropDestination(for: String.self) { items, _ in
                guard let cardID = items.first else { return false }
                onDrop(cardID)
                return true
            } isTargeted: { targeted in
                onTargeted(targeted)
            }
        } else {
            content
        }
    }
}
