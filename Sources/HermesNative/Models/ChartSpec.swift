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
    /// Heatmap row category (`"y"` in heatmap points is the row label, so the
    /// magnitude moves to `"v"`). nil for every other chart type.
    let row: String?
    /// Heatmap cell magnitude. nil for every other chart type.
    let value: Double?

    private enum CodingKeys: String, CodingKey {
        case x, y, v
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = try c.decode(AxisValue.self, forKey: .x)
        // Heatmap contract: {"x": "Mon", "y": "Week 1", "v": 12} — y is the
        // row CATEGORY and v the magnitude. Everything else: {"x": …, "y": 3}.
        if let magnitude = try c.decodeIfPresent(Double.self, forKey: .v) {
            let rowValue = try c.decode(AxisValue.self, forKey: .y)
            row = rowValue.labelValue
            value = magnitude
            y = magnitude
        } else {
            y = try c.decode(Double.self, forKey: .y)
            row = nil
            value = nil
        }
    }

    init(x: AxisValue, y: Double, row: String? = nil, value: Double? = nil) {
        self.x = x
        self.y = y
        self.row = row
        self.value = value
    }
}

struct ChartSeries {
    let name: String
    let colorHex: String?
    let points: [ChartPoint]
    /// Raw sample values for distribution charts (histogram, boxplot) —
    /// the client bins/summarizes so the LLM never emits derived stats.
    let values: [Double]
}

/// JSON contract for ```chart``` fenced blocks emitted by the assistant:
/// ```json
/// {
///   "type": "bar" | "line" | "area" | "scatter" | "pie"
///         | "heatmap" | "histogram" | "boxplot",
///   "title": "optional", "xLabel": "optional", "yLabel": "optional",
///   "stacked": false,
///   "bins": 12,                       // histogram only, optional
///   "series": [
///     { "name": "Series A", "color": "#7c7cff",
///       "points": [ {"x": "Jan", "y": 12.5}, {"x": 2, "y": 3} ] },
///     { "name": "Latency",                     // histogram / boxplot
///       "values": [12.1, 13.4, 11.8, 55.0] },
///     { "name": "Activity",                    // heatmap
///       "points": [ {"x": "Mon", "y": "Week 1", "v": 4} ] }
///   ]
/// }
/// ```
struct ChartSpec: Decodable {
    enum ChartType: String {
        case bar, line, area, scatter, pie, heatmap, histogram, boxplot
    }

    let type: ChartType
    let title: String?
    let xLabel: String?
    let yLabel: String?
    let stacked: Bool
    /// Histogram bin count; nil = Sturges' rule from the sample size.
    let bins: Int?
    let series: [ChartSeries]

    /// Chart types whose series carry raw `values` instead of points.
    var isDistribution: Bool {
        type == .histogram || type == .boxplot
    }

    /// True only when every point in every series has a numeric x.
    /// Any string (or mixed) x means the axis is treated as categorical.
    var isNumericX: Bool {
        series.allSatisfy { $0.points.allSatisfy { $0.x.numberValue != nil } }
    }

    private enum CodingKeys: String, CodingKey {
        case type, title, xLabel, yLabel, stacked, bins, series
    }

    private struct RawSeries: Decodable {
        let name: String?
        let color: String?
        let points: [ChartPoint]?
        let values: [Double]?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let typeString = try container.decode(String.self, forKey: .type)
        let normalized = typeString.trimmingCharacters(in: .whitespaces).lowercased()
        guard let chartType = ChartType(rawValue: normalized) else {
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "Unknown chart type '\(typeString)' — expected bar, line, area, scatter, pie, heatmap, histogram, or boxplot"
            )
        }
        type = chartType
        title = try container.decodeIfPresent(String.self, forKey: .title)
        xLabel = try container.decodeIfPresent(String.self, forKey: .xLabel)
        yLabel = try container.decodeIfPresent(String.self, forKey: .yLabel)
        stacked = try container.decodeIfPresent(Bool.self, forKey: .stacked) ?? false
        bins = try container.decodeIfPresent(Int.self, forKey: .bins)

        let raw = try container.decode([RawSeries].self, forKey: .series)
        guard !raw.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .series, in: container,
                debugDescription: "Chart has no series"
            )
        }
        let distribution = chartType == .histogram || chartType == .boxplot
        series = try raw.enumerated().map { index, s in
            let name = (s.name?.isEmpty == false) ? s.name! : "Series \(index + 1)"
            if distribution {
                // Accept `values`, or degrade points to their y values so a
                // model that emitted points anyway still renders.
                let values = s.values ?? s.points?.map(\.y) ?? []
                guard !values.isEmpty else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .series, in: container,
                        debugDescription: "Series '\(name)' has no values — \(normalized) series need a \"values\" array"
                    )
                }
                return ChartSeries(name: name, colorHex: s.color, points: [], values: values)
            }
            guard let points = s.points, !points.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .series, in: container,
                    debugDescription: "Series '\(name)' has no points"
                )
            }
            if chartType == .heatmap {
                guard points.allSatisfy({ $0.row != nil }) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .series, in: container,
                        debugDescription: "Series '\(name)': heatmap points need {\"x\", \"y\", \"v\"} (y = row category, v = value)"
                    )
                }
            }
            return ChartSeries(name: name, colorHex: s.color, points: points, values: [])
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

// MARK: - Distribution statistics

/// Client-side binning and five-number summaries so distribution charts
/// take raw samples, not derived stats.
enum ChartDistribution {

    struct Bin: Identifiable {
        let lowerBound: Double
        let upperBound: Double
        let count: Int
        var id: Double { lowerBound }
        var midpoint: Double { (lowerBound + upperBound) / 2 }
    }

    struct FiveNumber {
        let min: Double
        let q1: Double
        let median: Double
        let q3: Double
        let max: Double
    }

    /// Equal-width bins over [min, max]. `count` nil → Sturges' rule.
    static func bins(for values: [Double], count: Int? = nil) -> [Bin] {
        guard let lo = values.min(), let hi = values.max(), !values.isEmpty else { return [] }
        let n = max(1, count ?? Int(ceil(log2(Double(values.count)) + 1)))
        guard hi > lo else {
            return [Bin(lowerBound: lo, upperBound: hi, count: values.count)]
        }
        let width = (hi - lo) / Double(n)
        var counts = [Int](repeating: 0, count: n)
        for v in values {
            // Top edge belongs to the last bin.
            let idx = min(n - 1, Int((v - lo) / width))
            counts[idx] += 1
        }
        return counts.enumerated().map { i, c in
            Bin(lowerBound: lo + Double(i) * width,
                upperBound: lo + Double(i + 1) * width,
                count: c)
        }
    }

    /// Five-number summary with linear-interpolation quartiles (R-7).
    static func fiveNumber(for values: [Double]) -> FiveNumber? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        func quantile(_ q: Double) -> Double {
            let pos = q * Double(sorted.count - 1)
            let lower = Int(pos.rounded(.down))
            let upper = Int(pos.rounded(.up))
            let frac = pos - Double(lower)
            return sorted[lower] * (1 - frac) + sorted[upper] * frac
        }
        return FiveNumber(
            min: sorted.first!,
            q1: quantile(0.25),
            median: quantile(0.5),
            q3: quantile(0.75),
            max: sorted.last!
        )
    }
}
