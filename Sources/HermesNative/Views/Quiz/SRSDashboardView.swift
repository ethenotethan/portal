import SwiftUI

/// Dashboard showing all persisted flashcard decks with SRS stats.
/// Displays due counts, mastery progress, and "Study Now" buttons.
/// Accessible from the chat toolbar as a sheet overlay.
struct SRSDashboardView: View {
    @State private var decks: [FlashcardDeck] = []
    @State private var selectedDeck: FlashcardDeck?
    @State private var showStudySheet = false

    let onClose: () -> Void
    let onStudyDeck: (FlashcardDeck) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                if decks.isEmpty {
                    emptyState
                } else {
                    deckList
                }
            }
            .navigationTitle("Flashcard Decks")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { onClose() }
                        .foregroundStyle(Theme.secondary)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 400)
        .background(Theme.background)
        #if os(macOS)
        .frame(
            width: min((NSScreen.main?.visibleFrame.width ?? 800) * 0.7, 700),
            height: min((NSScreen.main?.visibleFrame.height ?? 700) * 0.75, 560)
        )
        #endif
        .onAppear {
            refreshDecks()
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "rectangle.stack.fill")
                .font(.system(size: 40))
                .foregroundStyle(Theme.tertiary)
            Text("No Flashcard Decks")
                .font(.headline)
                .foregroundStyle(Theme.primary)
            Text("Generate flashcards by typing /flashcard <topic> in chat, or the agent can create them automatically.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
    }

    // MARK: - Deck List

    private var deckList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                // Summary bar
                summaryBar
                    .padding(.horizontal, 20)
                    .padding(.top, 12)

                // Deck cards
                ForEach(sortedDecks) { deck in
                    deckRow(deck)
                }

                if decks.allSatisfy({ $0.dueCount == 0 }) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.success)
                        Text("All caught up! No cards due.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondary)
                    }
                    .padding(.top, 20)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }

    private var sortedDecks: [FlashcardDeck] {
        decks.sorted { a, b in
            // Due decks first, then by created date
            let aDue = a.dueCount > 0 ? 0 : 1
            let bDue = b.dueCount > 0 ? 0 : 1
            if aDue != bDue { return aDue < bDue }
            return a.created > b.created
        }
    }

    // MARK: - Summary Bar

    private var summaryBar: some View {
        HStack(spacing: 12) {
            summaryStat(
                value: "\(decks.count)",
                label: "Decks",
                color: Theme.accent
            )
            summaryStat(
                value: "\(decks.reduce(0) { $0 + $1.totalCount })",
                label: "Cards",
                color: Theme.primary
            )
            summaryStat(
                value: "\(decks.reduce(0) { $0 + $1.learnedCount })",
                label: "Learned",
                color: Theme.success
            )
            summaryStat(
                value: "\(decks.reduce(0) { $0 + $1.dueCount })",
                label: "Due",
                color: totalDueCount > 0 ? Theme.warning : Theme.success
            )
        }
    }

    private var totalDueCount: Int {
        decks.reduce(0) { $0 + $1.dueCount }
    }

    private func summaryStat(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.headline.weight(.bold))
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Deck Row

    private func deckRow(_ deck: FlashcardDeck) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(deck.topic)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        // Due badge
                        if deck.dueCount > 0 {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(Theme.warning)
                                    .frame(width: 6, height: 6)
                                Text("\(deck.dueCount) due")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.warning)
                            }
                        }

                        // Mastery progress
                        HStack(spacing: 4) {
                            Image(systemName: "brain.head.profile")
                                .font(.caption2)
                            Text("\(deck.learnedCount)/\(deck.totalCount) learned")
                                .font(.caption2)
                                .foregroundStyle(Theme.secondary)
                        }

                        // Date
                        Text(deck.created, style: .date)
                            .font(.caption2)
                            .foregroundStyle(Theme.tertiary)
                    }
                }

                Spacer()

                // Study button
                if deck.dueCount > 0 {
                    Button {
                        onStudyDeck(deck)
                        onClose()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 10))
                            Text("Study")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(Theme.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                            .font(.caption2)
                        Text("Done")
                            .font(.caption2)
                    }
                    .foregroundStyle(Theme.success)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.success.opacity(0.1), in: Capsule())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(deck.dueCount > 0 ? Theme.warning.opacity(0.3) : Theme.border.opacity(0.5), lineWidth: 1)
        )
        .contextMenu {
            Button(role: .destructive) {
                SRSStore.shared.deleteDeck(id: deck.id)
                refreshDecks()
            } label: {
                Label("Delete Deck", systemImage: "trash")
            }
        }
    }

    // MARK: - Data

    private func refreshDecks() {
        decks = SRSStore.shared.allDecks()
    }
}

// MARK: - Preview

#if DEBUG
struct SRSDashboardView_Previews: PreviewProvider {
    static var previews: some View {
        SRSDashboardView(
            onClose: {},
            onStudyDeck: { _ in }
        )
        .background(Theme.background)
    }
}
#endif
