import SwiftUI

/// Settings view for gateway connection configuration + persona management.
struct SettingsView: View {
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var personaManager: PersonaManager

    var body: some View {
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
        #if os(macOS)
        .frame(width: 500, height: 450)
        #endif
    }

    // MARK: - Connection Tab

    private var connectionTab: some View {
        Form {
            Section("Gateway Connection") {
                TextField("Gateway URL", text: $settings.gatewayURL)
                    .textFieldStyle(.roundedBorder)
                SecureField("API Key", text: $settings.apiKey)
                    .textFieldStyle(.roundedBorder)
            }

            Section {
                #if os(macOS)
                Text("The API key is stored in your macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #else
                Text("The API key is stored securely on this device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Persona Tab

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

            #if os(macOS)
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
            #endif
        }
        .formStyle(.grouped)
    }
}
