import SwiftUI

struct SkillsView: View {
    @EnvironmentObject var gatewayClientWrapper: GatewayClientWrapper
    @State private var viewModel = SkillsViewModel()
    @State private var expandedSkill: String?
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var confirmUninstall: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider().background(Theme.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summaryBar
                    installedSection
                    hubSection
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .refreshable { await viewModel.reload() }
        }
        .background(Theme.background)
        .task {
            viewModel.setGatewayClient(gatewayClientWrapper.client)
            await viewModel.refresh()
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            Text("Skills")
                .font(.headline)
                .foregroundStyle(Theme.primary)

            Spacer()

            Button {
                Task { await viewModel.reload() }
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .disabled(viewModel.isLoading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.surface)
    }

    // MARK: - Summary

    private var summaryBar: some View {
        HStack(spacing: 0) {
            summaryChip(value: "\(viewModel.totalSkills)", label: "Skills", color: Theme.accent)
            summaryChip(value: "\(viewModel.categoryCount)", label: "Categories", color: Theme.success)
        }
        .padding(12)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func summaryChip(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3.monospacedDigit().bold())
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Installed Skills

    private var installedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Installed")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.primary)

            if viewModel.skills.isEmpty && !viewModel.isLoading {
                emptyState
            } else {
                ForEach(viewModel.categories.keys.sorted(), id: \.self) { category in
                    if let skills = viewModel.categories[category] {
                        skillCategoryGroup(category: category, skills: skills)
                    }
                }
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func skillCategoryGroup(category: String, skills: [SkillInfo]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(category.capitalized)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.secondary)
                .padding(.bottom, 2)

            ForEach(skills) { skill in
                SkillCard(
                    skill: skill,
                    isExpanded: expandedSkill == skill.id,
                    installStatus: viewModel.installStatus[skill.name] ?? nil,
                    confirmUninstall: confirmUninstall == skill.name,
                    onToggle: {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            expandedSkill = expandedSkill == skill.id ? nil : skill.id
                        }
                    },
                    onUninstall: {
                        if confirmUninstall == skill.name {
                            confirmUninstall = nil
                            Task { await viewModel.uninstallSkill(name: skill.name) }
                        } else {
                            confirmUninstall = skill.name
                        }
                    },
                    onCancelUninstall: {
                        confirmUninstall = nil
                    }
                )
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 32))
                .foregroundStyle(Theme.tertiary)
            Text("No Skills Installed")
                .font(.headline)
                .foregroundStyle(Theme.secondary)
            Text("Search the Skills Hub below to discover and install skills.")
                .font(.subheadline)
                .foregroundStyle(Theme.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    // MARK: - Skills Hub

    private var hubSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Skills Hub")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.primary)

            HStack(spacing: 8) {
                TextField("Search skills hub...", text: $viewModel.searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await viewModel.search() } }

                Button {
                    Task { await viewModel.search() }
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if viewModel.isSearching {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Searching...")
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                }
            }

            if !viewModel.searchResults.isEmpty {
                ForEach(viewModel.searchResults) { result in
                    HubResultRow(
                        result: result,
                        installStatus: viewModel.installStatus[result.name],
                        onInstall: { Task { await viewModel.installSkill(name: result.name) } }
                    )
                }
            } else if !viewModel.isSearching && viewModel.searchQuery.count >= 2 {
                Text("No results found")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Skill Card

private struct SkillCard: View {
    let skill: SkillInfo
    let isExpanded: Bool
    let installStatus: String?
    let confirmUninstall: Bool
    let onToggle: () -> Void
    let onUninstall: () -> Void
    let onCancelUninstall: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
                .contentShape(Rectangle())
                .onTapGesture { onToggle() }

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Divider().background(Theme.border)
                    if !skill.description.isEmpty {
                        Text(skill.description)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Theme.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let preview = skill.skillMdPreview {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("SKILL.md Preview")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Theme.tertiary)
                            ScrollView {
                                Text(preview)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(Theme.secondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 200)
                        }
                    }
                    if let path = skill.skillMdPath {
                        detailRow("Path", value: path)
                    }
                    if !skill.tags.isEmpty {
                        detailRow("Tags", value: skill.tags.joined(separator: ", "))
                    }
                    detailRow("Source", value: skill.source)
                    detailRow("Command", value: skill.slashCommand)
                    uninstallButton
                }
                .padding(.top, 8)
                .padding(.leading, 28)
                .padding(.trailing, 4)
                .padding(.bottom, 4)
            }
        }
        .padding(10)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: 10))
    }

    private var headerRow: some View {
        HStack(spacing: 10) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.tertiary)
                .frame(width: 14)

            Image(systemName: sourceIcon)
                .font(.body)
                .foregroundStyle(sourceColor)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(skill.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)

                    if !skill.slashCommand.isEmpty {
                        Text(skill.slashCommand)
                            .font(.caption2)
                            .fontWeight(.medium)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Theme.accent.opacity(0.12))
                            .foregroundStyle(Theme.accent)
                            .clipShape(Capsule())
                    }

                    Text(skill.source)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(sourceColor.opacity(0.12))
                        .foregroundStyle(sourceColor)
                        .clipShape(Capsule())
                }

                if !skill.description.isEmpty && !isExpanded {
                    Text(skill.description)
                        .font(.caption2)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let status = installStatus {
                if status == "installing" || status == "uninstalling" {
                    ProgressView().controlSize(.small)
                } else if status == "installed" {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.success)
                } else if status.hasPrefix("failed") {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var sourceIcon: String {
        switch skill.source {
        case "official": "checkmark.seal.fill"
        case "github": "chevron.left.forwardslash.chevron.right"
        default: "sparkles"
        }
    }

    private var sourceColor: Color {
        switch skill.source {
        case "official": Theme.success
        case "github": Theme.accent
        default: .secondary
        }
    }

    private func detailRow(_ title: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(Theme.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 3)
    }

    private var uninstallButton: some View {
        HStack(spacing: 8) {
            if confirmUninstall {
                Button("Confirm Uninstall", role: .destructive) {
                    onUninstall()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Cancel") {
                    onCancelUninstall()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Button(role: .destructive) {
                    onUninstall()
                } label: {
                    Label("Uninstall", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}

// MARK: - Hub Result Row

private struct HubResultRow: View {
    let result: SkillSearchResult
    let installStatus: String?
    let onInstall: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(result.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.primary)
                if !result.description.isEmpty {
                    Text(result.description)
                        .font(.caption2)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            if let status = installStatus {
                if status == "installing" {
                    ProgressView().controlSize(.small)
                } else if status == "installed" {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.success)
                        .font(.caption)
                }
            } else {
                Button("Install") {
                    onInstall()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .font(.caption)
            }
        }
        .padding(8)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: 8))
    }
}
