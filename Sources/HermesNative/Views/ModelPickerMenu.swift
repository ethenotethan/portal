import SwiftUI

/// Drop-down for the session's model — replaces the static model badge in
/// the chat toolbars. Lists the curated `AgentModel.catalog` with a checkmark
/// on the session's reported model; a model the gateway reports that isn't
/// in the catalog is shown checked at the top so the truth is never hidden.
/// Falls back to the plain badge when the backend can't switch models
/// (Centaur) or no session is active yet.
struct ModelPickerMenu: View {
    @EnvironmentObject var chatViewModel: ChatViewModel

    private var currentModel: String { chatViewModel.currentModel }

    private var badgeLabel: String {
        currentModel.isEmpty ? "No model" : AgentModel.displayName(for: currentModel)
    }

    /// The reported model when it isn't one of the catalog entries.
    private var offCatalogModel: String? {
        guard !currentModel.isEmpty,
              !AgentModel.catalog.contains(where: { $0.matches(sessionModel: currentModel) })
        else { return nil }
        return currentModel
    }

    private var canSwitch: Bool {
        chatViewModel.backendCapabilities.supportsModelSwitching
            && chatViewModel.isSessionReady
            && !chatViewModel.isStreaming
    }

    var body: some View {
        if canSwitch {
            Menu {
                if let offCatalog = offCatalogModel {
                    Label(AgentModel.displayName(for: offCatalog), systemImage: "checkmark")
                    Divider()
                }
                ForEach(AgentModel.catalog) { model in
                    Button {
                        Task { await chatViewModel.switchModel(model.id) }
                    } label: {
                        if model.matches(sessionModel: currentModel) {
                            Label(model.label, systemImage: "checkmark")
                        } else {
                            Text(model.label)
                        }
                    }
                }
            } label: {
                badge(withChevron: true)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help("Model: \(currentModel.isEmpty ? "gateway default" : currentModel). Click to switch this session's model.")
        } else {
            badge(withChevron: false)
                .help(chatViewModel.backendCapabilities.supportsModelSwitching
                      ? "Model switching is unavailable while a turn is streaming"
                      : "This backend does not support model switching")
        }
    }

    private func badge(withChevron: Bool) -> some View {
        HStack(spacing: 3) {
            Text(badgeLabel)
            if withChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(0.6), in: Capsule())
    }
}
