#if os(macOS)
import SwiftUI

/// The search + filter panel for the sessions canvas. Owns no session data —
/// it just reads and writes `SessionsFilterState` so the list and timeline
/// panels respond instantly to every keystroke and filter tap.
@MainActor
internal struct SessionsSearchPanel: View {
    @EnvironmentObject private var filterState: SessionsFilterState
    @EnvironmentObject private var sessionList: SessionListViewModel

    private var allSessions: [Session] { sessionList.sessions.filter { !$0.isArchived } }

    private var availableSources: [String] {
        let sources = Set(allSessions.map { $0.displaySource })
        return sources.sorted()
    }

    internal var body: some View {
        VStack(spacing: 0) {
            searchField
            if !allSessions.isEmpty {
                Divider().overlay(Theme.border.opacity(0.6))
                filterPills
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(Theme.tertiary)
            TextField("Search sessions…", text: $filterState.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.primary)
            if !filterState.searchText.isEmpty {
                Button { filterState.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Filter pills

    private var filterPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SessionsFilterState.FilterStatus.allCases, id: \.self) { status in
                    let count = countForStatus(status)
                    filterPill(
                        label: status.rawValue,
                        count: count,
                        isSelected: filterState.filterStatus == status,
                        color: status == .live ? Theme.success : Theme.accent
                    ) {
                        withAnimation(.easeInOut(duration: 0.15)) { filterState.filterStatus = status }
                    }
                }

                if availableSources.count > 1 {
                    sourceMenu
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private var sourceMenu: some View {
        Menu {
            Button("All Sources") {
                withAnimation(.easeInOut(duration: 0.15)) { filterState.filterSource = nil }
            }
            ForEach(availableSources, id: \.self) { source in
                Button(source) {
                    withAnimation(.easeInOut(duration: 0.15)) { filterState.filterSource = source }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.caption)
                Text(filterState.filterSource ?? "Source")
                    .font(.caption.weight(.medium))
                if filterState.filterSource != nil {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(filterState.filterSource != nil ? Theme.accent.opacity(0.15) : Theme.surface)
            .foregroundStyle(filterState.filterSource != nil ? Theme.accent : Theme.secondary)
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
    }

    // MARK: - Helpers

    private func filterPill(
        label: String, count: Int, isSelected: Bool, color: Color, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.caption.weight(.medium))
                Text("\(count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(isSelected ? color : Theme.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isSelected ? color.opacity(0.15) : Theme.surface)
            .foregroundStyle(isSelected ? color : Theme.secondary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func countForStatus(_ status: SessionsFilterState.FilterStatus) -> Int {
        switch status {
        case .all:   return allSessions.count
        case .live:  return allSessions.filter { $0.isLive }.count
        case .ended: return allSessions.filter { !$0.isLive }.count
        }
    }
}
#endif
