// swiftlint:disable file_length
import SwiftUI
import os

private let log = Logger(subsystem: "com.ethenotethan.Portal", category: "SettingsView")

/// Full-window settings overlay. Sections are listed in a sidebar and
/// render into the main pane — same pattern as macOS System Settings.
/// Replaces the old 500×450 TabView sheet.
internal struct SettingsView: View {
    @EnvironmentObject internal var settings: SettingsViewModel
    @EnvironmentObject internal var personaManager: PersonaManager
    @EnvironmentObject internal var capabilitiesStore: GatewayCapabilitiesStore
    @EnvironmentObject internal var gatewayClientWrapper: GatewayClientWrapper
    @ObservedObject private var themeManager = ThemeManager.shared

    /// Unified sidebar selection — app sections plus one entry per gateway.
    internal enum SidebarItem: Hashable, Identifiable {
        case appearance
        case persona
        case notifications
        case gateway(SavedGateway)

        internal var id: AnyHashable {
            switch self {
            case .appearance: return "appearance"
            case .persona: return "persona"
            case .notifications: return "notifications"
            case .gateway(let g): return g.id
            }
        }

        internal var label: String {
            switch self {
            case .appearance: return "Appearance"
            case .persona: return "Persona"
            case .notifications: return "Notifications"
            case .gateway(let g): return g.displayName
            }
        }

        internal var icon: String {
            switch self {
            case .appearance: return "paintpalette"
            case .persona: return "person.crop.circle"
            case .notifications: return "bell"
            case .gateway(let g): return g.kind.isSessionScoped ? g.kind.iconName : "server.rack"
            }
        }
    }

    @State private var selection: SidebarItem = .appearance

    internal var body: some View {
        #if os(macOS)
        macBody
            .onChange(of: settings.savedGateways) {
                // If the selected gateway was deleted, fall back to appearance.
                if case .gateway(let g) = selection,
                   !settings.savedGateways.contains(g) {
                    selection = .appearance
                }
            }
        #else
        iosBody
        #endif
    }

    // MARK: - macOS

    #if os(macOS)
    private var macBody: some View {
        HStack(spacing: 0) {
            // Sidebar
            VStack(alignment: .leading, spacing: 0) {
                sidebarGroup(header: nil, items: [.appearance, .persona, .notifications])

                Divider().padding(.vertical, 8)

                // Gateways section
                Text("Gateways")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 4)

                ForEach(settings.savedGateways) { gateway in
                    sidebarRow(.gateway(gateway))
                }

                Button {
                    showAddGateway = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "plus")
                            .font(.system(size: 12))
                            .frame(width: 18)
                            .foregroundStyle(Theme.secondary)
                        Text("Add Gateway")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 16)
            .frame(width: 210)
            .background(Theme.surface.opacity(0.5))

            Rectangle().fill(Theme.border).frame(width: 1)

            // Main pane
            ScrollView {
                Group {
                    switch selection {
                    case .appearance:
                        themesSection
                    case .persona:
                        personaSection
                    case .notifications:
                        notificationsSection
                    case .gateway(let g):
                        GatewayDetailPane(gateway: g)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .sheet(isPresented: $showAddGateway) {
            AddGatewaySheet { name, url, key, kind in
                let gw = settings.addGateway(name: name, url: url, apiKey: key, kind: kind)
                selection = .gateway(gw)
                showAddGateway = false
            } onCancel: {
                showAddGateway = false
            }
        }
    }

    @ViewBuilder
    private func sidebarGroup(header: String?, items: [SidebarItem]) -> some View {
        if let header {
            Text(header)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, 14)
                .padding(.bottom, 4)
        }
        ForEach(items) { item in
            sidebarRow(item)
        }
    }

    @ViewBuilder
    private func sidebarRow(_ item: SidebarItem) -> some View {
        let isSelected = selection == item
        Button { selection = item } label: {
            HStack(spacing: 10) {
                Image(systemName: item.icon)
                    .font(.system(size: 13))
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Theme.accent : Theme.secondary)
                Text(item.label)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? Theme.primary : Theme.secondary)
                Spacer(minLength: 0)
                if case .gateway(let g) = item, settings.isActive(g), !g.kind.isSessionScoped {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                isSelected ? Theme.accent.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - macOS Sections

    @State private var showAddGateway = false

    private var themesSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsHeader("Themes", icon: "paintpalette")

            Text("Choose a color scheme. Changes apply instantly across the entire app.")
                .font(.caption)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: 160), spacing: 16)
            ], spacing: 16) {
                ForEach(AppTheme.allCases) { theme in
                    themeCard(theme)
                }
            }
        }
    }

    @ViewBuilder
    private func themeCard(_ theme: AppTheme) -> some View {
        let isSelected = themeManager.current.id == theme.id
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                themeManager.select(theme)
            }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                // Color preview strip
                HStack(spacing: 0) {
                    ForEach(theme.swatches, id: \.self) { hex in
                        Rectangle()
                            .fill(Color(hex: hex) ?? .gray)
                    }
                }
                .frame(height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(theme.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.primary)
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    Text(theme.description)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.top, 8)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? Theme.accent : Theme.border, lineWidth: isSelected ? 2 : 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var personaSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsHeader("Persona", icon: "person.crop.circle")

            HStack(spacing: 14) {
                personaManager.activePersona.bubbleAvatar(size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(personaManager.activePersona.name)
                        .font(.title3.weight(.semibold))
                    Text(personaManager.activePersona.tagline)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if let suffix = personaManager.activePersona.systemPromptSuffix,
               !suffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Persona Prompt (from PERSONA.md)")
                        .font(.headline)
                    ScrollView {
                        Text(suffix)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 240)
                    .padding(12)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                }
            } else {
                Text("The agent's persona is set by the gateway. Add a PERSONA.md to your gateway to customise the agent name, tagline, and system prompt suffix.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsHeader("Notifications", icon: "bell")

            Toggle("Response complete", isOn: $settings.responseCompleteNotificationsEnabled)
            Text("Notify when a response finishes while the app is in the background or another session is active.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
            APNsStatusRow()
        }
    }

    // MARK: - Shared helpers

    @ViewBuilder
    private func settingsHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(Theme.accent)
            Text(title)
                .font(.title2.weight(.semibold))
        }
    }

    @ViewBuilder
    private func labeledField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
    }

    #endif
}

// MARK: - Gateway Detail Pane

#if os(macOS)
/// Per-gateway settings pane. Shown in the main area when a gateway is
/// selected in the sidebar. Hermes gateways additionally show System Prompt.
private struct GatewayDetailPane: View {
    let gateway: SavedGateway

    @EnvironmentObject private var settings: SettingsViewModel
    @EnvironmentObject private var capabilitiesStore: GatewayCapabilitiesStore
    @EnvironmentObject private var gatewayClientWrapper: GatewayClientWrapper

    @State private var editingGateway: SavedGateway?
    @State private var showCFAuth = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header row
            HStack(spacing: 12) {
                Image(systemName: gateway.kind.isSessionScoped ? gateway.kind.iconName : "server.rack")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(gateway.displayName)
                            .font(.title2.weight(.semibold))
                        if gateway.kind.isSessionScoped {
                            Text(gateway.kind.displayName)
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Theme.accent.opacity(0.15), in: Capsule())
                                .foregroundStyle(Theme.accent)
                        } else if settings.isActive(gateway) {
                            Text("Active")
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Theme.success.opacity(0.15), in: Capsule())
                                .foregroundStyle(Theme.success)
                        }
                    }
                    Text(gateway.url)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if !gateway.kind.isSessionScoped, !settings.isActive(gateway) {
                    Button("Make Active") { settings.selectGateway(gateway) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Button { editingGateway = gateway } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Edit name, URL, or API key")

                Button(role: .destructive) {
                    settings.removeGateway(gateway)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(!gateway.kind.isSessionScoped && settings.hermesBackends.count <= 1)
                .help("Remove this gateway")
            }

            Divider()

            // API key presence indicator
            if !gateway.apiKey.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "key.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                    Text("API key configured")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Cloudflare Access (Hermes, when gateway requires it)
            if !gateway.kind.isSessionScoped && settings.needsCFAuth {
                Divider()
                cfAuthRow
            }

            // Capabilities summary
            if !gateway.kind.isSessionScoped {
                Divider()
                capabilitiesSummary

                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Thought Graph")
                        .font(.headline)
                    Toggle("Experimental: MLX reasoning model", isOn: $settings.mlxReasoningEnabled)
                    Text("Uses an on-device model (Gemma 3 1B, ~600MB download) to extract reasoning decisions. The default heuristic extractor is faster and needs no download.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Changes take effect on the next session.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Divider()
                SystemPromptSection(
                    client: gatewayClientWrapper.client,
                    sessionID: nil
                )
            }
        }
        .sheet(item: $editingGateway) { gw in
            AddGatewaySheet(editing: gw) { name, url, key, _ in
                var updated = gw
                updated.name = name
                updated.url = url
                updated.apiKey = key
                settings.updateGateway(updated)
                editingGateway = nil
            } onCancel: {
                editingGateway = nil
            }
        }
        .sheet(isPresented: $showCFAuth) {
            if let host = settings.buildWebSocketURL()?.host {
                CFAuthView(gatewayHost: host) { cookie in
                    settings.cfAuthCookie = cookie
                    settings.parseCFAuthEmail(from: cookie)
                    showCFAuth = false
                } onDismiss: {
                    showCFAuth = false
                }
            }
        }
    }

    private var cfAuthRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cloudflare Access")
                .font(.headline)
            HStack {
                if let email = settings.cfAuthEmail {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(email).lineLimit(1)
                } else if settings.cfAuthCookie != nil {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Authenticated")
                } else {
                    Image(systemName: "lock.shield").foregroundStyle(.secondary)
                    Text("Not authenticated").foregroundStyle(.secondary)
                }
                Spacer()
                Button(settings.cfAuthCookie != nil ? "Re-auth" : "Sign In") {
                    showCFAuth = true
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var capabilitiesSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Capabilities")
                .font(.headline)
            HStack {
                Label(
                    capabilitiesStore.capabilities.statusDisplay,
                    systemImage: capabilitiesStore.isRefreshing ? "arrow.triangle.2.circlepath" : "checkmark.seal"
                )
                .foregroundStyle(capabilitiesStore.isRefreshing ? Theme.warning : Theme.success)
                Spacer()
                Text("Version: \(capabilitiesStore.capabilities.versionDisplay)")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)

            HStack(spacing: 8) {
                CapabilityPill(title: "Image input", isEnabled: capabilitiesStore.hasImageInput)
                CapabilityPill(title: "ACP image prompts", isEnabled: capabilitiesStore.hasACPImagePrompts)
            }

            if case .fallback(let reason) = capabilitiesStore.capabilities.source {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
#endif

extension SettingsView {

    // Shared across platforms — used by both the macOS and iOS Settings bodies.
    var capabilitiesSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Gateway Capabilities")
                .font(.headline)
            HStack {
                Label(capabilitiesStore.capabilities.statusDisplay, systemImage: capabilitiesStore.isRefreshing ? "arrow.triangle.2.circlepath" : "checkmark.seal")
                    .foregroundStyle(capabilitiesStore.isRefreshing ? Theme.warning : Theme.success)
                Spacer()
                Text("Version: \(capabilitiesStore.capabilities.versionDisplay)")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)

            HStack(spacing: 8) {
                CapabilityPill(title: "Image input", isEnabled: capabilitiesStore.hasImageInput)
                CapabilityPill(title: "ACP image prompts", isEnabled: capabilitiesStore.hasACPImagePrompts)
            }

            if case .fallback(let reason) = capabilitiesStore.capabilities.source {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - iOS

    #if os(iOS)
    var iosBody: some View {
        NavigationStack {
            List {
                Section("Connection") {
                    TextField("Gateway URL", text: $settings.gatewayURL)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("API Key", text: $settings.apiKey)
                        .textFieldStyle(.roundedBorder)

                    if settings.savedGateways.count > 1 {
                        ForEach(settings.savedGateways) { gateway in
                            Button {
                                settings.selectGateway(gateway)
                            } label: {
                                HStack {
                                    Image(systemName: settings.isActive(gateway) ? "largecircle.fill.circle" : "circle")
                                        .foregroundStyle(settings.isActive(gateway) ? Theme.accent : .secondary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(gateway.displayName)
                                        Text(gateway.url)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section("System Prompt") {
                    NavigationLink {
                        SystemPromptSection(client: gatewayClientWrapper.client, sessionID: nil)
                    } label: {
                        Label("View & Edit System Prompt", systemImage: "doc.text.magnifyingglass")
                    }
                }

                Section("Themes") {
                    ForEach(AppTheme.allCases) { theme in
                        Button {
                            themeManager.select(theme)
                        } label: {
                            HStack {
                                HStack(spacing: 2) {
                                    ForEach(theme.swatches, id: \.self) { hex in
                                        Circle()
                                            .fill(Color(hex: hex) ?? .gray)
                                            .frame(width: 14, height: 14)
                                    }
                                }
                                Text(theme.displayName)
                                Spacer()
                                if themeManager.current.id == theme.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section("Notifications") {
                    Toggle("Response complete", isOn: $settings.responseCompleteNotificationsEnabled)
                    APNsStatusRow()
                }

                Section("Capabilities") {
                    capabilitiesSummary
                }

                if let suffix = personaManager.activePersona.systemPromptSuffix,
                   !suffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section("Persona") {
                        HStack {
                            personaManager.activePersona.bubbleAvatar(size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(personaManager.activePersona.name)
                                    .fontWeight(.semibold)
                                Text(personaManager.activePersona.tagline)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section {
                    Text("The API key is stored securely on this device.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    #endif
}

// MARK: - System Prompt Section

/// Fetches the full system prompt via `session.prompt_breakdown` RPC and
/// shows each section in an expandable list. The user can set an ephemeral
/// override via `session.set_prompt` which is appended to every API call
/// but not persisted to trajectories.
internal struct SystemPromptSection: View {
    internal let client: GatewayClient?
    internal let sessionID: String?

    @State private var breakdown: PromptBreakdown?
    @State private var ephemeralPrompt = ""
    @State private var originalEphemeralPrompt = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var expandedSections: Set<String> = []
    @State private var showSaveSuccess = false

    internal var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.accent)
                Text("System Prompt")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button {
                    Task { await loadPrompt() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }

            if isLoading {
                HStack {
                    ProgressView()
                    Text("Loading system prompt…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 40)
            } else if let error = errorMessage {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title)
                        .foregroundStyle(Theme.warning)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") { Task { await loadPrompt() } }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 40)
            } else if let breakdown {
                // Token summary
                promptTokenSummary(breakdown)

                // Prompt sections
                VStack(alignment: .leading, spacing: 12) {
                    Text("Prompt Sections")
                        .font(.headline)
                    ForEach(breakdown.sortedSections) { section in
                        promptSectionCard(section)
                    }
                }

                // Ephemeral prompt editor
                ephemeralPromptEditor
            } else {
                ContentUnavailableView(
                    "No System Prompt Loaded",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Tap Refresh to load the current system prompt from the gateway.")
                )
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 40)
            }
        }
        .task {
            await loadPrompt()
        }
    }

    @ViewBuilder
    private func promptTokenSummary(_ breakdown: PromptBreakdown) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Token Usage")
                .font(.headline)

            HStack(spacing: 16) {
                statTile("System", value: breakdown.totalSystemTokens, color: Theme.accent)
                statTile("Tools", value: breakdown.toolDefinitionsTokenCount, color: Theme.warning)
                statTile("History", value: breakdown.conversationHistoryTokenCount, color: Theme.success)
                statTile("Free", value: breakdown.freeTokens, color: Theme.secondary)
            }

            // Context utilization bar
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("\(breakdown.totalUsedTokens) / \(breakdown.contextLimit) tokens")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.1f%%", breakdown.utilizationPercent))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(breakdown.utilizationPercent > 85 ? Theme.warning : Theme.accent)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Theme.surfaceHover)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(breakdown.utilizationPercent > 85 ? Theme.warning : Theme.accent)
                            .frame(width: geo.size.width * min(breakdown.utilizationPercent / 100, 1.0))
                    }
                }
                .frame(height: 6)
            }

            if !breakdown.model.isEmpty {
                Text("Model: \(breakdown.model)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func statTile(_ label: String, value: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.formatted())
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func promptSectionCard(_ section: PromptSection) -> some View {
        let isExpanded = expandedSections.contains(section.id)

        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if isExpanded {
                        expandedSections.remove(section.id)
                    } else {
                        expandedSections.insert(section.id)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(section.color)
                        .frame(width: 4)

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Text(section.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)

                    Spacer()

                    Text("\(section.tokenCount) tok")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)

                    if !section.source.isEmpty {
                        Text(section.source)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                ScrollView {
                    Text(section.fullContent.isEmpty ? "(empty)" : section.fullContent)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                }
                .frame(maxHeight: 300)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .transition(.opacity)
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.border, lineWidth: 1)
        )
    }

    private var ephemeralPromptEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ephemeral Prompt Override")
                .font(.headline)

            Text("Appended to every API call for this session, but not persisted to trajectories. Setting empty clears the override.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $ephemeralPrompt)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 100)
                .padding(8)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.border, lineWidth: 1)
                )
                .scrollContentBackground(.hidden)

            HStack {
                if showSaveSuccess {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.success)
                        .transition(.opacity)
                }
                Spacer()
                Button("Clear") {
                    ephemeralPrompt = ""
                    Task { await savePrompt() }
                }
                .buttonStyle(.bordered)
                .disabled(originalEphemeralPrompt.isEmpty && ephemeralPrompt.isEmpty)

                Button("Apply") {
                    Task { await savePrompt() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(ephemeralPrompt == originalEphemeralPrompt)
            }
        }
    }

    // MARK: - Data

    private func loadPrompt() async {
        guard let client else {
            errorMessage = "Not connected to a gateway."
            return
        }
        isLoading = true
        errorMessage = nil

        do {
            // If no session ID is provided, try to use the first active session.
            let sid: String?
            if let sessionID {
                sid = sessionID
            } else {
                sid = await firstActiveSessionID(client: client)
            }
            guard let sid else {
                errorMessage = "No active session. Send a message first, then refresh."
                isLoading = false
                return
            }

            let result = try await client.promptBreakdown(sessionID: sid)
            await MainActor.run {
                breakdown = result
                // Extract the current ephemeral prompt if one exists.
                if let ephemeral = result.sections.first(where: { $0.name.lowercased().contains("ephemeral") }) {
                    ephemeralPrompt = ephemeral.fullContent
                    originalEphemeralPrompt = ephemeral.fullContent
                }
                isLoading = false
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    private func firstActiveSessionID(client: GatewayClient) async -> String? {
        do {
            return try await client.listSessions().first?.id
        } catch {
            log.warning("Unable to list sessions for system prompt settings: \(error.localizedDescription)")
            return nil
        }
    }

    private func savePrompt() async {
        guard let client else {
            errorMessage = "Not connected to a gateway."
            return
        }
        let sid: String?
        if let sessionID {
            sid = sessionID
        } else {
            sid = await firstActiveSessionID(client: client)
        }
        guard let sid else {
            errorMessage = "No active session to apply the override to."
            return
        }

        do {
            try await client.setEphemeralPrompt(sessionID: sid, prompt: ephemeralPrompt)
            await MainActor.run {
                originalEphemeralPrompt = ephemeralPrompt
                withAnimation {
                    showSaveSuccess = true
                }
                Task {
                    do {
                        try await Task.sleep(for: .seconds(2))
                    } catch {
                        return
                    }
                    await MainActor.run {
                        withAnimation {
                            showSaveSuccess = false
                        }
                    }
                }
                // Reload to show the updated prompt.
                Task { await loadPrompt() }
            }
            log.info("Ephemeral prompt saved for session \(sid)")
        } catch {
            await MainActor.run {
                errorMessage = "Failed to save: \(error.localizedDescription)"
            }
        }
    }
}

#if os(macOS)
/// Sheet for adding a new saved gateway or editing an existing one (rename,
/// change URL/key). Presented from Settings and the toolbar gateway switcher.
internal struct AddGatewaySheet: View {
    /// When set, the sheet edits this gateway in place instead of adding.
    internal var editing: SavedGateway?
    internal let onAdd: (_ name: String, _ url: String, _ apiKey: String, _ kind: BackendKind) -> Void
    internal let onCancel: () -> Void

    @State private var name = ""
    @State private var url = ""
    @State private var apiKey = ""
    @State private var kind: BackendKind = .hermes

    private var canSave: Bool {
        !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    internal var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(editing == nil ? "New Backend" : "Edit Backend") {
                    Picker("Type", selection: $kind) {
                        ForEach(BackendKind.allCases, id: \.self) { k in
                            Text(k.displayName).tag(k)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(editing != nil)
                    TextField("Name (optional)", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("gatewayNameField")
                    TextField(kind.urlFieldLabel, text: $url)
                        .textFieldStyle(.roundedBorder)
                    SecureField(kind.keyFieldLabel, text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                    if let footnote = kind.sessionScopedFootnote {
                        Text(footnote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(editing == nil ? "Add" : "Save") {
                    onAdd(
                        name.trimmingCharacters(in: .whitespacesAndNewlines),
                        url.trimmingCharacters(in: .whitespacesAndNewlines),
                        apiKey,
                        kind
                    )
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding(12)
        }
        .frame(width: 420, height: 320)
        .onAppear {
            if let gateway = editing {
                name = gateway.name
                url = gateway.url
                apiKey = gateway.apiKey
                kind = gateway.kind
            }
        }
    }
}
#endif

/// Remote-push (APNs) status: whether this device has an OS-granted push
/// token and whether the connected gateway has APNs credentials.
internal struct APNsStatusRow: View {
    @ObservedObject private var push = PushRegistrationService.shared

    private enum PushState {
        case active
        case gatewayUnconfigured
        case noDeviceToken

        var icon: String {
            switch self {
            case .active: return "checkmark.circle.fill"
            case .gatewayUnconfigured: return "exclamationmark.circle"
            case .noDeviceToken: return "bell.slash"
            }
        }

        var color: Color {
            switch self {
            case .active: return Theme.success
            case .gatewayUnconfigured: return Theme.warning
            case .noDeviceToken: return Theme.secondary
            }
        }

        var label: String {
            switch self {
            case .active: return "Remote push active"
            case .gatewayUnconfigured: return "Remote push: gateway not configured"
            case .noDeviceToken: return "Remote push off (no device token)"
            }
        }

        var detail: String {
            switch self {
            case .active:
                return "Approvals, turn completions, and cron results are pushed via APNs even when the app is closed."
            case .gatewayUnconfigured:
                return "This device registered its token, but the gateway has no APNs credentials (APNS_* env vars). See docs/apns-setup.md."
            case .noDeviceToken:
                return "The OS hasn't granted a push token — expected without the push entitlement. "
                    + "Local notifications still work while the app runs. See docs/apns-setup.md."
            }
        }
    }

    private var state: PushState {
        guard push.deviceTokenHex != nil else { return .noDeviceToken }
        return push.gatewayAPNsConfigured == true ? .active : .gatewayUnconfigured
    }

    internal var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: state.icon)
                    .foregroundStyle(state.color)
                Text(state.label)
            }
            Text(state.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("apnsStatusRow")
    }
}

private struct CapabilityPill: View {
    let title: String
    let isEnabled: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isEnabled ? "checkmark.circle.fill" : "minus.circle")
            Text(title)
        }
        .font(.caption2)
        .foregroundStyle(isEnabled ? Theme.success : Theme.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Theme.surfaceHover, in: Capsule())
    }
}
