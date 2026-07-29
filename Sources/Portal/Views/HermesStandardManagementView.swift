import SwiftUI
import os

private let log = Logger(subsystem: "com.ethenotethan.Portal", category: "HermesStandardManagement")

/// Management dashboard for a Hermes Standard backend. Shown in the main
/// content area when a `.hermesStandard` entry is focused — replaces ChatView
/// because Standard has no chat surface, only management.
///
/// Navigation surface: Sessions, Cron, Notifications, Skills, Settings.
/// Each tab reads from the upstream Hermes dashboard HTTP API via
/// `HermesStandardClient`.
struct HermesStandardManagementView: View {
    let entry: SavedGateway
    @State private var selectedSection: ManagementSection = .sessions
    @State private var client: HermesStandardClient?
    @State private var connectionError: String?
    @State private var isLoading = false

    @State private var sessions: [HermesStandardSession] = []
    @State private var cronJobs: [HermesStandardCronJob] = []
    @State private var skills: [HermesStandardSkill] = []
    @State private var config: [String: AnyCodable] = [:]
    @State private var statusInfo: [String: AnyCodable] = [:]

    enum ManagementSection: String, CaseIterable, Identifiable {
        case sessions, cron, notifications, skills, settings
        var id: String { rawValue }

        var label: String {
            switch self {
            case .sessions: "Sessions"
            case .cron: "Cron"
            case .notifications: "Notifications"
            case .skills: "Skills"
            case .settings: "Settings"
            }
        }

        var icon: String {
            switch self {
            case .sessions: "bubble.left.and.bubble.right"
            case .cron: "clock.badge.checkmark"
            case .notifications: "bell"
            case .skills: "sparkles"
            case .settings: "gearshape"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Section sidebar
            VStack(spacing: 2) {
                ForEach(ManagementSection.allCases) { section in
                    Button {
                        selectedSection = section
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: section.icon)
                                .font(.system(size: 13))
                                .frame(width: 16)
                            Text(section.label)
                                .font(.system(size: 13))
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(selectedSection == section ? Theme.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(selectedSection == section ? Theme.accent : Theme.primary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(8)
            .frame(width: 180)
            .background(Theme.surface)

            Rectangle().fill(Theme.border).frame(width: 1)

            // Content
            VStack(spacing: 0) {
                headerBar
                Divider()
                contentArea
            }
        }
        .background(Theme.background)
        .task { await loadAll() }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.kind.iconName)
                .font(.system(size: 14))
                .foregroundStyle(Theme.accent)
            Text(entry.displayName)
                .font(.system(size: 14, weight: .semibold))
            if let url = URL(string: entry.url), let host = url.host {
                Text(host)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isLoading {
                ProgressView().scaleEffect(0.7)
            }
            Button {
                Task { await loadAll() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help("Refresh")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(height: 42)
    }

    // MARK: - Content dispatch

    @ViewBuilder
    private var contentArea: some View {
        if let error = connectionError {
            errorView(error)
        } else if client == nil {
            VStack(spacing: 8) {
                ProgressView()
                Text("Connecting to \(entry.displayName)…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch selectedSection {
            case .sessions:
                sessionsList
            case .cron:
                cronList
            case .notifications:
                notificationsView
            case .skills:
                skillsList
            case .settings:
                settingsView
            }
        }
    }

    // MARK: - Sessions

    private var sessionsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                if sessions.isEmpty {
                    emptyState("No sessions found")
                } else {
                    ForEach(sessions) { session in
                        sessionRow(session)
                    }
                }
            }
            .padding(12)
        }
    }

    private func sessionRow(_ session: HermesStandardSession) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(session.title ?? "Untitled")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer()
                Text("\(session.messageCount) msgs")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                if session.isActive {
                    Circle().fill(.green).frame(width: 6, height: 6)
                }
            }
            if let preview = session.preview {
                Text(preview)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text(session.id)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Cron

    private var cronList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                if cronJobs.isEmpty {
                    emptyState("No cron jobs")
                } else {
                    ForEach(cronJobs) { job in
                        cronRow(job)
                    }
                }
            }
            .padding(12)
        }
    }

    private func cronRow(_ job: HermesStandardCronJob) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(job.enabled ? .green : .gray)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name)
                    .font(.system(size: 13, weight: .medium))
                Text(job.schedule)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                if let err = job.lastRunError {
                    Text(err)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            Spacer()
            if let status = job.lastRunStatus {
                Text(status)
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(status == "ok" ? Color.green.opacity(0.15) : Color.orange.opacity(0.15), in: Capsule())
            }
            Menu {
                Button("Run now") {
                    Task { await triggerCron(job.id) }
                }
                Button(job.enabled ? "Pause" : "Resume") {
                    Task { await toggleCron(job) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14))
            }
            .menuStyle(.borderlessButton)
        }
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Notifications

    private var notificationsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "bell.slash")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            switch client?.notificationAvailability {
            case .available:
                Text("Live notifications connected")
                    .font(.callout)
            case .unavailable(let reason):
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            case .none:
                Text("Checking notification availability…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Skills

    private var skillsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if skills.isEmpty {
                    emptyState("No skills found")
                } else {
                    ForEach(skills) { skill in
                        skillRow(skill)
                    }
                }
            }
            .padding(12)
        }
    }

    private func skillRow(_ skill: HermesStandardSkill) -> some View {
        HStack(spacing: 10) {
            Image(systemName: skill.enabled ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(skill.enabled ? .green : .secondary)
                .font(.system(size: 13))
            VStack(alignment: .leading, spacing: 1) {
                Text(skill.name)
                    .font(.system(size: 12, weight: .medium))
                if !skill.description.isEmpty {
                    Text(skill.description)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Text(skill.category)
                .font(.system(size: 9, weight: .semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Theme.accent.opacity(0.1), in: Capsule())
        }
        .padding(8)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Settings

    private var settingsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if statusInfo.isEmpty {
                    emptyState("No configuration loaded")
                } else {
                    ForEach(statusInfo.keys.sorted(), id: \.self) { key in
                        configRow(key: key, value: statusInfo[key])
                    }
                }
            }
            .padding(12)
        }
    }

    private func configRow(key: String, value: AnyCodable?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(key)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(describe(value))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.primary)
                .lineLimit(4)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Helpers

    private func describe(_ value: AnyCodable?) -> String {
        guard let value else { return "—" }
        if let s = value.stringValue { return s }
        if let i = value.intValue { return String(i) }
        if let b = value.boolValue { return b ? "true" : "false" }
        if let d = value.dictionaryValue, !d.isEmpty {
            return d.keys.sorted().joined(separator: ", ")
        }
        return "…"
    }

    private func emptyState(_ text: String) -> some View {
        VStack(spacing: 6) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .foregroundStyle(Theme.primary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                connectionError = nil
                Task { await loadAll() }
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data Loading

    private func loadAll() async {
        guard client == nil || connectionError != nil else { return }
        isLoading = true
        defer { isLoading = false }

        guard let url = URL(string: entry.url.trimmingCharacters(in: .whitespaces)),
              !entry.apiKey.isEmpty else {
            connectionError = "Invalid URL or missing session token"
            return
        }

        do {
            let newClient = try HermesStandardClient(
                baseURL: url,
                sessionToken: entry.apiKey
            )
            client = newClient

            // Load all surfaces in parallel
            async let s = newClient.sessions()
            async let c = newClient.cronJobs()
            async let sk = newClient.skills()
            async let st = newClient.status()

            sessions = (try? await s.sessions) ?? []
            cronJobs = (try? await c) ?? []
            skills = (try? await sk) ?? []
            statusInfo = (try? await st) ?? [:]
            connectionError = nil
        } catch {
            connectionError = error.localizedDescription
            log.error("Hermes Standard connect failed: \(error.localizedDescription)")
        }
    }

    private func triggerCron(_ id: String) {
        Task {
            do {
                try await client?.triggerCronJob(id)
                cronJobs = (try? await client?.cronJobs()) ?? cronJobs
            } catch {
                connectionError = error.localizedDescription
            }
        }
    }

    private func toggleCron(_ job: HermesStandardCronJob) {
        Task {
            do {
                try await client?.setCronJob(job.id, enabled: !job.enabled)
                cronJobs = (try? await client?.cronJobs()) ?? cronJobs
            } catch {
                connectionError = error.localizedDescription
            }
        }
    }
}
