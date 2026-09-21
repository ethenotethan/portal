import Foundation
import Testing
@testable import Portal

@Suite("Session folder")
internal struct SessionFolderTests {
    @Test("a newly named folder receives stable local identity and creation metadata")
    internal func initializerDefaults() throws {
        let folder = SessionFolder(name: "Research")

        _ = try #require(UUID(uuidString: folder.id))
        #expect(folder.name == "Research")
        #expect(folder.createdAt.timeIntervalSince1970 > 0)
    }

    @Test("restored folder metadata is preserved exactly")
    internal func explicitMetadataIsPreserved() {
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let folder = SessionFolder(id: "folder-1", name: "Archive", createdAt: createdAt)

        #expect(folder.id == "folder-1")
        #expect(folder.name == "Archive")
        #expect(folder.createdAt == createdAt)
    }
}
