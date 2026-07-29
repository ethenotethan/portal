import Foundation

/// Errors from the upstream Hermes dashboard HTTP API.
internal enum HermesStandardError: Error, LocalizedError, Equatable {
    case invalidBaseURL
    case invalidPath
    case invalidResponse
    case unauthorized
    case http(status: Int, message: String)

    internal var errorDescription: String? {
        switch self {
        case .invalidBaseURL: "Hermes Standard requires an HTTP or HTTPS origin."
        case .invalidPath: "The Hermes Standard request path is invalid."
        case .invalidResponse: "Hermes Standard returned an invalid response."
        case .unauthorized: "Hermes Standard rejected the dashboard session token."
        case .http(let status, let message): "Hermes Standard HTTP \(status): \(message)"
        }
    }
}

internal enum HermesStandardNotificationAvailability: Equatable {
    case available
    case unavailable(String)
}

private final class HermesStandardRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let origin: URL

    init(origin: URL) {
        self.origin = origin
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard request.url?.scheme == origin.scheme,
              request.url?.host == origin.host,
              request.url?.port == origin.port else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

internal struct HermesStandardSessionEnvelope: Decodable, Equatable {
    internal let sessions: [HermesStandardSession]
    internal let total: Int
    internal let limit: Int?
    internal let offset: Int?
}

internal struct HermesStandardSession: Decodable, Identifiable, Equatable {
    internal let id: String
    internal let title: String?
    internal let preview: String?
    internal let source: String?
    internal let messageCount: Int
    internal let startedAt: Double?
    internal let lastActive: Double?
    internal let endedAt: Double?
    internal let isActive: Bool
    internal let archived: Bool

    private enum CodingKeys: String, CodingKey {
        case id, title, preview, source, archived
        case messageCount = "message_count"
        case startedAt = "started_at"
        case lastActive = "last_active"
        case endedAt = "ended_at"
        case isActive = "is_active"
    }

    internal init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        preview = try values.decodeIfPresent(String.self, forKey: .preview)
        source = try values.decodeIfPresent(String.self, forKey: .source)
        messageCount = try values.decodeIfPresent(Int.self, forKey: .messageCount) ?? 0
        startedAt = try values.decodeIfPresent(Double.self, forKey: .startedAt)
        lastActive = try values.decodeIfPresent(Double.self, forKey: .lastActive)
        endedAt = try values.decodeIfPresent(Double.self, forKey: .endedAt)
        isActive = try values.decodeIfPresent(Bool.self, forKey: .isActive) ?? (endedAt == nil)
        archived = try values.decodeIfPresent(Bool.self, forKey: .archived) ?? false
    }
}

internal struct HermesStandardCronJob: Decodable, Identifiable, Equatable {
    internal let id: String
    internal let name: String
    internal let schedule: String
    internal let enabled: Bool
    internal let state: String
    internal let deliver: String
    internal let lastRunStatus: String?
    internal let lastRunError: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, schedule, enabled, state, deliver
        case jobID = "job_id"
        case scheduleDisplay = "schedule_display"
        case lastRunStatus = "last_run_status"
        case lastStatus = "last_status"
        case lastRunError = "last_run_error"
        case lastError = "last_error"
    }

    internal init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id)
            ?? values.decode(String.self, forKey: .jobID)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? id
        schedule = try values.decodeIfPresent(String.self, forKey: .scheduleDisplay)
            ?? values.decodeIfPresent(String.self, forKey: .schedule)
            ?? ""
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        state = try values.decodeIfPresent(String.self, forKey: .state) ?? (enabled ? "scheduled" : "paused")
        deliver = try values.decodeIfPresent(String.self, forKey: .deliver) ?? "local"
        lastRunStatus = try values.decodeIfPresent(String.self, forKey: .lastRunStatus)
            ?? values.decodeIfPresent(String.self, forKey: .lastStatus)
        lastRunError = try values.decodeIfPresent(String.self, forKey: .lastRunError)
            ?? values.decodeIfPresent(String.self, forKey: .lastError)
    }
}

internal struct HermesStandardSkill: Decodable, Identifiable, Equatable {
    internal var id: String { name }
    internal let name: String
    internal let description: String
    internal let category: String
    internal let enabled: Bool
    internal let provenance: String
    internal let usage: Int?

    private enum CodingKeys: String, CodingKey {
        case name, description, category, enabled, provenance, source, usage
    }

    internal init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        description = try values.decodeIfPresent(String.self, forKey: .description) ?? ""
        category = try values.decodeIfPresent(String.self, forKey: .category) ?? "general"
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        provenance = try values.decodeIfPresent(String.self, forKey: .provenance)
            ?? values.decodeIfPresent(String.self, forKey: .source)
            ?? "local"
        usage = try values.decodeIfPresent(Int.self, forKey: .usage)
    }
}

/// HTTP management client for upstream/default Hermes. It intentionally does
/// not conform to AgentBackend: this surface manages a Hermes installation but
/// cannot create or stream Portal chat sessions.
internal final class HermesStandardClient {
    private let origin: URL
    private let sessionToken: String
    private let redirectDelegate: HermesStandardRedirectDelegate
    private let session: URLSession
    private let decoder = JSONDecoder()

    internal let notificationAvailability: HermesStandardNotificationAvailability = .unavailable(
        "This Hermes version does not advertise an SSE notification stream."
    )

    internal init(
        baseURL: URL,
        sessionToken: String,
        configuration: URLSessionConfiguration = .ephemeral
    ) throws {
        guard let scheme = baseURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              baseURL.host != nil else {
            throw HermesStandardError.invalidBaseURL
        }
        var originComponents = URLComponents()
        originComponents.scheme = scheme
        originComponents.host = baseURL.host
        originComponents.port = baseURL.port
        guard let origin = originComponents.url else {
            throw HermesStandardError.invalidBaseURL
        }
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let redirectDelegate = HermesStandardRedirectDelegate(origin: origin)
        self.origin = origin
        self.sessionToken = sessionToken
        self.redirectDelegate = redirectDelegate
        self.session = URLSession(
            configuration: configuration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
    }

    internal func makeRequest(method: String, path: String, body: Data? = nil) throws -> URLRequest {
        guard path.hasPrefix("/"),
              let components = URLComponents(string: path),
              components.scheme == nil,
              components.host == nil,
              let url = URL(string: path, relativeTo: origin)?.absoluteURL,
              url.scheme == origin.scheme,
              url.host == origin.host,
              url.port == origin.port else {
            throw HermesStandardError.invalidPath
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(sessionToken, forHTTPHeaderField: "X-Hermes-Session-Token")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    internal func status() async throws -> [String: AnyCodable] {
        try await getDictionary("/api/status")
    }

    internal func sessions(limit: Int = 200, offset: Int = 0) async throws -> HermesStandardSessionEnvelope {
        let data = try await send(makeRequest(
            method: "GET",
            path: "/api/sessions?limit=\(max(1, limit))&offset=\(max(0, offset))"
        ))
        return try Self.decodeSessions(data)
    }

    internal func cronJobs() async throws -> [HermesStandardCronJob] {
        try Self.decodeCronJobs(await send(makeRequest(method: "GET", path: "/api/cron/jobs")))
    }

    internal func setCronJob(_ id: String, enabled: Bool) async throws {
        let action = enabled ? "resume" : "pause"
        _ = try await send(makeRequest(method: "POST", path: "/api/cron/jobs/\(try escaped(id))/\(action)"))
    }

    internal func triggerCronJob(_ id: String) async throws {
        _ = try await send(makeRequest(method: "POST", path: "/api/cron/jobs/\(try escaped(id))/trigger"))
    }

    internal func skills() async throws -> [HermesStandardSkill] {
        try Self.decodeSkills(await send(makeRequest(method: "GET", path: "/api/skills")))
    }

    internal func setSkill(_ name: String, enabled: Bool) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["name": name, "enabled": enabled])
        _ = try await send(makeRequest(method: "PUT", path: "/api/skills/toggle", body: body))
    }

    internal func config() async throws -> [String: AnyCodable] {
        try await getDictionary("/api/config")
    }

    internal func updateConfig(_ config: [String: AnyCodable]) async throws -> [String: AnyCodable] {
        let body = try JSONEncoder().encode(config)
        let data = try await send(makeRequest(method: "PUT", path: "/api/config", body: body))
        return try Self.decodeConfig(data)
    }

    private func getDictionary(_ path: String) async throws -> [String: AnyCodable] {
        try Self.decodeConfig(await send(makeRequest(method: "GET", path: path)))
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HermesStandardError.invalidResponse
        }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401, 403:
            throw HermesStandardError.unauthorized
        default:
            let message = sanitizedErrorMessage(data)
            throw HermesStandardError.http(status: http.statusCode, message: message)
        }
    }

    private func sanitizedErrorMessage(_ data: Data) -> String {
        var message: String?
        let object: [String: Any]?
        do {
            object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            object = nil
        }
        if let object {
            for key in ["message", "error", "detail"] {
                if let value = object[key] as? String, !value.isEmpty {
                    message = value
                    break
                }
            }
        }
        if message == nil {
            message = String(data: data, encoding: .utf8)
        }
        let redacted = (message ?? "Request failed")
            .replacingOccurrences(of: sessionToken, with: "[REDACTED]")
        return String(redacted.prefix(512))
    }

    private func escaped(_ component: String) throws -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))
        guard let encoded = component.addingPercentEncoding(withAllowedCharacters: allowed),
              !encoded.isEmpty else {
            throw HermesStandardError.invalidPath
        }
        return encoded
    }

    internal static func decodeSessions(_ data: Data) throws -> HermesStandardSessionEnvelope {
        try JSONDecoder().decode(HermesStandardSessionEnvelope.self, from: data)
    }

    internal static func decodeCronJobs(_ data: Data) throws -> [HermesStandardCronJob] {
        try decodeArray(data, envelopeKeys: ["jobs", "cron_jobs"])
    }

    internal static func decodeSkills(_ data: Data) throws -> [HermesStandardSkill] {
        try decodeArray(data, envelopeKeys: ["skills"])
    }

    internal static func decodeConfig(_ data: Data) throws -> [String: AnyCodable] {
        try JSONDecoder().decode([String: AnyCodable].self, from: data)
    }

    private static func decodeArray<T: Decodable>(_ data: Data, envelopeKeys: [String]) throws -> [T] {
        let direct: [T]?
        do {
            direct = try JSONDecoder().decode([T].self, from: data)
        } catch {
            direct = nil
        }
        if let direct {
            return direct
        }
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any],
              let raw = envelopeKeys.lazy.compactMap({ dictionary[$0] }).first else {
            throw HermesStandardError.invalidResponse
        }
        return try JSONDecoder().decode([T].self, from: JSONSerialization.data(withJSONObject: raw))
    }
}
