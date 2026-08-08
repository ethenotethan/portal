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

    // MARK: - Read outcomes

    /// Why a read produced no value. Callers MUST distinguish these two: a
    /// missing item means "nothing was ever saved", but a refused read means
    /// "something is saved and we couldn't see it".
    ///
    /// Collapsing both to `nil` is what let one transient refusal destroy a
    /// user's saved harness. `SettingsViewModel.init` read nil, fell back to
    /// `Constants.defaultGatewayURL` (127.0.0.1), and then *wrote that back*:
    /// the migration branch minted a fresh localhost entry over the real
    /// `gateways` blob, and `syncActiveGateway` rewrote the active entry's URL
    /// to localhost. A read failure became permanent corruption, which is the
    /// "I add the harness, restart, and it's 127.0.0.1 again" report.
    internal enum ReadOutcome<Value>: Sendable where Value: Sendable {
        /// The item exists and decoded.
        case found(Value)
        /// The item genuinely is not there (`errSecItemNotFound`). Safe to
        /// treat as "first run" and write a default.
        case missing
        /// The Keychain refused or the payload wouldn't decode. NOT safe to
        /// overwrite — the stored value is presumed intact and unread.
        case failed(OSStatus)

        /// The value, or nil for both no-value cases. Use only where the
        /// distinction genuinely doesn't matter.
        internal var value: Value? {
            if case .found(let value) = self { return value }
            return nil
        }

        /// True when the stored item must be left alone.
        internal var isUnreadable: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    /// Read raw data for `account`, preserving the OSStatus on failure.
    private func read(account: String) -> ReadOutcome<Data> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess else {
            log.error("Keychain read '\(account, privacy: .public)' failed: \(status)")
            return .failed(status)
        }
        guard let data = result as? Data else {
            log.error("Keychain read '\(account, privacy: .public)' returned no data")
            return .failed(errSecInternalError)
        }
        return .found(data)
    }

    private func readString(account: String) -> ReadOutcome<String> {
        switch read(account: account) {
        case .missing: return .missing
        case .failed(let status): return .failed(status)
        case .found(let data):
            guard let text = String(data: data, encoding: .utf8) else {
                log.error("Keychain '\(account, privacy: .public)' held non-UTF8 bytes")
                return .failed(errSecDecode)
            }
            return .found(text)
        }
    }

    /// Test seam for `readString`, mirroring `upsertForTesting` — the real
    /// readers below are hard-wired to the app's live accounts, which tests must
    /// not read or disturb.
    internal func readStringForTesting(account: String) -> ReadOutcome<String> {
        readString(account: account)
    }

    /// The `Data` → `[SavedGateway]` step of `readGateways`, split out because
    /// the branch that matters is unreachable from a test otherwise: producing a
    /// genuine Keychain read failure requires a refused ACL, which a test cannot
    /// manufacture. This keeps the "undecodable is `.failed`, not `.missing`"
    /// rule — the rule whose absence let a bad blob be overwritten — assertable.
    internal static func decodeGateways(_ outcome: ReadOutcome<Data>) -> ReadOutcome<[SavedGateway]> {
        switch outcome {
        case .missing: return .missing
        case .failed(let status): return .failed(status)
        case .found(let data):
            do {
                return .found(try JSONDecoder().decode([SavedGateway].self, from: data))
            } catch {
                // Logged, not swallowed: this is the only record of *why* the
                // blob is being preserved rather than replaced, and the reason
                // (a schema change vs. genuine corruption) decides the fix.
                log.error(
                    """
                    Keychain 'gateways' blob failed to decode (\(data.count) bytes) — preserving it: \
                    \(error.localizedDescription, privacy: .public)
                    """
                )
                return .failed(errSecDecode)
            }
        }
    }

    // MARK: - API Key

    @discardableResult
    func saveAPIKey(_ key: String) -> Bool {
        guard let data = key.data(using: .utf8) else { return false }
        return upsert(account: "api-key", data: data)
    }

    func loadAPIKey() -> String? {
        readAPIKey().value
    }

    internal func readAPIKey() -> ReadOutcome<String> {
        readString(account: "api-key")
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

    internal func readGatewayURL() -> ReadOutcome<String> {
        readString(account: "gateway-url")
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

    /// Read the saved-harness list, distinguishing "none saved" from "couldn't
    /// read". A decode failure counts as `.failed`, not `.missing`: a blob that
    /// won't parse is still a blob, and overwriting it throws away the only copy
    /// of credentials that may not be regenerable.
    internal func readGateways() -> ReadOutcome<[SavedGateway]> {
        Self.decodeGateways(read(account: "gateways"))
    }
}
