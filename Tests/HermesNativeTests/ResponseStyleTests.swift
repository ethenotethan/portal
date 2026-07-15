import Testing
import Foundation
@testable import HermesNative

// .serialized: two of these tests mutate the same UserDefaults key; parallel
// execution races them against each other (one test's write lands between the
// other's set and read).
@Suite("Response Style", .serialized)
struct ResponseStyleTests {

    @Test("Every style has a distinct, non-empty preamble")
    func preamblesAreDistinct() {
        let preambles = ResponseStyle.allCases.map(\.preamble)
        #expect(preambles.allSatisfy { !$0.isEmpty })
        #expect(Set(preambles).count == preambles.count)
    }

    @Test("Direct style forbids diagrams; deep map encourages them")
    func stylesPointOppositeDirections() {
        #expect(ResponseStyle.deepMap.preamble.contains("diagram-first"))
        #expect(ResponseStyle.direct.preamble.contains("Do not use Mermaid diagrams"))
    }

    @Test("Stored default round-trips through UserDefaults")
    func storedDefaultRoundTrip() {
        let original = UserDefaults.standard.string(forKey: ResponseStyle.userDefaultsKey)
        defer {
            // Restore whatever was there so the test doesn't pollute app state.
            if let original {
                UserDefaults.standard.set(original, forKey: ResponseStyle.userDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: ResponseStyle.userDefaultsKey)
            }
        }

        ResponseStyle.storedDefault = .direct
        #expect(ResponseStyle.storedDefault == .direct)
        ResponseStyle.storedDefault = .deepMap
        #expect(ResponseStyle.storedDefault == .deepMap)
    }

    @Test("Unknown stored value falls back to deep map")
    func unknownValueFallsBack() {
        let original = UserDefaults.standard.string(forKey: ResponseStyle.userDefaultsKey)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: ResponseStyle.userDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: ResponseStyle.userDefaultsKey)
            }
        }

        UserDefaults.standard.set("not-a-style", forKey: ResponseStyle.userDefaultsKey)
        #expect(ResponseStyle.storedDefault == .deepMap)
    }
}
