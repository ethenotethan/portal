import SwiftUI

/// Root content view — switches between onboarding and chat.
struct ContentView: View {
    @EnvironmentObject var settings: SettingsViewModel
    @StateObject private var chatViewModel = ChatViewModel()
    @StateObject private var gatewayClientWrapper = GatewayClientWrapper()

    var body: some View {
        Group {
            if settings.isConfigured && gatewayClientWrapper.isConnected {
                ChatView()
                    .environmentObject(chatViewModel)
            } else {
                OnboardingView()
                    .environmentObject(gatewayClientWrapper)
            }
        }
        .task {
            if settings.isConfigured {
                await gatewayClientWrapper.connect(
                    gatewayURL: settings.gatewayURL,
                    apiKey: settings.apiKey,
                    settings: settings
                )
                chatViewModel.setGatewayClient(gatewayClientWrapper.client)
            }
        }
        .onChange(of: settings.isConfigured) { _, configured in
            if configured {
                Task {
                    await gatewayClientWrapper.connect(
                        gatewayURL: settings.gatewayURL,
                        apiKey: settings.apiKey,
                        settings: settings
                    )
                    chatViewModel.setGatewayClient(gatewayClientWrapper.client)
                }
            }
        }
    }
}

/// Observable wrapper for the GatewayClient lifecycle.
@MainActor
final class GatewayClientWrapper: ObservableObject {
    @Published var isConnected: Bool = false
    private(set) var client: GatewayClient

    init() {
        self.client = GatewayClient(gatewayURL: URL(string: Constants.defaultGatewayURL)!, apiKey: "")
    }

    func connect(gatewayURL: String, apiKey: String, settings: SettingsViewModel) async {
        client.disconnect()

        guard let url = settings.buildWebSocketURL() else {
            isConnected = false
            return
        }

        client = GatewayClient(gatewayURL: url, apiKey: apiKey)
        client.$connectionState
            .map { state -> Bool in
                if case .connected = state { return true }
                return false
            }
            .assign(to: &$isConnected)

        client.connect()
    }
}
