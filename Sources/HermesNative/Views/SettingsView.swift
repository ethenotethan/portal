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
    private var connectionTab: some View {
        Form {
            Section("Gateway Connection") {
                TextField("Gateway URL", text: $settings.gatewayURL)
                    .textFieldStyle(.roundedBorder)
                SecureField("API Key", text: $settings.apiKey)
                    .textFieldStyle(.roundedBorder)
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
