import Foundation

/// Outbound JSON-RPC 2.0 request.
struct JSONRPCRequest: Encodable {
    let jsonrpc: String = "2.0"
    let id: Int
    let method: String
    let params: [String: AnyCodable]?

    init(id: Int, method: String, params: [String: AnyCodable]? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }
}

/// Type-erasing codable wrapper for heterogeneous JSON-RPC params.
/// Needed because Swift's Codable requires homogeneous dictionaries,
/// but JSON-RPC params are heterogeneous (String, Int, Bool, etc.).
enum AnyCodable: Codable, @unchecked Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([AnyCodable])
    case dictionary([String: AnyCodable])

    // --- Encodable ---

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .null: try container.encodeNil()
        case .array(let v): try container.encode(v)
        case .dictionary(let v): try container.encode(v)
        }
    }

    // --- Decodable ---

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        // Order matters: Bool before Int/Double (JSON true/false are not numbers)
        if let v = try? container.decode(Bool.self) { self = .bool(v); return }
        if let v = try? container.decode(String.self) { self = .string(v); return }
        if let v = try? container.decode(Int.self) { self = .int(v); return }
        if let v = try? container.decode(Double.self) { self = .double(v); return }
        if let v = try? container.decode([AnyCodable].self) { self = .array(v); return }
        if let v = try? container.decode([String: AnyCodable].self) { self = .dictionary(v); return }
        if container.decodeNil() { self = .null; return }

        throw DecodingError.typeMismatch(
            AnyCodable.self,
            DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "Cannot decode AnyCodable value"
            )
        )
    }

    // --- Convenience constructors ---

    init(_ value: String) { self = .string(value) }
    init(_ value: Int) { self = .int(value) }
    init(_ value: Double) { self = .double(value) }
    init(_ value: Bool) { self = .bool(value) }

    /// Bridge an untyped JSON-shaped value (nested [String: Any] / [Any] /
    /// scalars, e.g. from JSONSerialization or hand-built wire dicts) into
    /// the typed tree. Unrepresentable leaves become .null rather than
    /// throwing — a lossy leaf must not drop the whole request.
    internal init(any value: Any) {
        switch value {
        case let v as String: self = .string(v)
        case let v as Bool: self = .bool(v)
        case let v as Int: self = .int(v)
        case let v as Double: self = .double(v)
        case let v as [Any]: self = .array(v.map { AnyCodable(any: $0) })
        case let v as [String: Any]:
            self = .dictionary(v.mapValues { AnyCodable(any: $0) })
        case let v as AnyCodable: self = v
        default: self = .null
        }
    }
}

// Equatable for testing
extension AnyCodable {
    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        switch (lhs, rhs) {
        case (.string(let a), .string(let b)): return a == b
        case (.int(let a), .int(let b)): return a == b
        case (.double(let a), .double(let b)): return a == b
        case (.bool(let a), .bool(let b)): return a == b
        case (.null, .null): return true
        case (.array(let a), .array(let b)): return a == b
        case (.dictionary(let a), .dictionary(let b)): return a == b
        default: return false
        }
    }
}
