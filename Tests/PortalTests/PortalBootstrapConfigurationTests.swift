import Foundation
import Testing
@testable import Portal

@Suite("Portal bootstrap configuration")
internal struct PortalBootstrapConfigurationTests {
    @Test("loads a secure local installer handoff without deleting it")
    internal func loadsSecureLocalHandoff() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("bootstrap.json")
        let payload = """
        {"schemaVersion":1,"gatewayURL":"ws://127.0.0.1:8642/v1/ws","apiKey":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}
        """
        try Data(payload.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)

        let configuration = try PortalBootstrapConfiguration.load(from: file)

        #expect(configuration.gatewayURL == "ws://127.0.0.1:8642/v1/ws")
        #expect(configuration.apiKey.count == 64)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("removes the handoff only when explicitly acknowledged")
    internal func removesAcknowledgedHandoff() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent("bootstrap.json")
        try Data("{}".utf8).write(to: file, options: .atomic)

        try PortalBootstrapConfiguration.removeHandoff(at: file)

        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("rejects a symbolic-link handoff")
    internal func rejectsSymbolicLink() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let target = directory.appendingPathComponent("target.json")
        let link = directory.appendingPathComponent("bootstrap.json")
        let payload = """
        {"schemaVersion":1,"gatewayURL":"ws://127.0.0.1:8642/v1/ws","apiKey":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}
        """
        try Data(payload.utf8).write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(throws: PortalBootstrapConfiguration.LoadError.unsafeFile) {
            try PortalBootstrapConfiguration.load(from: link)
        }
    }
}
