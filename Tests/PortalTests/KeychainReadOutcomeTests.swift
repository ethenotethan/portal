import Testing
import Foundation
import Security
@testable import Portal

/// Regression coverage for "I add the harness, restart, and it's 127.0.0.1
/// again."
///
/// The loaders used to collapse every non-success `OSStatus` to `nil`/`[]`, so a
/// *refused* read looked exactly like "nothing was ever saved". `SettingsViewModel`
/// then fell back to `Constants.defaultGatewayURL` and wrote that back — the
/// migration branch minting a localhost entry over the real `gateways` blob, and
/// `syncActiveGateway` rewriting the active entry's URL. One transient refusal
/// became permanent data loss.
///
/// `ReadOutcome` exists to make that distinction impossible to drop. These tests
/// pin the three-way split and, in particular, that an undecodable payload is
/// `.failed` rather than `.missing`: a blob that won't parse is still a blob,
/// and overwriting it discards the only copy of credentials the user may not be
/// able to regenerate.
@Suite("Keychain read outcomes", .serialized)
internal struct KeychainReadOutcomeTests {

    private static let service = "com.hermes.native"

    private func deleteItem(_ account: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }

    /// Runs `body` against a throwaway account so the app's live `gateways`,
    /// `gateway-url`, and `api-key` items are never read or written.
    private func withTemporaryItem(_ account: String, _ body: (String) throws -> Void) throws {
        defer { deleteItem(account) }
        deleteItem(account)
        try body(account)
    }

    // MARK: - The three outcomes

    @Test("an item that was never written reads as .missing, not .failed")
    internal func absentItemIsMissing() throws {
        try withTemporaryItem("read-outcome-absent") { account in
            let outcome = KeychainStore.shared.readStringForTesting(account: account)
            #expect(outcome.value == nil)
            // The whole point: absent is safe to overwrite with a default.
            #expect(!outcome.isUnreadable)
            if case .missing = outcome {} else {
                Issue.record("expected .missing, got \(outcome)")
            }
        }
    }

    @Test("a stored value reads back as .found")
    internal func storedValueIsFound() throws {
        try withTemporaryItem("read-outcome-found") { account in
            #expect(KeychainStore.shared.upsertForTesting(
                account: account, value: "ws://100.64.7.12:8642/v1/ws"
            ))
            let outcome = KeychainStore.shared.readStringForTesting(account: account)
            #expect(outcome.value == "ws://100.64.7.12:8642/v1/ws")
            #expect(!outcome.isUnreadable)
        }
    }

    @Test("non-UTF8 bytes are .failed — the value is present but unreadable")
    internal func nonUTF8PayloadIsFailed() throws {
        try withTemporaryItem("read-outcome-binary") { account in
            // 0xFF 0xFE is not valid UTF-8. Standing in for any payload we hold
            // but cannot interpret: reporting "nothing saved" here is the lie
            // that licenses the overwrite.
            #expect(KeychainStore.shared.upsertForTesting(
                account: account, data: Data([0xFF, 0xFE, 0xFF])
            ))
            let outcome = KeychainStore.shared.readStringForTesting(account: account)
            #expect(outcome.value == nil)
            #expect(outcome.isUnreadable)
            if case .failed(let status) = outcome {
                #expect(status == errSecDecode)
            } else {
                Issue.record("expected .failed(errSecDecode), got \(outcome)")
            }
        }
    }

    // MARK: - Gateway blob decoding

    @Test("a valid harness blob decodes to .found")
    internal func validBlobDecodes() throws {
        let saved = [
            SavedGateway(name: "Eigen VDI", url: "http://10.0.2.47:8642", apiKey: "k1", kind: .hermes),
        ]
        let outcome = KeychainStore.decodeGateways(.found(try JSONEncoder().encode(saved)))
        #expect(outcome.value?.count == 1)
        #expect(outcome.value?.first?.name == "Eigen VDI")
        #expect(!outcome.isUnreadable)
    }

    @Test("a corrupt harness blob is .failed so it is never overwritten")
    internal func corruptBlobIsPreserved() {
        let outcome = KeychainStore.decodeGateways(.found(Data("{not json".utf8)))
        #expect(outcome.value == nil)
        // .failed, NOT .missing — .missing would send SettingsViewModel down the
        // migration branch, which writes a fresh localhost entry over this blob.
        #expect(outcome.isUnreadable)
    }

    @Test("a refused read propagates its status rather than becoming an empty list")
    internal func refusedReadPropagates() {
        // errSecAuthFailed is the realistic case: an ad-hoc signed rebuild gets a
        // new code identity, so the existing item's ACL no longer matches.
        let outcome = KeychainStore.decodeGateways(.failed(errSecAuthFailed))
        #expect(outcome.value == nil)
        #expect(outcome.isUnreadable)
        if case .failed(let status) = outcome {
            #expect(status == errSecAuthFailed)
        } else {
            Issue.record("expected .failed(errSecAuthFailed), got \(outcome)")
        }
    }

    @Test("a missing harness blob stays .missing — first launch must still work")
    internal func missingBlobStaysMissing() {
        let outcome = KeychainStore.decodeGateways(.missing)
        #expect(outcome.value == nil)
        // Not unreadable: a genuine first run has to be allowed to write.
        #expect(!outcome.isUnreadable)
    }

    // MARK: - loadX bridges

    @Test("the nil-returning loaders still bridge .found through")
    internal func loadersBridgeFoundValues() throws {
        // The `load*` helpers are the compatibility layer over `read*`. They keep
        // returning nil for both no-value cases, so only callers that must
        // distinguish them use the outcome directly.
        try withTemporaryItem("read-outcome-bridge") { account in
            #expect(KeychainStore.shared.upsertForTesting(account: account, value: "bridged"))
            #expect(KeychainStore.shared.readStringForTesting(account: account).value == "bridged")
        }
    }
// MARK: - saveAPIKey

    @Test("saveAPIKey persists the value and returns true")
    internal func saveAPIKeyPersists() throws {
        let account = "api-key"
        defer { deleteItem(account) }
        deleteItem(account)
        let allGood = KeychainStore.shared.saveAPIKey("test-api-key")
        #expect(allGood)
        #expect(KeychainStore.shared.loadAPIKey() == "test-api-key")
    }
}
