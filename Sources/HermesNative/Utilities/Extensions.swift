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
}

// MARK: - String utilities

extension String {
    /// Truncate to a maximum length, appending "…" if truncated.
    func truncated(to length: Int) -> String {
        if self.count <= length { return self }
        return String(self.prefix(length)) + "…"
    }
}
