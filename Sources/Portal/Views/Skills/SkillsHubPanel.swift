import SwiftUI

/// The Skills Hub as a canvas panel: remote search and one-click install.
///
/// Separate from `SkillsSearchPanel` on purpose — this field queries a *remote*
/// corpus over the Gateway, while that one filters what's already installed.
/// Gateway-only: a Standard backend manages a fixed local skill set with no hub,
/// so the panel says so rather than offering a field that can't work.
@MainActor
internal struct SkillsHubPanel: View {
    internal let viewModel: SkillsViewModel

    internal var body: some View {
        Group {
            if viewModel.isStandardMode {
                PanelEmptyState(
                    icon: "lock",
                    message: "The Skills Hub needs a Gateway harness — a Standard backend manages a fixed local set"
                )
            } else {
                VStack(spacing: 0) {
                    searchRow
                    Divider().overlay(Theme.border.opacity(0.5))
                    results
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    private var searchRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Theme.tertiary)
            TextField("Search the Skills Hub…", text: Binding(
                get: { viewModel.searchQuery },
                set: { viewModel.searchQuery = $0 }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .onSubmit { Task { await viewModel.search() } }

            if viewModel.isSearching {
                PortalProgressView().scaleEffect(0.5)
            } else {
                Button {
                    Task { await viewModel.search() }
                } label: {
                    Text("Search").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .disabled(viewModel.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private var results: some View {
        if let searchError = viewModel.searchError {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.warning)
                Text(searchError)
                    .font(.caption)
                    .foregroundStyle(Theme.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(12)
        } else if !viewModel.searchResults.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(viewModel.searchResults) { result in
                        SkillsHubResultRow(
                            result: result,
                            installStatus: viewModel.installStatus[result.name],
                            onInstall: { Task { await viewModel.installSkill(name: result.name) } }
                        )
                    }
                }
                .padding(10)
            }
        } else if viewModel.isSearching {
            PortalProgressView(label: "Searching the hub…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.searchQuery.count >= 2 {
            PanelEmptyState(icon: "magnifyingglass", message: "No matches — try a different keyword")
        } else {
            PanelEmptyState(icon: "square.and.arrow.down", message: "Search the hub to discover and install skills")
        }
    }
}

/// One hub search result. A canvas-local copy of the row rather than a shared
/// component: `SkillsView`'s `HubResultRow` is `private` to that file and sized
/// for a full-width section, and widening its access to share a 30-line row would
/// couple the two surfaces for no real gain.
@MainActor
internal struct SkillsHubResultRow: View {
    internal let result: SkillSearchResult
    internal let installStatus: String?
    internal let onInstall: () -> Void

    internal var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(result.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                if !result.description.isEmpty {
                    Text(result.description)
                        .font(.caption2)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            installControl
        }
        .padding(8)
        .background(Theme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var installControl: some View {
        if let status = installStatus {
            if status == "installing" {
                PortalProgressView().scaleEffect(0.5)
            } else if status == "installed" {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.success)
            } else {
                Button("Retry", action: onInstall)
                    .font(.caption2)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    .help(status)
            }
        } else {
            Button("Install", action: onInstall)
                .font(.system(size: 11, weight: .semibold))
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
        }
    }
}
