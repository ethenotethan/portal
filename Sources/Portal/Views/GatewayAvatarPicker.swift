import SwiftUI
import UniformTypeIdentifiers

/// The persona avatar for a saved gateway, with controls to upload a custom
/// picture or reset to the generated identicon. The gateway's name is the
/// persona name; this is that persona's face.
///
/// Persists by copying the chosen image into `~/.hermes/images` (via
/// `PersonaImage`) and writing the returned path onto the gateway through
/// `SettingsViewModel.updateGateway`, which re-persists the Keychain list and
/// fires the `savedGateways` change that re-adopts the live persona.
internal struct GatewayAvatarPicker: View {
    internal let gateway: SavedGateway
    @EnvironmentObject private var settings: SettingsViewModel

    @State private var showImporter = false

    /// The persona this gateway represents — same builder the chat chrome uses,
    /// so the picker preview matches exactly what appears in the header.
    private var persona: Persona { PersonaManager.persona(for: gateway) }

    internal init(gateway: SavedGateway) {
        self.gateway = gateway
    }

    internal var body: some View {
        HStack(spacing: 14) {
            persona.bubbleAvatar(size: 56)
                .overlay(Circle().strokeBorder(Theme.border.opacity(0.4), lineWidth: 1))

            VStack(alignment: .leading, spacing: 4) {
                Text("Persona avatar")
                    .font(.headline)
                Text(gateway.avatarImagePath == nil
                     ? "Generated from this gateway. Upload a picture to personalize it."
                     : "Custom picture. Reset to use the generated identicon.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button("Upload…") { showImporter = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    if gateway.avatarImagePath != nil {
                        Button("Reset") { resetAvatar() }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                    }
                }
            }
            Spacer()
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result, let source = urls.first else { return }
        // Security-scoped access: a file the sandbox handed us via the importer
        // must be opened inside a start/stop access pair before we can copy it.
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard let stored = PersonaImage.store(fileURL: source) else { return }
        setAvatar(path: stored)
    }

    private func setAvatar(path: String) {
        var updated = gateway
        // Clear a previously-stored image so we don't orphan files on disk.
        PersonaImage.remove(path: gateway.avatarImagePath)
        updated.avatarImagePath = path
        settings.updateGateway(updated)
    }

    private func resetAvatar() {
        var updated = gateway
        PersonaImage.remove(path: gateway.avatarImagePath)
        updated.avatarImagePath = nil
        settings.updateGateway(updated)
    }
}
