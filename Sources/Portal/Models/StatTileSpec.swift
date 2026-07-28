import Foundation

/// JSON contract for ```stats fenced blocks — a KPI row of stat tiles for
/// "here are your key metrics" answers that don't warrant full charts:
/// ```json
/// {
///   "tiles": [
///     { "label": "Requests", "value": 128400,
///       "unit": "/day",                        // optional suffix
///       "delta": 12.5,                          // optional, % vs prior period
///       "deltaLabel": "vs last week",           // optional context
///       "upIsGood": true,                       // optional, default true
///       "trend": [98, 102, 110, 108, 121, 128] }// optional sparkline points
///   ]
/// }
/// ```
struct StatTileSpec: Decodable {
    struct Tile: Decodable, Identifiable {
        let label: String
        /// Numeric when possible (enables compact formatting); the model may
        /// also send a pre-formatted string ("99.97%").
        let value: TileValue
        let unit: String?
        let delta: Double?
        let deltaLabel: String?
        let upIsGood: Bool
        let trend: [Double]?

        var id: String { label }

        private enum CodingKeys: String, CodingKey {
            case label, value, unit, delta, deltaLabel, upIsGood, trend
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            label = try c.decode(String.self, forKey: .label)
            value = try c.decode(TileValue.self, forKey: .value)
            unit = try c.decodeIfPresent(String.self, forKey: .unit)
            delta = try c.decodeIfPresent(Double.self, forKey: .delta)
            deltaLabel = try c.decodeIfPresent(String.self, forKey: .deltaLabel)
            upIsGood = try c.decodeIfPresent(Bool.self, forKey: .upIsGood) ?? true
            trend = try c.decodeIfPresent([Double].self, forKey: .trend)
        }

        init(label: String, value: TileValue, unit: String? = nil, delta: Double? = nil,
             deltaLabel: String? = nil, upIsGood: Bool = true, trend: [Double]? = nil) {
            self.label = label
            self.value = value
            self.unit = unit
            self.delta = delta
            self.deltaLabel = deltaLabel
            self.upIsGood = upIsGood
            self.trend = trend
        }
    }

    /// Number or pre-formatted string.
    enum TileValue: Decodable {
        case number(Double)
        case text(String)

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let n = try? c.decode(Double.self) {
                self = .number(n)
            } else if let s = try? c.decode(String.self) {
                self = .text(s)
            } else {
                throw DecodingError.dataCorruptedError(
                    in: c, debugDescription: "value must be a number or a string"
                )
            }
        }

        /// Display form: numbers auto-compact (1,284 / 12.9K / 4.2M), strings
        /// pass through as the model formatted them.
        var display: String {
            switch self {
            case .text(let s):
                return s
            case .number(let n):
                let magnitude = abs(n)
                switch magnitude {
                case 1_000_000_000...:
                    return trimmed(n / 1_000_000_000) + "B"
                case 1_000_000...:
                    return trimmed(n / 1_000_000) + "M"
                case 10_000...:
                    return trimmed(n / 1_000) + "K"
                default:
                    if n == n.rounded() {
                        return Int(n).formatted(.number.grouping(.automatic))
                    }
                    return n.formatted(.number.precision(.fractionLength(0...2)))
                }
            }
        }

        private func trimmed(_ scaled: Double) -> String {
            scaled.formatted(.number.precision(.fractionLength(0...1)))
        }
    }

    let tiles: [Tile]

    /// Runs in the stat-tile view body; memoized so resume/scroll don't
    /// re-decode. Pure function of the source string.
    private static let parseMemo = RenderMemo<StatTileSpec?>(limit: 32)

    static func parse(_ json: String) -> StatTileSpec? {
        parseMemo.value(for: json) { parseUncached(json) }
    }

    private static func parseUncached(_ json: String) -> StatTileSpec? {
        guard let data = json.data(using: .utf8),
              let spec = try? JSONDecoder().decode(StatTileSpec.self, from: data),
              !spec.tiles.isEmpty else { return nil }
        return spec
    }
}
