import SwiftUI

/// Horizontal strip of intent buttons rendered as trusted SwiftUI chrome above
/// an HTML document. The artifact never receives gateway credentials or an
/// arbitrary command surface.
internal struct ArtifactTopLevelActionBar: View {
    internal let actions: [ArtifactAction]
    internal let artifactID: String

    @EnvironmentObject private var capabilitiesStore: GatewayCapabilitiesStore

    private var intentActions: [ArtifactAction] {
        guard capabilitiesStore.capabilities.supportsArtifactActions else { return [] }
        return actions.filter { $0.kind == .intent }
    }

    internal var body: some View {
        if !intentActions.isEmpty {
            HStack(spacing: 8) {
                ForEach(intentActions) { action in
                    // Artifact-level intents use an empty entry key because
                    // they operate on the artifact, not a specific row.
                    IntentButton(action: action, entryKey: "", artifactID: artifactID)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.surface)
            .overlay(alignment: .bottom) {
                Divider().overlay(Theme.border.opacity(0.5))
            }
        }
    }
}
