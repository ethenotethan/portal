import Foundation

/// Parse a UTF-8 JSON string into a `[String: Any]`, or nil if it isn't valid
/// JSON / isn't a top-level object. A do/catch wrapper around
/// `JSONSerialization` so structured-artifact specs share one error-swallowing
/// site instead of each opening its own. Malformed input yielding nil is the
/// intended, explicit contract here.
internal enum JSONObjectParse {
    internal static func object(from json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        do {
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            return nil
        }
    }
}
