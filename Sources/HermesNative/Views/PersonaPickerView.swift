import SwiftUI

/// Popover view for selecting and managing personas.
struct PersonaPickerView: View {
    @EnvironmentObject var personaManager: PersonaManager
    @Environment(\.dismiss) private var dismiss
    @State private var showTemplateExported = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Personas")
                    .font(.headline)
                Spacer()
                Button {
                    if let url = personaManager.exportTemplate() {
                        #if os(macOS)
                        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
                        #endif
                        showTemplateExported = true
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text("New")
                    }
                    .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            Divider()

            // Persona list
            ScrollView {
                LazyVStack(spacing: 8) {
                    if let agentPersona = personaManager.personas.first(where: { $0.isAgentDefault }) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Default")
                                .font(.caption2.weight(.semibold))
                                .textCase(.uppercase)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 10)
                            PersonaRow(
                                persona: agentPersona,
                                isActive: personaManager.usesAgentDefault,
                                subtitleOverride: "Mirrors Hermes Agent config"
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                personaManager.useAgentDefault()
                                dismiss()
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Custom")
                            .font(.caption2.weight(.semibold))
                            .textCase(.uppercase)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 10)

                        ForEach(personaManager.personas.filter { !$0.isAgentDefault }) { persona in
                            PersonaRow(persona: persona, isActive: !personaManager.usesAgentDefault && persona.id == personaManager.activePersona.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    personaManager.select(persona)
                                    dismiss()
                                }
                                .contextMenu {
                                    if !persona.isBuiltIn {
                                        Button("Delete", role: .destructive) {
                                            personaManager.delete(persona)
                                        }
                                    }
                                    #if os(macOS)
                                    Button("Open Personas Folder") {
                                        NSWorkspace.shared.open(PersonaManager.personasDirectory)
                                    }
                                    #endif
                                }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }

            Divider()

            // Footer
            #if os(macOS)
            HStack {
                Text("Drop .json files in ~/HermesNative/Personas/")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Open Folder") {
                    NSWorkspace.shared.open(PersonaManager.personasDirectory)
                }
                .font(.caption2)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            #endif
        }
        #if os(macOS)
        .frame(width: 280, height: 360)
        #else
        .presentationDetents([.medium])
        #endif
        .alert("Template Created", isPresented: $showTemplateExported) {
            Button("OK") {}
        } message: {
            Text("Edit my-persona.json in the Personas folder, then reopen this picker.")
        }
    }
}

// MARK: - Persona Row

struct PersonaRow: View {
    let persona: Persona
    let isActive: Bool
    var subtitleOverride: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            persona.bubbleAvatar(size: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(persona.name)
                    .font(.subheadline)
                    .fontWeight(isActive ? .semibold : .regular)
                Text(subtitleOverride ?? persona.tagline)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isActive {
                Image(systemName: "checkmark")
                    .font(.caption)
                    .foregroundStyle(persona.accentColor)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            isActive ? persona.accentColor.opacity(0.1) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
    }
}
