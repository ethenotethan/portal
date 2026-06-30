import SwiftUI

/// Settings view for gateway connection configuration.
struct SettingsView: View {
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var personaManager: PersonaManager
    @EnvironmentObject var capabilitiesStore: HermesCapabilitiesStore
    @Environment(\.dismiss) private var dismiss
    @State private var showCFAuth = false

    var body: some View {
        #if os(macOS)
        macBody
        #else
        iosBody
        #endif
    }

    // MARK: - macOS

    #if os(macOS)
    private var macBody: some View {
        TabView {
            connectionTab
                .tabItem {
                    Label("Connection", systemImage: "network")
                }

            personaTab
                .tabItem {
                    Label("Persona", systemImage: "person.crop.circle")
                }
        }
        .frame(width: 500, height: 450)
    }
    #endif

    // MARK: - iOS

    #if os(iOS)
    private var iosBody: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Gateway URL")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        TextField("ws://192.168.1.x:8642/v1/ws", text: $settings.gatewayURL)
                            .textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .font(.body)

                        Text("API Key")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .padding(.top, 4)
                        SecureField("Optional", text: $settings.apiKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.body)
                    }

                    if settings.savedGateways.count > 1 {
                        Divider()
                        iosGatewaySwitcher
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Notifications")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)

                        Toggle("Response complete", isOn: $settings.responseCompleteNotificationsEnabled)
                        Text("Notify when a response finishes while the app is in the background or another session is active.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    Divider()

                    capabilitiesSummary

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Persona")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)

                        HStack(spacing: 12) {
                            personaManager.activePersona.bubbleAvatar(size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(personaManager.activePersona.name)
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                Text(personaManager.activePersona.tagline)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Text("The API key is stored securely on this device.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
    #endif

    #if os(iOS)
    private var iosGatewaySwitcher: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Gateways")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            ForEach(settings.savedGateways) { gateway in
                Button {
                    settings.selectGateway(gateway)
                } label: {
                    HStack {
                        Image(systemName: settings.isActive(gateway) ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(settings.isActive(gateway) ? Theme.accent : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(gateway.displayName)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(gateway.url)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
    #endif

    private var capabilitiesSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
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

    // MARK: - Shared Tab Content (macOS)

    #if os(macOS)
    @State private var showAddGateway = false

    private var connectionTab: some View {
        Form {
            Section("Gateway Connection") {
                TextField("Gateway URL", text: $settings.gatewayURL)
                    .textFieldStyle(.roundedBorder)
                SecureField("API Key", text: $settings.apiKey)
                    .textFieldStyle(.roundedBorder)
            }

            Section {
                ForEach(settings.savedGateways) { gateway in
                    HStack {
                        Image(systemName: settings.isActive(gateway) ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(settings.isActive(gateway) ? Theme.accent : Theme.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(gateway.displayName)
                                .lineLimit(1)
                            Text(gateway.url)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if !settings.isActive(gateway) {
                            Button("Switch") { settings.selectGateway(gateway) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                        Button(role: .destructive) {
                            settings.removeGateway(gateway)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .disabled(settings.savedGateways.count <= 1)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { settings.selectGateway(gateway) }
                }
            } header: {
                HStack {
                    Text("Saved Gateways")
                    Spacer()
                    Button {
                        showAddGateway = true
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                }
            }

            if settings.needsCFAuth {
                Section("Cloudflare Access") {
                    HStack {
                        if let email = settings.cfAuthEmail {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(email)
                                .lineLimit(1)
                        } else if settings.cfAuthCookie != nil {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Authenticated")
                        } else {
                            Image(systemName: "lock.shield")
                                .foregroundStyle(.secondary)
                            Text("Not authenticated")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(settings.cfAuthCookie != nil ? "Re-auth" : "Sign In") {
                            showCFAuth = true
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            Section("Notifications") {
                Toggle("Response complete", isOn: $settings.responseCompleteNotificationsEnabled)
                Text("Notify when a response finishes while the app is in the background or another session is active.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Gateway Capabilities") {
                capabilitiesSummary
            }

            Section {
                Text("The API key is stored in your macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
        .sheet(isPresented: $showAddGateway) {
            AddGatewaySheet { name, url, key in
                settings.addGateway(name: name, url: url, apiKey: key)
                showAddGateway = false
            } onCancel: {
                showAddGateway = false
            }
        }
    }

    private var personaTab: some View {
        Form {
            Section("Gateway Persona") {
                HStack(spacing: 12) {
                    personaManager.activePersona.bubbleAvatar(size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(personaManager.activePersona.name)
                            .font(.headline)
                        Text(personaManager.activePersona.tagline)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let suffix = personaManager.activePersona.systemPromptSuffix,
               !suffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section("Persona Prompt (from PERSONA.md)") {
                    Text(suffix)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }
    #endif
}

#if os(macOS)
/// Sheet for adding a new saved gateway.
private struct AddGatewaySheet: View {
    let onAdd: (_ name: String, _ url: String, _ apiKey: String) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @State private var url = ""
    @State private var apiKey = ""

    private var canAdd: Bool {
        !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("New Gateway") {
                    TextField("Name (optional)", text: $name)
                        .textFieldStyle(.roundedBorder)
                    TextField("Gateway URL", text: $url)
                        .textFieldStyle(.roundedBorder)
                    SecureField("API Key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    onAdd(
                        name.trimmingCharacters(in: .whitespacesAndNewlines),
                        url.trimmingCharacters(in: .whitespacesAndNewlines),
                        apiKey
                    )
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd)
            }
            .padding(12)
        }
        .frame(width: 420, height: 320)
    }
}
#endif

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
