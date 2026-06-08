import SwiftUI

/// Onboarding view shown when the app isn't configured yet.
struct OnboardingView: View {
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var gatewayClientWrapper: GatewayClientWrapper
    @EnvironmentObject var personaManager: PersonaManager
    @EnvironmentObject var capabilitiesStore: HermesCapabilitiesStore
    @State private var testing = false
    @State private var testResult: String?
    @State private var showCFAuth = false

    var body: some View {
        #if os(macOS)
        macBody
        #else
        iosBody
        #endif
    }

    // MARK: - macOS (original centered form)

    #if os(macOS)
    private var macBody: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(personaManager.activePersona.accentColor)

                Text(personaManager.activePersona.name)
                    .font(.title)
                    .fontWeight(.bold)

                Text("Connect to your Hermes Agent gateway")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Form {
                    Section("Gateway") {
                        TextField("URL", text: $settings.gatewayURL)
                            .textFieldStyle(.roundedBorder)
                            .placeholder(when: settings.gatewayURL.isEmpty) {
                                Text("wss://your-gateway.example.com/v1/ws").foregroundStyle(.tertiary)
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
                            HermesProgressView()
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
                    VStack(spacing: 4) {
                        Text(result)
                            .font(.caption)
                            .foregroundStyle(result.hasPrefix("✓") ? .green : .red)

                        if result.hasPrefix("✓") {
                            Text("Capabilities: \(capabilitiesStore.capabilities.statusDisplay), version \(capabilitiesStore.capabilities.versionDisplay)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(40)
        }
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
    #endif

    // MARK: - iOS (compact, native-feeling)

    #if os(iOS)
    private var iosBody: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Header
                    VStack(spacing: 8) {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(personaManager.activePersona.accentColor)
                        Text(personaManager.activePersona.name)
                            .font(.title3)
                            .fontWeight(.bold)
                        Text("Connect to your gateway")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 20)

                    // Gateway URL
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
                    }

                    // API Key
                    VStack(alignment: .leading, spacing: 6) {
                        Text("API Key")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        SecureField("Optional", text: $settings.apiKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.body)
                    }

                    // CF Access
                    if settings.needsCFAuth {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Cloudflare Access")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                            HStack {
                                if let email = settings.cfAuthEmail {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                    Text(email)
                                        .lineLimit(1)
                                        .font(.subheadline)
                                } else if settings.cfAuthCookie != nil {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                    Text("Authenticated")
                                        .font(.subheadline)
                                } else {
                                    Image(systemName: "lock.shield")
                                        .foregroundStyle(.secondary)
                                    Text("Not authenticated")
                                        .foregroundStyle(.secondary)
                                        .font(.subheadline)
                                }
                                Spacer()
                                Button(settings.cfAuthCookie != nil ? "Re-auth" : "Sign In") {
                                    showCFAuth = true
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }

                    // Buttons
                    HStack(spacing: 16) {
                        Button {
                            testConnection()
                        } label: {
                            if testing {
                                HermesProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("Test Connection")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(testing)

                        Spacer()

                        Button("Connect") {
                            settings.validate()
                        }
                        .accessibilityIdentifier("connectButton")
                        .buttonStyle(.borderedProminent)
                        .disabled(settings.gatewayURL.isEmpty || (settings.needsCFAuth && settings.cfAuthCookie == nil))
                    }
                    .padding(.top, 8)

                    if !gatewayClientWrapper.log.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(gatewayClientWrapper.log.suffix(5)) { entry in
                                Text(entry.text)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(entry.isError ? .red : .secondary)
                                    .lineLimit(2)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let result = testResult {
                        VStack(spacing: 4) {
                            Text(result)
                                .font(.caption)
                                .foregroundStyle(result.hasPrefix("✓") ? .green : .red)

                            if result.hasPrefix("✓") {
                                Text("Capabilities: \(capabilitiesStore.capabilities.statusDisplay), version \(capabilitiesStore.capabilities.versionDisplay)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)
        }
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
    #endif

    func testConnection() {
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
                    Task {
                        if let client = await gatewayClientWrapper.connectedClient(using: settings, timeout: 12) {
                            await capabilitiesStore.refresh(using: client)
                        } else {
                            await capabilitiesStore.reset(reason: "Gateway is reachable, but WebSocket did not connect")
                        }
                    }
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
