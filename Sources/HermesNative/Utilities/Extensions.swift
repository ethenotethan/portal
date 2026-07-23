import Foundation

// MARK: - AnyCodable value accessors

extension AnyCodable {
    /// Access the String value, if this is a .string case.
    var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    /// Access the Int value, if this is an .int case.
    var intValue: Int? {
        if case .int(let v) = self { return v }
        return nil
    }

    /// Access the Double value, if this is a .double case.
    var doubleValue: Double? {
        if case .double(let v) = self { return v }
        if case .int(let v) = self { return Double(v) }  // Int → Double coercion
        return nil
    }

    /// Access the Bool value, if this is a .bool case.
    var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }

    /// Access the dictionary value, if this is a .dictionary case.
    var dictionaryValue: [String: AnyCodable]? {
        if case .dictionary(let v) = self { return v }
        return nil
    }

    /// Access the array value, if this is an .array case.
    var arrayValue: [AnyCodable]? {
        if case .array(let v) = self { return v }
        return nil
    }

    /// Best-effort display conversion for heterogeneous JSON-RPC values.
    var displayString: String {
        switch self {
        case .string(let v): return v
        case .int(let v): return String(v)
        case .double(let v): return String(v)
        case .bool(let v): return String(v)
        case .null: return "null"
        case .array(let v): return v.map(\.displayString).joined(separator: ", ")
        case .dictionary(let v):
            return v
                .sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value.displayString)" }
                .joined(separator: ", ")
        }
    }
}

// MARK: - String utilities

extension String {
    /// Truncate to a maximum length, appending "…" if truncated.
    func truncated(to length: Int) -> String {
        if self.count <= length { return self }
        return String(self.prefix(length)) + "…"
    }
}

// MARK: - Test-process detection

extension ProcessInfo {
    /// True inside a unit-test runner (XCTest or swift-testing, Xcode or
    /// SwiftPM). Shared by services that must not touch process-external
    /// state under test: gateway pushes (ArtifactStore leaked test artifacts
    /// to the live store) and UNUserNotificationCenter (throws
    /// NSInternalInconsistencyException in bundle-less SwiftPM runners).
    static let isTestProcess = NSClassFromString("XCTestCase") != nil
        || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || ProcessInfo.processInfo.environment["SWIFT_TESTING_ENABLED"] == "1"
        || Bundle.main.bundlePath.hasSuffix(".xctest")
        || (Bundle.main.bundleIdentifier == nil
            && Bundle.main.bundlePath.contains("/usr/libexec/swift/pm"))
}
