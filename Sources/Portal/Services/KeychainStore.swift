import Foundation
import Security
import os

private let log = Logger(subsystem: "com.ethenotethan.Portal", category: "KeychainStore")

/// macOS Keychain wrapper for storing the gateway API key and URL.
/// Uses kSecClassGenericPassword with a fixed service identifier.
/// All operations are synchronous C API calls — safe to call from any thread.
final class KeychainStore: Sendable {

    static let shared = KeychainStore()

    private let service = "com.hermes.native"

    private init() {}

    // MARK: - Upsert primitive

    /// Write `data` under `account`, creating the item or updating it in place.
    ///
    /// Every save used to be `delete()` then `SecItemAdd`. That pattern loses
    /// data whenever the delete fails: `SecItemAdd` then returns
    /// `errSecDuplicateItem`, the stale value survives, and — because callers
    /// discard the `Bool` — the app reports success and shows the new value in
    /// memory until the next launch re-reads the old blob. The delete DOES fail
    /// in normal local use: an ad-hoc signed build gets a fresh code identity on
    /// every rebuild, so the existing item's ACL no longer matches and the
    /// write is denied (`errSecAuthFailed`) while reads still succeed. That is
    /// the "my new harness disappears on relaunch" bug.
    ///
    /// Update-first is also atomic: there is no window where the item is gone.
    @discardableResult
    private func upsert(account: String, data: Data) -> Bool {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let updateStatus = SecItemUpdate(
            identity as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return true }

        if updateStatus == errSecItemNotFound {
            var addQuery = identity
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus == errSecSuccess { return true }
            // Lost a race with another writer — the item exists now, so update.
            if addStatus == errSecDuplicateItem {
                let retry = SecItemUpdate(
                    identity as CFDictionary,
                    [kSecValueData as String: data] as CFDictionary
                )
                if retry == errSecSuccess { return true }
                log.error("Keychain upsert '\(account, privacy: .public)' failed on duplicate retry: \(retry)")
                return false
            }
            log.error("Keychain add '\(account, privacy: .public)' failed: \(addStatus)")
            return false
        }

        // errSecAuthFailed (-25293) here means the item's ACL was created by a
        // different code identity — the ad-hoc rebuild case above.
        log.error("Keychain update '\(account, privacy: .public)' failed: \(updateStatus)")
        return false
    }

    /// Test seam for `upsert` — the save/load helpers below all funnel through
    /// it, but tests need to hit it under a throwaway account so they never
    /// touch the app's live `gateways`/`api-key` items.
    @discardableResult
    internal func upsertForTesting(account: String, data: Data) -> Bool {
        upsert(account: account, data: data)
    }

    @discardableResult
    internal func upsertForTesting(account: String, value: String) -> Bool {
        upsert(account: account, data: Data(value.utf8))
    }

    // MARK: - API Key

    @discardableResult
    func saveAPIKey(_ key: String) -> Bool {
        guard let data = key.data(using: .utf8) else { return false }
        return upsert(account: "api-key", data: data)
    }

    func loadAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "api-key",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func deleteAPIKey() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "api-key",
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Centaur API Key

    @discardableResult
    func saveCentaurAPIKey(_ key: String) -> Bool {
        guard let data = key.data(using: .utf8) else { return false }
        return upsert(account: "centaur-api-key", data: data)
    }

    func loadCentaurAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "centaur-api-key",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func deleteCentaurAPIKey() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "centaur-api-key",
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Gateway URL

    @discardableResult
    func saveGatewayURL(_ url: String) -> Bool {
        guard let data = url.data(using: .utf8) else { return false }
        return upsert(account: "gateway-url", data: data)
    }

    func loadGatewayURL() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "gateway-url",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func deleteGatewayURL() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "gateway-url",
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Saved Gateways (multi-gateway switching)

    /// The list of saved gateways is stored as a single JSON blob under its own
    /// Keychain account, separate from the active `gateway-url`/`api-key` items
    /// (which still mirror whichever gateway is currently selected).

    @discardableResult
    func saveGateways(_ gateways: [SavedGateway]) -> Bool {
        guard let data = try? JSONEncoder().encode(gateways) else { return false }
        return upsert(account: "gateways", data: data)
    }

    func loadGateways() -> [SavedGateway] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "gateways",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data,
              let gateways = try? JSONDecoder().decode([SavedGateway].self, from: data) else {
            return []
        }
        return gateways
    }

    @discardableResult
    func deleteGateways() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "gateways",
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
