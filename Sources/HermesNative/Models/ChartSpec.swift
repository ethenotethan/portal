import Foundation

/// Error surfaced to the UI when a ```chart``` JSON block fails to decode.
struct ChartSpecError: Error {
    let message: String
}

/// Heterogeneous x-axis value: LLMs emit either category labels or numbers.
enum AxisValue: Hashable, Decodable {
    case label(String)
    case number(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .label(string)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "x must be a number or a string"
            )
        }
    }

    var numberValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    /// String form for categorical axes; numbers are coerced ("2" not "2.0").
    var labelValue: String {
        switch self {
        case .label(let s):
            return s
        case .number(let n):
            if n == n.rounded(), abs(n) < 1e15 {
                return String(Int(n))
            }
            return String(n)
        }
    }
}

struct ChartPoint: Decodable {
    let x: AxisValue
    let y: Double
}

struct ChartSeries {
    let name: String
    let colorHex: String?
    let points: [ChartPoint]
}

/// JSON contract for ```chart``` fenced blocks emitted by the assistant:
/// ```json
/// {
///   "type": "bar" | "line" | "area" | "scatter" | "pie",
///   "title": "optional", "xLabel": "optional", "yLabel": "optional",
///   "stacked": false,
///   "series": [
///     { "name": "Series A", "color": "#7c7cff",
///       "points": [ {"x": "Jan", "y": 12.5}, {"x": 2, "y": 3} ] }
///   ]
/// }
/// ```
struct ChartSpec: Decodable {
    enum ChartType: String {
        case bar, line, area, scatter, pie
    }

    let type: ChartType
    let title: String?
    let xLabel: String?
    let yLabel: String?
    let stacked: Bool
    let series: [ChartSeries]

    /// True only when every point in every series has a numeric x.
    /// Any string (or mixed) x means the axis is treated as categorical.
    var isNumericX: Bool {
        series.allSatisfy { $0.points.allSatisfy { $0.x.numberValue != nil } }
    }

    private enum CodingKeys: String, CodingKey {
        case type, title, xLabel, yLabel, stacked, series
    }

    private struct RawSeries: Decodable {
        let name: String?
        let color: String?
        let points: [ChartPoint]
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let typeString = try container.decode(String.self, forKey: .type)
        let normalized = typeString.trimmingCharacters(in: .whitespaces).lowercased()
        guard let chartType = ChartType(rawValue: normalized) else {
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "Unknown chart type '\(typeString)' — expected bar, line, area, scatter, or pie"
            )
        }
        type = chartType
        title = try container.decodeIfPresent(String.self, forKey: .title)
        xLabel = try container.decodeIfPresent(String.self, forKey: .xLabel)
        yLabel = try container.decodeIfPresent(String.self, forKey: .yLabel)
        stacked = try container.decodeIfPresent(Bool.self, forKey: .stacked) ?? false

        let raw = try container.decode([RawSeries].self, forKey: .series)
        guard !raw.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .series, in: container,
                debugDescription: "Chart has no series"
            )
        }
        series = try raw.enumerated().map { index, s in
            let name = (s.name?.isEmpty == false) ? s.name! : "Series \(index + 1)"
            guard !s.points.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .series, in: container,
                    debugDescription: "Series '\(name)' has no points"
                )
            }
            return ChartSeries(name: name, colorHex: s.color, points: s.points)
        }
    }

    static func parse(_ json: String) -> Result<ChartSpec, ChartSpecError> {
        guard let data = json.data(using: .utf8) else {
            return .failure(ChartSpecError(message: "Chart spec is not valid UTF-8"))
        }
        do {
            return .success(try JSONDecoder().decode(ChartSpec.self, from: data))
        } catch let error as DecodingError {
            return .failure(ChartSpecError(message: describe(error)))
        } catch {
            return .failure(ChartSpecError(message: error.localizedDescription))
        }
    }

    /// Cheap structural sniff for streaming gating — not a validity check.
    static func looksLikeChartJSON(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("{")
            && trimmed.contains("\"type\"")
            && trimmed.contains("\"series\"")
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let joined = context.codingPath
                .map { key in key.intValue.map { "[\($0)]" } ?? key.stringValue }
                .joined(separator: ".")
                .replacingOccurrences(of: ".[", with: "[")
            return joined.isEmpty ? "" : " at \(joined)"
        }
        switch error {
        case .keyNotFound(let key, let context):
            return "Missing key '\(key.stringValue)'\(path(context))"
        case .valueNotFound(_, let context):
            return "Missing value\(path(context))"
        case .typeMismatch(_, let context):
            return "\(context.debugDescription)\(path(context))"
        case .dataCorrupted(let context):
            let detail = context.debugDescription
            return detail.isEmpty ? "Malformed JSON" : detail
        @unknown default:
            return "Could not decode chart spec"
        }
    }
}
