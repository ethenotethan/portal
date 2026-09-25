import CryptoKit
import Foundation
import Testing

@Suite("Application icon assets")
internal struct AppIconAssetTests {
    @Test("macOS, menu bar, and iOS ship the approved issue 547 artwork")
    internal func approvedArtworkIsUsedAtEveryRequiredSize() throws {
        let expectedHashes = [
            "Icon-1024.png": "44799cf02f2c1a4af1ad8fa0b2e4f3f06eacf5b836fb3010ee9b592c9717fde7",
            "Icon-120.png": "8729592448e13e8c276c30d5c54a3da419433b54d43b7a2e7cb92d0fe9283128",
            "Icon-152.png": "2b250f28ef5f2719d59829519768800f0ff554b57be8d740ae793cc2840ad2c0",
            "Icon-167.png": "9646fa9d6ac8afefd45d1c886dea0ef4e00b7e6e8f5d8b5c820b307cb8c84ac7",
            "Icon-180.png": "10e433dc369cee6e8ff9adba25b1861582e298d3c598d64cb6bf130b554359be",
            "Icon-228.png": "2953bc04c085b87a83a33ec67fb1327fc38e34e5724ab15170b9741a88c2492e",
            "Icon-40.png": "a14fb1865bd2ad01b312f0784e1f16c03883d5f7ac929d8289bba9915f1dc593",
            "Icon-58.png": "4d0b2078e20185414882fcd1a2c43ac53147418867e1db40fe7f34dbec3dcbfd",
            "Icon-60.png": "d3ef80dec476a88cc9b73c1a2980d4091c3c82a82b02ac8ed62587ddac24945e",
            "Icon-80.png": "28a2f56982b42b04e68a5c5fb727b28b51efbcdb97fdbdb77296f2256a275285",
            "Icon-87.png": "4a800308c66ddcd844111568993e1682d94f21d4fd2de52aa882b0bf565c5ead",
            "mac-1024.png": "a02f41c6d18fe337b758d6d7fc4e2ea27aae84b12ea1e8a1f5ae55a6caba02d0",
            "mac-128.png": "7477cffa84cfffd870782da4d5fa7ed75508c1c69c3f47c9bbc795ddf5e51142",
            "mac-16.png": "5471436523c35e60d09b1242c5968fc322f31c18a6db8bcbbb839f19e1b3131b",
            "mac-256.png": "ac4d779e2efa849d9a941c0bf0b8e133ea704b852f21fea8ce306a8cc7f5ca5d",
            "mac-32.png": "5583749c9640167773fab695b398aed55178cb8c643d04f38fc658d1ce537331",
            "mac-512.png": "30cc3babea8cc995a2828adbc482336daf4c78ccfc04d928c01d81cb714ffa59",
            "mac-64.png": "8892265467a5c0b7c311029594dea3c777a588365f0a0355eee97577202150e8",
        ]
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let iconDirectory = root.appendingPathComponent("Sources/Portal/Assets.xcassets/AppIcon.appiconset")
        let catalogData = try Data(contentsOf: iconDirectory.appendingPathComponent("Contents.json"))
        let catalog = try #require(JSONSerialization.jsonObject(with: catalogData) as? [String: Any])
        let images = try #require(catalog["images"] as? [[String: Any]])
        let catalogFilenames = Set(images.compactMap { $0["filename"] as? String })
        #expect(catalogFilenames == Set(expectedHashes.keys), "every catalog icon must pin approved artwork")

        for (filename, expectedHash) in expectedHashes {
            let data = try Data(contentsOf: iconDirectory.appendingPathComponent(filename))
            let actualHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            #expect(actualHash == expectedHash, "\(filename) does not contain the approved logo artwork")
            if filename.hasPrefix("Icon-") {
                #expect(data.count > 25 && data[25] == 2, "\(filename) must be an opaque RGB PNG for iOS")
            }
        }
    }
}
