import SwiftUI

/// Chronological feed of wiki changesets (edit history) with action filtering,
/// day grouping, pagination, and tap-to-open-page.
struct WikiTimelineView: View {
    @StateObject private var viewModel = WikiTimelineViewModel()
    @EnvironmentObject var gatewayClientWrapper: GatewayClientWrapper

    /// Wiki name to scope the timeline to (nil = default wiki).
    let wiki: String?
    /// Optional single-page filter (relative path); shows that page's history.
    var pageFilter: String?
    /// Called when a row is tapped, with the changeset's page path.
    var onOpenPage: ((String) -> Void)?

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(Theme.background)
        .task(id: pageFilter) {
            viewModel.configure(wiki: wiki, page: pageFilter)
            await viewModel.start(client: gatewayClientWrapper.client)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.accent)

            Text(pageFilter == nil ? "Timeline" : "Page History")
                .font(.headline)
                .foregroundStyle(Theme.primary)

            if viewModel.total > 0 {
                Text("\(viewModel.total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.secondary)
            }

            Spacer()

            actionFilterMenu

            Button {
                Task { await viewModel.reload(client: gatewayClientWrapper.client) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("Refresh timeline")
        }
        .foregroundStyle(Theme.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.surface)
    }

    private var actionFilterMenu: some View {
        Menu {
            Button {
                viewModel.actionFilter = nil
            } label: {
                if viewModel.actionFilter == nil {
                    Label("All changes", systemImage: "checkmark")
                } else {
                    Text("All changes")
                }
            }
            Divider()
            ForEach([WikiChangeset.Action.create, .update, .archive, .delete], id: \.rawValue) { action in
                Button {
                    viewModel.actionFilter = action
                } label: {
                    if viewModel.actionFilter == action {
                        Label(action.rawValue.capitalized, systemImage: "checkmark")
                    } else {
                        Label(action.rawValue.capitalized, systemImage: action.icon)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 12))
                Text(viewModel.actionFilter?.rawValue.capitalized ?? "All")
                    .font(.caption)
            }
            .foregroundStyle(viewModel.actionFilter == nil ? Theme.secondary : Theme.accent)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.changesets.isEmpty {
            Spacer()
            HermesProgressView(label: "Loading timeline…")
            Spacer()
        } else if let error = viewModel.error, viewModel.changesets.isEmpty {
            errorState(error)
        } else if viewModel.changesets.isEmpty {
            emptyState
        } else {
            timelineList
        }
    }

    private var timelineList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(groupedByDay, id: \.key) { group in
                    Section {
                        ForEach(group.items) { changeset in
                            WikiChangesetRow(
                                changeset: changeset,
                                showPage: pageFilter == nil,
                                relativeText: relativeText(for: changeset)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { onOpenPage?(changeset.page) }
                            Divider().padding(.leading, 44)
                        }
                    } header: {
                        dayHeader(group.title)
                    }
                }

                if viewModel.hasMore {
                    loadMoreFooter
                }
            }
        }
    }

    private func dayHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Theme.background.opacity(0.96))
    }

    private var loadMoreFooter: some View {
        HStack {
            Spacer()
            if viewModel.isLoadingMore {
                HermesProgressView()
                    .scaleEffect(0.7)
            } else {
                Button("Load more") {
                    Task { await viewModel.loadMore(client: gatewayClientWrapper.client) }
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(Theme.accent)
            }
            Spacer()
        }
        .padding(.vertical, 12)
        .onAppear {
            // Auto-paginate when the footer scrolls into view.
            Task { await viewModel.loadMore(client: gatewayClientWrapper.client) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 36))
                .foregroundStyle(Theme.tertiary)
            Text(pageFilter == nil ? "No changes recorded yet" : "No history for this page")
                .font(.callout)
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ error: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30))
                .foregroundStyle(Theme.warning)
            Text("Couldn’t load timeline")
                .font(.callout)
                .foregroundStyle(Theme.primary)
            Text(error)
                .font(.caption)
                .foregroundStyle(Theme.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Retry") {
                Task { await viewModel.reload(client: gatewayClientWrapper.client) }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Grouping

    private struct DayGroup {
        let key: String
        let title: String
        let items: [WikiChangeset]
    }

    /// Group changesets by calendar day, preserving newest-first order.
    private var groupedByDay: [DayGroup] {
        var order: [String] = []
        var buckets: [String: [WikiChangeset]] = [:]
        for changeset in viewModel.changesets {
            let key: String
            let title: String
            if let date = changeset.date {
                key = Self.dayFormatter.string(from: date)
                title = dayTitle(for: date, key: key)
            } else {
                key = "Unknown date"
                title = "Unknown date"
            }
            if buckets[key] == nil {
                buckets[key] = []
                order.append(key)
            }
            buckets[key]?.append(changeset)
        }
        return order.map { DayGroup(key: $0, title: titleCache[$0] ?? $0, items: buckets[$0] ?? []) }
    }

    // Resolve the display title once per key (Today / Yesterday / date).
    private var titleCache: [String: String] {
        var cache: [String: String] = [:]
        for changeset in viewModel.changesets {
            guard let date = changeset.date else {
                cache["Unknown date"] = "Unknown date"
                continue
            }
            let key = Self.dayFormatter.string(from: date)
            if cache[key] == nil { cache[key] = dayTitle(for: date, key: key) }
        }
        return cache
    }

    private func dayTitle(for date: Date, key: String) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return key
    }

    private func relativeText(for changeset: WikiChangeset) -> String {
        guard let date = changeset.date else { return "" }
        return Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Row

private struct WikiChangesetRow: View {
    let changeset: WikiChangeset
    let showPage: Bool
    let relativeText: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: changeset.action.icon)
                .font(.system(size: 14))
                .foregroundStyle(actionColor)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(changeset.title.isEmpty ? changeset.page : changeset.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)

                    if !changeset.type.isEmpty {
                        Text(changeset.type)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Theme.surfaceHover, in: Capsule())
                    }

                    Spacer(minLength: 4)

                    Text(relativeText)
                        .font(.caption2)
                        .foregroundStyle(Theme.tertiary)
                        .fixedSize()
                }

                if !changeset.summary.isEmpty {
                    Text(changeset.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    metaChip(systemImage: "bolt.fill", text: changeset.trigger.label)

                    if changeset.linesAdded > 0 || changeset.linesRemoved > 0 {
                        HStack(spacing: 4) {
                            Text("+\(changeset.linesAdded)")
                                .foregroundStyle(Theme.success)
                            Text("−\(changeset.linesRemoved)")
                                .foregroundStyle(Theme.warning)
                        }
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                    }

                    if !changeset.gitCommit.isEmpty {
                        metaChip(systemImage: "arrow.triangle.branch", text: changeset.gitCommit)
                    }

                    if showPage {
                        Text(changeset.page)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    private func metaChip(systemImage: String, text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: 8))
            Text(text)
                .font(.system(size: 10))
        }
        .foregroundStyle(Theme.tertiary)
    }

    private var actionColor: Color {
        switch changeset.action {
        case .create: return Theme.success
        case .update: return Theme.accent
        case .archive: return Theme.warning
        case .delete: return Color(hex: "e85c5c") ?? Theme.warning
        case .unknown: return Theme.secondary
        }
    }
}
