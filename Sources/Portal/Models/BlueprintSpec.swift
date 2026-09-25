import Foundation

/// JSON contract for native ```blueprint fenced blocks. Coordinates and sizes
/// live in a declared logical canvas (100 × 100 by default), which gives the
/// author deterministic placement instead of asking a graph layout to infer it.
internal struct BlueprintSpec: Decodable {
    internal enum ElementKind: String, Decodable {
        case generic
        case boundary
        case service
        case storage
        case actor
        case note

        internal init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
            self = Self(rawValue: value.lowercased()) ?? .generic
        }
    }

    internal enum ConnectionStyle: String, Decodable {
        case flow
        case data
        case dependency
        case physical

        internal init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
            self = Self(rawValue: value.lowercased()) ?? .flow
        }
    }

    internal struct Element: Identifiable {
        internal let id: String
        internal let label: String
        internal let x: Double
        internal let y: Double
        internal let width: Double
        internal let height: Double
        internal let kind: ElementKind
        internal let note: String?

        fileprivate init?(raw: RawElement, canvasWidth: Double, canvasHeight: Double) {
            let cleanID = raw.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanID.isEmpty else { return nil }
            id = cleanID
            let cleanLabel = raw.label?.trimmingCharacters(in: .whitespacesAndNewlines)
            label = cleanLabel.flatMap { $0.isEmpty ? nil : $0 } ?? cleanID
            x = Self.clamp(raw.x ?? 0, minimum: 0, maximum: max(0, canvasWidth - 1))
            y = Self.clamp(raw.y ?? 0, minimum: 0, maximum: max(0, canvasHeight - 1))
            width = Self.clamp(raw.width ?? 12, minimum: 1, maximum: canvasWidth)
            height = Self.clamp(raw.height ?? 8, minimum: 1, maximum: canvasHeight)
            kind = raw.kind ?? .generic
            note = raw.note
        }

        private static func clamp(_ value: Double, minimum: Double, maximum: Double) -> Double {
            guard value.isFinite else { return minimum }
            return min(maximum, max(minimum, value))
        }
    }

    internal struct Connection: Decodable {
        internal let from: String
        internal let to: String
        internal let label: String?
        internal let style: ConnectionStyle
        internal let hasArrow: Bool

        private enum CodingKeys: String, CodingKey {
            case from, to, label, style, arrow
        }

        internal init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            from = try container.decode(String.self, forKey: .from)
            to = try container.decode(String.self, forKey: .to)
            label = try container.decodeIfPresent(String.self, forKey: .label)
            style = try container.decodeIfPresent(ConnectionStyle.self, forKey: .style) ?? .flow
            hasArrow = try container.decodeIfPresent(Bool.self, forKey: .arrow) ?? true
        }
    }

    internal let title: String?
    internal let canvasWidth: Double
    internal let canvasHeight: Double
    internal let showsGrid: Bool
    internal let elements: [Element]
    internal let connections: [Connection]

    private enum CodingKeys: String, CodingKey {
        case title, width, height, grid, elements, connections
    }

    internal init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        let decodedWidth = Self.dimension(try container.decodeIfPresent(Double.self, forKey: .width) ?? 100)
        let decodedHeight = Self.dimension(try container.decodeIfPresent(Double.self, forKey: .height) ?? 100)
        canvasWidth = decodedWidth
        canvasHeight = decodedHeight
        showsGrid = try container.decodeIfPresent(Bool.self, forKey: .grid) ?? true

        let rawElements = try container.decodeIfPresent([RawElement].self, forKey: .elements) ?? []
        var seen = Set<String>()
        elements = rawElements.compactMap { raw in
            guard let element = Element(raw: raw, canvasWidth: decodedWidth, canvasHeight: decodedHeight),
                  seen.insert(element.id).inserted else { return nil }
            return element
        }

        let ids = seen
        let rawConnections = try container.decodeIfPresent([Connection].self, forKey: .connections) ?? []
        connections = rawConnections.filter { ids.contains($0.from) && ids.contains($0.to) && $0.from != $0.to }
    }

    private static let parseMemo = RenderMemo<BlueprintSpec?>(limit: 32)

    internal static func parse(_ json: String) -> BlueprintSpec? {
        parseMemo.value(for: json) {
            guard let data = json.data(using: .utf8) else { return nil }
            do {
                let spec = try JSONDecoder().decode(BlueprintSpec.self, from: data)
                return spec.elements.isEmpty ? nil : spec
            } catch {
                return nil
            }
        }
    }

    private static func dimension(_ value: Double) -> Double {
        guard value.isFinite else { return 100 }
        return min(1_000, max(10, value))
    }

    fileprivate struct RawElement: Decodable {
        fileprivate let id: String
        fileprivate let label: String?
        fileprivate let x: Double?
        fileprivate let y: Double?
        fileprivate let width: Double?
        fileprivate let height: Double?
        fileprivate let kind: ElementKind?
        fileprivate let note: String?
    }
}
