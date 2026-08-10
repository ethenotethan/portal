import SwiftUI

/// Local search + sort chrome for the skills canvas. Writes to the shared
/// `SkillsFilterState`; the list, folders, and stats panels read it.
///
/// This searches *installed* skills. Searching the remote Skills Hub is a
/// different operation against a different corpus, and lives in `SkillsHubPanel`
/// — one field that sometimes means "filter what I have" and sometimes "fetch
/// what I don't" is the ambiguity worth spending a panel to avoid.
@MainActor
internal struct SkillsSearchPanel: View {
    @EnvironmentObject private var filterState: SkillsFilterState
    /// Every installed skill — the source for the result count and the source
    /// menu's options.
    internal let skills: [SkillInfo]

    @FocusState private var searchFocused: Bool

    private var availableSources: [String] {
        Set(skills.map(\.source)).sorted()
    }

    private var matchCount: Int {
        filterState.filtered(skills).count
    }

    internal var body: some View {
        VStack(spacing: 0) {
            searchRow
            Divider().overlay(Theme.border.opacity(0.5))
            filterRow
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.background)
        .onKeyPress(.escape) {
            // Escape clears before it defocuses: the first press should undo the
            // filter, not silently leave the list narrowed with the field blurred.
            if searchFocused || !filterState.searchText.isEmpty {
                filterState.searchText = ""
                searchFocused = false
                return .handled
            }
            return .ignored
        }
    }

    // MARK: - Search row

    private var searchRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Theme.tertiary)
            TextField("Search installed skills…", text: $filterState.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
            if !filterState.searchText.isEmpty {
                Text("\(matchCount)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.tertiary)
                Button { filterState.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    // MARK: - Filter row

    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if availableSources.count > 1 {
                    sourceMenu
                    Divider().frame(height: 16).opacity(0.5)
                }

                sortMenu

                if let scoped = filterState.scopedPath {
                    Divider().frame(height: 16).opacity(0.5)
                    scopeChip(scoped)
                }

                if filterState.hasActiveFilters {
                    Divider().frame(height: 16).opacity(0.5)
                    Button {
                        withAnimation(.easeInOut(duration: 0.12)) { filterState.clearFilters() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle").font(.caption)
                            Text("Clear").font(.caption.weight(.medium))
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Theme.surface, in: Capsule())
                        .foregroundStyle(Theme.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    /// The folder scope shows up here as well as in the tree, because the tree
    /// may not be on the canvas at all — a scope with no visible cause reads as
    /// missing skills.
    private func scopeChip(_ path: [String]) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.12)) { filterState.scopedPath = nil }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder").font(.caption)
                Text(SkillCategory.displayPath(path))
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Theme.accent.opacity(0.15), in: Capsule())
            .foregroundStyle(Theme.accent)
        }
        .buttonStyle(.plain)
    }

    private var sourceMenu: some View {
        Menu {
            Button("All Sources") {
                withAnimation(.easeInOut(duration: 0.12)) { filterState.filterSource = nil }
            }
            Divider()
            ForEach(availableSources, id: \.self) { source in
                Button(source) {
                    withAnimation(.easeInOut(duration: 0.12)) { filterState.filterSource = source }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle").font(.caption)
                Text(filterState.filterSource ?? "Source")
                    .font(.caption.weight(.medium))
                if filterState.filterSource != nil {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(filterState.filterSource != nil ? Theme.accent.opacity(0.15) : Theme.surface)
            .foregroundStyle(filterState.filterSource != nil ? Theme.accent : Theme.secondary)
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var sortMenu: some View {
        Menu {
            ForEach(SkillsFilterState.SortOrder.allCases, id: \.self) { order in
                Button {
                    withAnimation(.easeInOut(duration: 0.12)) { filterState.sortOrder = order }
                } label: {
                    HStack {
                        Text(order.rawValue)
                        if filterState.sortOrder == order {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down").font(.caption)
                Text(filterState.sortOrder.rawValue)
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(filterState.sortOrder != .name ? Theme.accent.opacity(0.15) : Theme.surface)
            .foregroundStyle(filterState.sortOrder != .name ? Theme.accent : Theme.secondary)
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
