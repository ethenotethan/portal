import Foundation

/// One-time local connection handoff written by the macOS stack installer.
///
/// The API key remains in a mode-0600 file until the user confirms the
/// connection. `SettingsViewModel` then persists it to the Keychain and removes
/// the handoff. The loader accepts only a loopback WebSocket URL so a planted
/// file cannot silently redirect Portal to a remote gateway.
internal struct PortalBootstrapConfiguration: Codable, Equatable, Sendable {
    internal let schemaVersion: Int
    internal let gatewayURL: String
    internal let apiKey: String

    internal enum LoadError: Error, Equatable {
        case unsafeFile
        case insecurePermissions(Int)
        case unsupportedSchema(Int)
        case invalidGatewayURL
        case invalidAPIKey
    }

    internal static func defaultHandoffURL(
        fileManager: FileManager = .default
    ) -> URL? {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Portal", isDirectory: true)
            .appendingPathComponent("bootstrap.json", isDirectory: false)
    }

    internal static func load(
        from url: URL,
        fileManager: FileManager = .default
    ) throws -> PortalBootstrapConfiguration {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              (values.fileSize ?? 0) <= 65_536 else {
            throw LoadError.unsafeFile
        }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let ownerID = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
        let referenceCount = (attributes[.referenceCount] as? NSNumber)?.intValue
        guard ownerID == getuid(), referenceCount == 1 else {
            throw LoadError.unsafeFile
        }
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
        guard permissions & 0o077 == 0 else {
            throw LoadError.insecurePermissions(permissions)
        }

        let configuration = try JSONDecoder().decode(
            PortalBootstrapConfiguration.self,
            from: Data(contentsOf: url)
        )
        guard configuration.schemaVersion == 1 else {
            throw LoadError.unsupportedSchema(configuration.schemaVersion)
        }
        guard let components = URLComponents(string: configuration.gatewayURL),
              components.scheme == "ws",
              let host = components.host,
              ["127.0.0.1", "localhost", "::1"].contains(host),
              components.port != nil else {
            throw LoadError.invalidGatewayURL
        }
        guard configuration.apiKey.count >= 32,
              configuration.apiKey.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet.alphanumerics.contains(scalar)
              }) else {
            throw LoadError.invalidAPIKey
        }
        return configuration
    }

    internal static func removeHandoff(
        at url: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.removeItem(at: url)
    }
}
