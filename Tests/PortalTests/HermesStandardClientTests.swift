import Testing
import Foundation
@testable import Portal

@Suite("Hermes Standard Client")
internal struct HermesStandardClientTests {
    private func client() throws -> HermesStandardClient {
        try HermesStandardClient(
            baseURL: #require(URL(string: "https://standard.example.com/dashboard")),
            sessionToken: String("session-token")
        )
    }

    @Test("requests stay on configured origin and carry dashboard auth")
    internal func requestContract() throws {
        let request = try client().makeRequest(method: "GET", path: "/api/sessions")
        #expect(request.url?.absoluteString == "https://standard.example.com/api/sessions")
        #expect(request.value(forHTTPHeaderField: "X-Hermes-Session-Token") == "session-token")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.timeoutInterval == 15)
    }

    @Test("rejects non-HTTP origins and absolute request paths")
    internal func rejectsUnsafeURLs() throws {
        #expect(throws: HermesStandardError.self) {
            _ = try HermesStandardClient(
                baseURL: #require(URL(string: "file:///tmp/hermes")),
                sessionToken: String("session-token")
            )
        }
        #expect(throws: HermesStandardError.self) {
            _ = try client().makeRequest(method: "GET", path: "https://evil.example/api/sessions")
        }
    }

    @Test("decodes upstream session list envelope")
    internal func decodesSessions() throws {
        let json = #"""
        {
          "sessions": [{
            "id": "20260729_120000_abcd",
            "title": "Roadmap",
            "preview": "hello",
            "source": "cli",
            "message_count": 7,
            "started_at": 1785326400,
            "last_active": 1785326460,
            "ended_at": null,
            "is_active": true,
            "archived": false
          }],
          "total": 1,
          "limit": 20,
          "offset": 0
        }
        """#
        let data = Data(json.utf8)
        let envelope = try HermesStandardClient.decodeSessions(data)
        #expect(envelope.total == 1)
        #expect(envelope.sessions.first?.id == "20260729_120000_abcd")
        #expect(envelope.sessions.first?.messageCount == 7)
        #expect(envelope.sessions.first?.isActive == true)
    }

    @Test("decodes upstream cron and skill rows")
    internal func decodesCronAndSkills() throws {
        let cronData = Data(#"[{"id":"daily","name":"Daily brief","schedule":"0 9 * * *","enabled":true,"state":"scheduled","deliver":"local","last_run_status":"ok"}]"#.utf8)
        let jobs = try HermesStandardClient.decodeCronJobs(cronData)
        #expect(jobs.first?.id == "daily")
        #expect(jobs.first?.enabled == true)
        #expect(jobs.first?.lastRunStatus == "ok")

        let skillsData = Data(#"[{"name":"github-pr-workflow","description":"PR lifecycle","category":"github","enabled":true,"provenance":"bundled","usage":12}]"#.utf8)
        let skills = try HermesStandardClient.decodeSkills(skillsData)
        #expect(skills.first?.name == "github-pr-workflow")
        #expect(skills.first?.enabled == true)
        #expect(skills.first?.provenance == "bundled")
    }

    @Test("decodes config without flattening schema")
    internal func decodesConfig() throws {
        let data = Data(#"{"model":{"default":"openai/gpt-5"},"display":{"compact":true}}"#.utf8)
        let config = try HermesStandardClient.decodeConfig(data)
        #expect(config.keys.sorted() == ["display", "model"])
        #expect(config["model"]?.dictionaryValue?["default"]?.stringValue == "openai/gpt-5")
    }

    @Test("notifications are honest when upstream has no SSE contract")
    internal func notificationAvailability() throws {
        let client = try client()
        #expect(client.notificationAvailability == .unavailable(
            "This Hermes version does not advertise an SSE notification stream."
        ))
    }

    @Test("cross-origin redirects are rejected before credentials leave the configured origin")
    internal func rejectsCrossOriginRedirects() async throws {
        CrossOriginRedirectProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CrossOriginRedirectProtocol.self]
        let client = try HermesStandardClient(
            baseURL: #require(URL(string: "https://standard.example.com/dashboard")),
            sessionToken: String("session-token"),
            configuration: configuration
        )

        await #expect(throws: HermesStandardError.self) {
            _ = try await client.status()
        }
        #expect(CrossOriginRedirectProtocol.requestedHosts == ["standard.example.com"])
    }

    @Test("structured HTTP errors preserve useful context without exposing credentials")
    internal func redactsCredentialsFromHTTPError() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CredentialEchoErrorProtocol.self]
        let client = try HermesStandardClient(
            baseURL: #require(URL(string: "https://standard.example.com")),
            sessionToken: String("session-token"),
            configuration: configuration
        )

        do {
            _ = try await client.status()
            Issue.record("Expected the HTTP request to fail")
        } catch let error as HermesStandardError {
            let description = error.errorDescription ?? ""
            #expect(description.contains("database unavailable"))
            #expect(!description.contains("session-token"))
            #expect(description.count <= 600)
        }
    }

    @Test("cancelling a management request stops the underlying URL load")
    internal func cancellationStopsLoading() async throws {
        CancellationProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CancellationProtocol.self]
        let client = try HermesStandardClient(
            baseURL: #require(URL(string: "https://standard.example.com")),
            sessionToken: String("session-token"),
            configuration: configuration
        )

        let task = Task { try await client.status() }
        #expect(CancellationProtocol.waitUntilStarted())
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation to fail the request")
        } catch is CancellationError {
            // Expected Swift-concurrency cancellation.
        } catch let error as URLError {
            #expect(error.code == .cancelled)
        }
        #expect(CancellationProtocol.waitUntilStopped())
    }
}

private final class CrossOriginRedirectProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var hosts: [String] = []

    static var requestedHosts: [String] {
        lock.withLock { hosts }
    }

    static func reset() {
        lock.withLock { hosts = [] }
    }

    override static func canInit(with request: URLRequest) -> Bool { true }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        Self.lock.withLock { Self.hosts.append(host) }

        if host == "standard.example.com",
           let requestURL = request.url,
           let redirectURL = URL(string: "https://evil.example/collect"),
           let response = HTTPURLResponse(
            url: requestURL,
            statusCode: 302,
            httpVersion: nil,
            headerFields: ["Location": redirectURL.absoluteString]
           ) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class CredentialEchoErrorProtocol: URLProtocol, @unchecked Sendable {
    override static func canInit(with request: URLRequest) -> Bool { true }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 500,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let body = Data(#"{"error":"database unavailable","debug":"session-token"}"#.utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class CancellationProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var started = DispatchSemaphore(value: 0)
    nonisolated(unsafe) private static var stopped = DispatchSemaphore(value: 0)

    static func reset() {
        started = DispatchSemaphore(value: 0)
        stopped = DispatchSemaphore(value: 0)
    }

    static func waitUntilStarted() -> Bool {
        started.wait(timeout: .now() + 2) == .success
    }

    static func waitUntilStopped() -> Bool {
        stopped.wait(timeout: .now() + 2) == .success
    }

    override static func canInit(with request: URLRequest) -> Bool { true }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.started.signal()
    }

    override func stopLoading() {
        Self.stopped.signal()
    }
}
