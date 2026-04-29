import SwiftUI

/// Settings view for gateway connection configuration.
struct SettingsView: View {
    @EnvironmentObject var settings: SettingsViewModel

    var body: some View {
        Form {
            Section("Gateway Connection") {
                TextField("Gateway URL", text: $settings.gatewayURL)
                    .textFieldStyle(.roundedBorder)
                SecureField("API Key", text: $settings.apiKey)
                    .textFieldStyle(.roundedBorder)
            }

            Section {
                Text("The API key is stored in your macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 250)
    }
}
