import SwiftUI

/// Read-only Sessions management surface for upstream/default Hermes.
/// Portal chat actions are intentionally absent because this API can inspect
/// sessions but cannot resume or stream them through Portal.
internal struct HermesStandardSessionsView: View {
    private enum StatusFilter: String, CaseIterable {
        case all = "All"
        case live = "Live"
        case ended = "Ended"
    }

    @StateObject private var viewModel: HermesStandardSessionsViewModel
    @State private var searchText = ""
    @State private var statusFilter: StatusFilter = .all

    private let gatewayName: String

    internal init(gateway: SavedGateway) {
        gatewayName = gateway.displayName
        _viewModel = StateObject(wrappedValue: HermesStandardSessionsViewModel(gateway: gateway))
    }

    private var visibleSessions: [Session] {
        viewModel.sessions
            .filter { !$0.isArchived }
            .filter { session in
                switch statusFilter {
                case .all: return true
                case .live: return session.isLive
                case .ended: return !session.isLive
                }
            }
            .filter { session in
                guard !searchText.isEmpty else { return true }
                let query = searchText.lowercased()
                return viewModel.title(for: session).lowercased().contains(query)
                    || (session.preview ?? "").lowercased().contains(query)
                    || (session.source ?? "").lowercased().contains(query)
                    || session.id.lowercased().contains(query)
            }
            .sorted {
                ($0.lastActive ?? $0.startedAt ?? .distantPast)
                    > ($1.lastActive ?? $1.startedAt ?? .distantPast)
            }
    }

    private var liveCount: Int {
        viewModel.sessions.filter { !$0.isArchived && $0.isLive }.count
    }

    internal var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.border)
            filterBar
            Divider().overlay(Theme.border)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .task { await viewModel.refresh() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Hermes Standard Sessions")
                    .font(.headline)
                    .foregroundStyle(Theme.primary)
                Text("Read-only management view · \(gatewayName)")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
            }
            Spacer()
            summary(value: viewModel.total, label: "Total", color: Theme.accent)
            summary(value: liveCount, label: "Live", color: Theme.success)
            Button {
                Task { await viewModel.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(viewModel.isLoading)
            .accessibilityLabel("Refresh Hermes Standard sessions")
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 54)
        .background(Theme.surface.opacity(0.45))
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.tertiary)
                TextField("Search sessions…", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: 320)

            Picker("Status", selection: $statusFilter) {
                ForEach(StatusFilter.allCases, id: \.self) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)

            Spacer()

            Label("Inspection only", systemImage: "eye")
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.sessions.isEmpty {
            ProgressView("Loading sessions…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = viewModel.errorMessage {
            errorState(error)
        } else if visibleSessions.isEmpty {
            ContentUnavailableView(
                searchText.isEmpty ? "No Sessions" : "No Matching Sessions",
                systemImage: searchText.isEmpty ? "rectangle.stack" : "magnifyingglass",
                description: Text(searchText.isEmpty
                    ? "This Hermes installation returned no visible sessions."
                    : "Try a different search or status filter.")
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(visibleSessions) { session in
                        sessionCard(session)
                    }
                }
                .padding(16)
            }
            .refreshable { await viewModel.refresh() }
        }
    }

    private func sessionCard(_ session: Session) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(session.isLive ? Theme.success : Theme.tertiary)
                .frame(width: 8, height: 8)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 5) {
                Text(viewModel.title(for: session))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)

                if let preview = session.preview, !preview.isEmpty {
                    Text(preview)
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 10) {
                    if let source = session.source, !source.isEmpty {
                        Label(source, systemImage: "terminal")
                    }
                    Label("\(session.messageCount) messages", systemImage: "bubble.left.and.text.bubble.right")
                    if let lastActive = session.lastActive {
                        Label(lastActive.relativeString, systemImage: "clock")
                    }
                }
                .font(.caption2)
                .foregroundStyle(Theme.tertiary)
            }

            Spacer()

            Text(session.isLive ? "Live" : "Ended")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(session.isLive ? Theme.success : Theme.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    (session.isLive ? Theme.success : Theme.secondary).opacity(0.12),
                    in: Capsule()
                )
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.border.opacity(0.65), lineWidth: 1)
        )
    }

    private func summary(value: Int, label: String, color: Color) -> some View {
        VStack(spacing: 0) {
            Text("\(value)")
                .font(.subheadline.monospacedDigit().bold())
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.tertiary)
        }
        .frame(minWidth: 48)
    }

    private func errorState(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Couldn’t Load Sessions", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Retry") {
                Task { await viewModel.refresh() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
