import SwiftUI

/// Onboarding view shown when the app isn't configured yet.
struct OnboardingView: View {
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var gatewayClientWrapper: GatewayClientWrapper
    @State private var testing = false
    @State private var testResult: String?
    @State private var showCFAuth = false

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
                            Text("https://GATEWAY_HOST").foregroundStyle(.tertiary)
                        }
                }

                Section("Authentication") {
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
                .disabled(testing)
                .buttonStyle(.bordered)

                Button("Connect") {
                    settings.validate()
                }
                .buttonStyle(.borderedProminent)
                .disabled(settings.gatewayURL.isEmpty || (settings.needsCFAuth && settings.cfAuthCookie == nil))
            }

            if let result = testResult {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(result.hasPrefix("✓") ? .green : .red)
            }
        }
        .padding(40)
        .frame(minWidth: 500, minHeight: 450)
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
        if let cookie = settings.cfAuthCookie {
            HTTPCookieStorage.shared.setCookie(cookie)
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
                } else if let http = response as? HTTPURLResponse, http.statusCode == 302 {
                    testResult = "✗ Cloudflare Access — sign in required"
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
