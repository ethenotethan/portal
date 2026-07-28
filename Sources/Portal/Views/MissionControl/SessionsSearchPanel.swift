#if os(macOS)
import SwiftUI

/// Global filter bar for the sessions canvas. Compact single-panel chrome:
/// search field, status chips, source menu, time-window picker. All controls
/// write to `SessionsFilterState` which every other panel observes.
@MainActor
internal struct SessionsSearchPanel: View {
    @EnvironmentObject private var filterState: SessionsFilterState
    @EnvironmentObject private var sessionList: SessionListViewModel

    @FocusState private var searchFocused: Bool

    private var allNonCronSessions: [Session] {
        sessionList.sessions.filter { !$0.isArchived && !$0.isCron }
    }

    private var availableSources: [String] {
        let sources = Set(allNonCronSessions.map { $0.displaySource })
        return sources.sorted()
    }

    internal var body: some View {
        VStack(spacing: 0) {
            searchRow
            Divider().overlay(Theme.border.opacity(0.5))
            filterRow
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.background)
        .keyboardShortcut("f", modifiers: .command)
        .onKeyPress(.escape) {
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
            TextField("Search sessions…", text: $filterState.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
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
                // Status chips
                ForEach(SessionsFilterState.FilterStatus.allCases, id: \.self) { status in
                    chip(
                        label: status.rawValue,
                        count: countForStatus(status),
                        isSelected: filterState.filterStatus == status,
                        color: status == .live ? Theme.success : Theme.accent
                    ) {
                        withAnimation(.easeInOut(duration: 0.12)) { filterState.filterStatus = status }
                    }
                }

                if availableSources.count > 1 {
                    Divider().frame(height: 16).opacity(0.5)
                    sourceMenu
                }

                Divider().frame(height: 16).opacity(0.5)
                timeWindowMenu

                Divider().frame(height: 16).opacity(0.5)
                sortMenu

                if !filterState.savedPresets.isEmpty {
                    Divider().frame(height: 16).opacity(0.5)
                    presetsMenu
                }
                Divider().frame(height: 16).opacity(0.5)
                savePresetButton
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private var sortMenu: some View {
        Menu {
            ForEach(SessionsFilterState.SortOrder.allCases, id: \.self) { order in
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

    private var presetsMenu: some View {
        Menu {
            ForEach(filterState.savedPresets) { preset in
                Button { filterState.applyPreset(preset) } label: {
                    Text(preset.name)
                }
            }
            Divider()
            ForEach(filterState.savedPresets) { preset in
                Button(role: .destructive) { filterState.deletePreset(id: preset.id) } label: {
                    Label("Delete \"\(preset.name)\"", systemImage: "trash")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "star").font(.caption)
                Text("Presets").font(.caption.weight(.medium))
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Theme.surface)
            .foregroundStyle(Theme.secondary)
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @State private var showSavePreset = false
    @State private var presetName = ""

    private var savePresetButton: some View {
        Button {
            presetName = ""
            showSavePreset = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "star.badge.plus").font(.caption)
                Text("Save").font(.caption.weight(.medium))
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Theme.surface)
            .foregroundStyle(Theme.secondary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showSavePreset) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Save preset")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                TextField("Preset name…", text: $presetName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(width: 180)
                HStack {
                    Button("Cancel") { showSavePreset = false }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                    Spacer()
                    Button("Save") {
                        if !presetName.isEmpty {
                            filterState.saveCurrentPreset(name: presetName)
                            showSavePreset = false
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .disabled(presetName.isEmpty)
                }
            }
            .padding(14)
        }
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
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.caption)
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

    private var timeWindowMenu: some View {
        Menu {
            ForEach(SessionsFilterState.TimeWindow.presets, id: \.label) { window in
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

    // MARK: - Helpers

    private func chip(label: String, count: Int, isSelected: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(label).font(.caption.weight(.medium))
                Text("\(count)").font(.caption2.monospacedDigit()).foregroundStyle(isSelected ? color : Theme.tertiary)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(isSelected ? color.opacity(0.15) : Theme.surface)
            .foregroundStyle(isSelected ? color : Theme.secondary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func countForStatus(_ status: SessionsFilterState.FilterStatus) -> Int {
        switch status {
        case .all:   return allNonCronSessions.count
        case .live:  return allNonCronSessions.filter { $0.isLive }.count
        case .ended: return allNonCronSessions.filter { !$0.isLive }.count
        }
    }
}
#endif
