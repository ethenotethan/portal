import SwiftUI

/// Settings view for gateway connection configuration + persona management.
struct SettingsView: View {
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var personaManager: PersonaManager
    @Environment(\.dismiss) private var dismiss

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
                    // Gateway
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

                    // Persona
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Persona")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)

                        // Active persona
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

                        // Picker
                        ForEach(personaManager.personas) { persona in
                            HStack(spacing: 10) {
                                persona.bubbleAvatar(size: 28)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(persona.name)
                                        .font(.subheadline)
                                    Text(persona.tagline)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if persona.id == personaManager.activePersona.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(persona.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                personaManager.select(persona)
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

            Section {
                Text("The API key is stored in your macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var personaTab: some View {
        Form {
            Section("Active Persona") {
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

            Section("Available Personas") {
                ForEach(personaManager.personas) { persona in
                    HStack(spacing: 10) {
                        persona.bubbleAvatar(size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(persona.name)
                                .font(.subheadline)
                            Text(persona.tagline)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if persona.id == personaManager.activePersona.id {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(persona.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        personaManager.select(persona)
                    }
                }
            }

            Section("Custom Personas") {
                HStack {
                    Text("Drop .json files in:")
                        .font(.caption)
                    Text(PersonaManager.personasDirectory.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Open Folder") {
                        NSWorkspace.shared.open(PersonaManager.personasDirectory)
                    }
                    Button("Create Template") {
                        if let url = personaManager.exportTemplate() {
                            NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
                        }
                    }
                }
            }

            Section("Persona JSON Format") {
                Text("""
                    {
                      "id": "my-persona",
                      "name": "My Persona",
                      "tagline": "A custom AI assistant",
                      "symbolName": "person.fill",
                      "accentColorHex": "#5856D6",
                      "imagePath": null,
                      "systemPromptSuffix": "You are…"
                    }
                    """)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }
    #endif
}
