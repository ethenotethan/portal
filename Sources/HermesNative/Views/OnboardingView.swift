import SwiftUI

/// Onboarding view shown when the app isn't configured yet.
struct OnboardingView: View {
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var gatewayClientWrapper: GatewayClientWrapper
    @State private var testing = false
    @State private var testResult: String?

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color.accentColor)

            Text("Hermes Native")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Connect to your Hermes Agent gateway")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Form {
                Section("Gateway") {
                    TextField("URL", text: $settings.gatewayURL)
                        .textFieldStyle(.roundedBorder)
                        .placeholder(when: settings.gatewayURL.isEmpty) {
                            Text(Constants.defaultGatewayURL).foregroundStyle(.tertiary)
                        }
                }

                Section("Authentication") {
                    SecureField("API Key", text: $settings.apiKey)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: 450)

            HStack(spacing: 16) {
                Button {
                    testConnection()
                } label: {
                    if testing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Test Connection")
                    }
                }
                .disabled(testing || settings.apiKey.isEmpty)
                .buttonStyle(.bordered)

                Button("Connect") {
                    settings.validate()
                }
                .buttonStyle(.borderedProminent)
                .disabled(settings.apiKey.isEmpty)
            }

            if let result = testResult {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(result.hasPrefix("✓") ? .green : .red)
            }
        }
        .padding(40)
        .frame(minWidth: 500, minHeight: 400)
    }

    private func testConnection() {
        testing = true
        testResult = nil

        guard let url = settings.buildWebSocketURL() else {
            testResult = "✗ Invalid URL"
            testing = false
            return
        }

        // Quick HTTP health check on the gateway
        let baseURL = url.deletingLastPathComponent().deletingLastPathComponent()
        let healthURL = baseURL.appendingPathComponent("health")

        var request = URLRequest(url: healthURL)
        request.timeoutInterval = 5
        if !settings.apiKey.isEmpty {
            request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        }

        URLSession.shared.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                testing = false
                if let error = error {
                    testResult = "✗ \(error.localizedDescription)"
                } else if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    testResult = "✓ Gateway reachable"
                } else if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                    testResult = "✗ Invalid API key"
                } else {
                    testResult = "✗ Unexpected response"
                }
            }
        }.resume()
    }
}

// Helper ViewModifier for placeholder text
extension View {
    func placeholder(when shouldShow: Bool, @ViewBuilder placeholder: () -> some View) -> some View {
        ZStack(alignment: .leading) {
            placeholder().opacity(shouldShow ? 1 : 0)
            self
        }
    }
}
