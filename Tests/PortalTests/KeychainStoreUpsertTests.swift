import Testing
import Foundation
import Security
@testable import Portal

/// Regression coverage for the "added harness disappears on relaunch" bug.
///
/// `KeychainStore` used to save by `SecItemDelete` + `SecItemAdd`. When the
/// delete failed — routinely, for an ad-hoc signed local build whose code
/// identity changes on every rebuild, so the existing item's ACL no longer
/// matches — the add returned `errSecDuplicateItem` and the stale value
/// survived. The new harness stayed visible in memory and vanished on the next
/// launch. These tests pin the update-in-place contract that fixes it.
///
/// They exercise the real Keychain under a throwaway service/account, so they
/// clean up after themselves and never touch the app's live `gateways` item.
@Suite("Keychain upsert", .serialized)
internal struct KeychainStoreUpsertTests {

    private static let service = "com.hermes.native"

    /// A distinct account per test keeps them independent under .serialized.
    private func withTemporaryItem(
        _ account: String,
        _ body: (String) throws -> Void
    ) throws {
        defer { deleteItem(account) }
        deleteItem(account)
        try body(account)
    }

    private func deleteItem(_ account: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }

    private func rawRead(_ account: String) -> String? {
        var out: AnyObject?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func rawWrite(_ account: String, _ value: String) {
        SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ] as CFDictionary, nil)
    }

    @Test("overwriting an existing item replaces its value and reports success")
    internal func overwriteExistingItemSucceeds() throws {
        try withTemporaryItem("upsert-overwrite-test") { account in
            rawWrite(account, "stale")
            #expect(rawRead(account) == "stale")

            // The exact shape of the bug: a second write over an item that
            // already exists must land, not silently no-op.
            let ok = KeychainStore.shared.upsertForTesting(account: account, value: "fresh")
            #expect(ok)
            #expect(rawRead(account) == "fresh")
        }
    }

    @Test("repeated writes each land — no duplicate-item stall")
    internal func repeatedWritesAllLand() throws {
        try withTemporaryItem("upsert-repeat-test") { account in
            for value in ["one", "two", "three"] {
                #expect(KeychainStore.shared.upsertForTesting(account: account, value: value))
                #expect(rawRead(account) == value)
            }
        }
    }

    @Test("writing a brand-new item creates it")
    internal func createsMissingItem() throws {
        try withTemporaryItem("upsert-create-test") { account in
            #expect(rawRead(account) == nil)
            #expect(KeychainStore.shared.upsertForTesting(account: account, value: "created"))
            #expect(rawRead(account) == "created")
        }
    }

    @Test("a growing harness list survives a rewrite")
    internal func harnessListGrowsAcrossWrites() throws {
        // The user-facing scenario: add a Hermes Standard entry alongside an
        // existing Gateway entry, then re-read as a fresh launch would.
        let existing = [
            SavedGateway(name: "Eigen VDI", url: "http://10.0.2.47:8642", apiKey: "k1", kind: .hermes),
        ]
        let grown = existing + [
            SavedGateway(name: "Standard", url: "https://dash.example.com", apiKey: "k2", kind: .hermesStandard),
        ]

        try withTemporaryItem("upsert-harness-list-test") { account in
            let firstBlob = try JSONEncoder().encode(existing)
            #expect(KeychainStore.shared.upsertForTesting(account: account, data: firstBlob))

            let secondBlob = try JSONEncoder().encode(grown)
            #expect(KeychainStore.shared.upsertForTesting(account: account, data: secondBlob))

            let reread = try #require(rawRead(account).map { Data($0.utf8) })
            let decoded = try JSONDecoder().decode([SavedGateway].self, from: reread)
            #expect(decoded.count == 2)
            #expect(decoded.contains { $0.kind == .hermesStandard })
        }
    }
}
