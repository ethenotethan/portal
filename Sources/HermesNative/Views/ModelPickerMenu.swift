import SwiftUI

/// Drop-down for the session's model — replaces the static model badge in
/// the chat toolbars. Prefers the gateway's live inventory (model.options:
/// providers with curated model lists) and falls back to the static
/// `AgentModel.catalog` on gateways that predate the RPC. A model the
/// gateway reports that isn't in either list is shown checked at the top so
/// the truth is never hidden. Falls back to the plain badge when the backend
/// can't switch models (Centaur) or no session is active yet.
///
/// Expensive models: the gateway can gate a switch behind confirmation;
/// the ViewModel publishes `pendingModelConfirmation` and this view asks.
struct ModelPickerMenu: View {
    @EnvironmentObject var chatViewModel: ChatViewModel

    private var currentModel: String { chatViewModel.currentModel }

    private var badgeLabel: String {
        currentModel.isEmpty ? "No model" : AgentModel.displayName(for: currentModel)
    }

    /// Wire IDs offered by the menu (live catalog or static fallback).
    private var offeredModelIDs: Set<String> {
        if let catalog = chatViewModel.modelCatalog {
            return Set(catalog.allModelIDs.map(AgentModel.normalize))
        }
        return Set(AgentModel.catalog.map { AgentModel.normalize($0.id) })
    }

    /// The reported model when it isn't in the offered list.
    private var offCatalogModel: String? {
        guard !currentModel.isEmpty,
              !offeredModelIDs.contains(AgentModel.normalize(currentModel))
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
                menuContent
            } label: {
                badge(withChevron: true)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help("Model: \(currentModel.isEmpty ? "gateway default" : currentModel). Click to switch this session's model.")
            .task {
                await chatViewModel.refreshModelCatalog()
            }
            .confirmationDialog(
                chatViewModel.pendingModelConfirmation?.message ?? "",
                isPresented: Binding(
                    get: { chatViewModel.pendingModelConfirmation != nil },
                    set: { if !$0 { chatViewModel.pendingModelConfirmation = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let confirmation = chatViewModel.pendingModelConfirmation {
                    Button("Switch to \(AgentModel.displayName(for: confirmation.model))") {
                        chatViewModel.pendingModelConfirmation = nil
                        Task { await chatViewModel.switchModel(confirmation.model, confirmed: true) }
                    }
                    Button("Cancel", role: .cancel) {
                        chatViewModel.pendingModelConfirmation = nil
                    }
                }
            }
        } else {
            badge(withChevron: false)
                .help(chatViewModel.backendCapabilities.supportsModelSwitching
                      ? "Model switching is unavailable while a turn is streaming"
                      : "This backend does not support model switching")
        }
    }

    @ViewBuilder
    private var menuContent: some View {
        if let offCatalog = offCatalogModel {
            Label(AgentModel.displayName(for: offCatalog), systemImage: "checkmark")
            Divider()
        }
        if let catalog = chatViewModel.modelCatalog, !catalog.selectableProviders.isEmpty {
            liveCatalogSections(catalog)
            Divider()
            Button("Refresh Models") {
                Task { await chatViewModel.refreshModelCatalog(force: true) }
            }
        } else {
            staticCatalogButtons
        }
    }

    /// One section per authenticated provider, in the gateway's canonical
    /// order, the current provider's section first.
    @ViewBuilder
    private func liveCatalogSections(_ catalog: ModelCatalog) -> some View {
        let providers = catalog.selectableProviders
            .sorted { $0.isCurrent && !$1.isCurrent }
        ForEach(providers) { provider in
            Section(provider.name) {
                ForEach(provider.models, id: \.self) { modelID in
                    modelButton(id: modelID, label: AgentModel.displayName(for: modelID))
                }
            }
        }
    }

    @ViewBuilder
    private var staticCatalogButtons: some View {
        ForEach(AgentModel.catalog) { model in
            modelButton(id: model.id, label: model.label)
        }
    }

    @ViewBuilder
    private func modelButton(id: String, label: String) -> some View {
        Button {
            Task { await chatViewModel.switchModel(id) }
        } label: {
            if AgentModel.normalize(id) == AgentModel.normalize(currentModel) {
                Label(label, systemImage: "checkmark")
            } else {
                Text(label)
            }
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
