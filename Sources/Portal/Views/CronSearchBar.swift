import SwiftUI

/// Filter chrome for the Cron page, matching `SessionsSearchPanel`: a plain
/// inline search field over a horizontal row of status chips, a time-window
/// picker, and a sort menu. Every control writes to `CronFilterState`, which
/// `CronListView` observes. Cross-platform (the Cron page ships on iOS too).
internal struct CronSearchBar: View {
    @ObservedObject internal var filterState: CronFilterState
    internal let jobs: [CronJob]

    @FocusState private var searchFocused: Bool

    internal var body: some View {
        VStack(spacing: 0) {
            searchRow
            Divider().overlay(Theme.border.opacity(0.5))
            filterRow
        }
        .background(Theme.background)
    }

    // MARK: - Search row

    private var searchRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Theme.tertiary)
            TextField("Search cron jobs…", text: $filterState.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            if !filterState.searchText.isEmpty {
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
                ForEach(CronFilterState.FilterStatus.allCases, id: \.self) { status in
                    chip(
                        label: status.rawValue,
                        count: filterState.count(for: status, in: jobs),
                        isSelected: filterState.filterStatus == status,
                        color: color(for: status)
                    ) {
                        withAnimation(.easeInOut(duration: 0.12)) { filterState.filterStatus = status }
                    }
                }

                Divider().frame(height: 16).opacity(0.5)
                timeWindowMenu

                Divider().frame(height: 16).opacity(0.5)
                sortMenu

                if hasAnyCategory {
                    Divider().frame(height: 16).opacity(0.5)
                    groupToggle
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private var timeWindowMenu: some View {
        Menu {
            ForEach(CronFilterState.TimeWindow.presets, id: \.label) { window in
                Button {
                    withAnimation(.easeInOut(duration: 0.12)) { filterState.timeWindow = window }
                } label: {
                    HStack {
                        Text(window.label)
                        if filterState.timeWindow == window {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "clock").font(.caption)
                Text(filterState.timeWindow == .all ? "Time" : filterState.timeWindow.label)
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(filterState.timeWindow != .all ? Theme.accent.opacity(0.15) : Theme.surface)
            .foregroundStyle(filterState.timeWindow != .all ? Theme.accent : Theme.secondary)
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var sortMenu: some View {
        Menu {
            ForEach(CronFilterState.SortOrder.allCases, id: \.self) { order in
                Button {
                    withAnimation(.easeInOut(duration: 0.12)) { filterState.sortOrder = order }
                } label: {
                    HStack {
                        Text(order.rawValue)
                        if filterState.sortOrder == order { Spacer(); Image(systemName: "checkmark") }
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
            .background(filterState.sortOrder != .recent ? Theme.accent.opacity(0.15) : Theme.surface)
            .foregroundStyle(filterState.sortOrder != .recent ? Theme.accent : Theme.secondary)
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// The grouping affordance only appears once at least one job is named with
    /// a path — otherwise the tree would be a single "Ungrouped" section and the
    /// control would be dead weight.
    private var hasAnyCategory: Bool {
        jobs.contains { !CronCategory.isUngrouped($0) }
    }

    private var groupToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.12)) {
                filterState.groupByCategory.toggle()
                // Opening the tree with everything collapsed hides every job, so
                // seed the top level expanded on first use.
                if filterState.groupByCategory, filterState.expandedCategories.isEmpty {
                    filterState.expandAll(in: CronCategory.group(jobs))
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: filterState.groupByCategory
                      ? "list.bullet.indent" : "list.bullet")
                    .font(.caption)
                Text("Group")
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(filterState.groupByCategory ? Theme.accent.opacity(0.15) : Theme.surface)
            .foregroundStyle(filterState.groupByCategory ? Theme.accent : Theme.secondary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Group jobs by their name path (life/training/…)")
    }

    // MARK: - Helpers

    private func color(for status: CronFilterState.FilterStatus) -> Color {
        switch status {
        case .all:     return Theme.accent
        case .active:  return Theme.success
        case .paused:  return Theme.secondary
        case .failing: return .red
        }
    }

    private func chip(label: String, count: Int, isSelected: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(label).font(.caption.weight(.medium))
                Text("\(count)").font(.caption2.monospacedDigit())
                    .foregroundStyle(isSelected ? color : Theme.tertiary)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(isSelected ? color.opacity(0.15) : Theme.surface)
            .foregroundStyle(isSelected ? color : Theme.secondary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
