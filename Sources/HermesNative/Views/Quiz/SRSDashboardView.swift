import SwiftUI

/// Flashcard deck library presented as a sheet from the chat toolbar.
/// Shares card rows, stat tiles, and the due banner with the Learning
/// dashboard so the two surfaces stay visually identical.
struct SRSDashboardView: View {
    @State private var decks: [FlashcardDeck] = []
    @State private var pendingDeleteDeck: FlashcardDeck?

    let onClose: () -> Void
    let onStudyDeck: (FlashcardDeck) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                if decks.isEmpty {
                    LearningEmptyState(
                        icon: "rectangle.on.rectangle",
                        title: "No Flashcard Decks",
                        message: "Type /flashcard <topic> in chat, or ask the agent — decks land here for spaced review."
                    )
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
        .background(Theme.background)
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 400)
        .frame(
            width: min((NSScreen.main?.visibleFrame.width ?? 800) * 0.7, 700),
            height: min((NSScreen.main?.visibleFrame.height ?? 700) * 0.75, 560)
        )
        #endif
        .onAppear { refreshDecks() }
        .confirmationDialog(
            "Delete \"\(pendingDeleteDeck?.topic ?? "")\"?",
            isPresented: Binding(
                get: { pendingDeleteDeck != nil },
                set: { if !$0 { pendingDeleteDeck = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { confirmDelete() }
            Button("Cancel", role: .cancel) { pendingDeleteDeck = nil }
        } message: {
            Text("This can't be undone.")
        }
    }

    // MARK: - Deck List

    private var deckList: some View {
        ScrollView {
            VStack(spacing: 12) {
                if totalDueCount > 0 {
                    LearningDueBanner(dueCount: totalDueCount) {
                        if let deck = sortedDecks.first(where: { $0.dueCount > 0 }) {
                            study(deck)
                        }
                    }
                }

                HStack(spacing: 10) {
                    LearningStatTile(value: "\(decks.count)", label: "Decks")
                    LearningStatTile(
                        value: "\(decks.reduce(0) { $0 + $1.totalCount })",
                        label: "Cards"
                    )
                    LearningStatTile(
                        value: "\(decks.reduce(0) { $0 + $1.learnedCount })",
                        label: "Learned",
                        icon: "brain.head.profile",
                        iconColor: Theme.success
                    )
                    LearningStatTile(
                        value: "\(totalDueCount)",
                        label: "Due",
                        icon: totalDueCount > 0 ? "clock" : "checkmark.circle",
                        iconColor: totalDueCount > 0 ? Theme.warning : Theme.success
                    )
                }

                LazyVStack(spacing: 10) {
                    ForEach(sortedDecks) { deck in
                        LearningDeckCard(
                            deck: deck,
                            onOpen: { study(deck) },
                            onDelete: { pendingDeleteDeck = deck }
                        )
                    }
                }

                if totalDueCount == 0 {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.success)
                        Text("All caught up! No cards due.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondary)
                    }
                    .padding(.top, 8)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
    }

    private var sortedDecks: [FlashcardDeck] {
        decks.sorted { a, b in
            if (a.dueCount > 0) != (b.dueCount > 0) { return a.dueCount > 0 }
            return a.created > b.created
        }
    }

    private var totalDueCount: Int {
        decks.reduce(0) { $0 + $1.dueCount }
    }

    // MARK: - Actions

    private func study(_ deck: FlashcardDeck) {
        onStudyDeck(deck)
        onClose()
    }

    private func confirmDelete() {
        guard let deck = pendingDeleteDeck else { return }
        SRSStore.shared.deleteDeck(id: deck.id)
        decks.removeAll { $0.id == deck.id }
        pendingDeleteDeck = nil
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
