import SwiftUI
import Charts

/// Renders a ```chart``` fenced block (JSON spec) as a native Swift Charts view.
/// While streaming, unparseable JSON shows a placeholder instead of an error.
struct NativeChartView: View {
    let json: String
    let isStreaming: Bool

    init(json: String, isStreaming: Bool) {
        self.json = json
        self.isStreaming = isStreaming
    }

    var body: some View {
        switch ChartSpec.parse(json) {
        case .success(let spec):
            ChartCard(spec: spec)
        case .failure(let error):
            if isStreaming {
                StreamingPlaceholder()
            } else {
                ChartErrorCard(message: error.message, source: json)
            }
        }
    }
}

// MARK: - Chart Card

private struct ChartCard: View {
    let spec: ChartSpec
    private let numericX: Bool
    private let grouped: Bool

    @State private var selectedNumericX: Double?
    @State private var selectedCategoryX: String?

    init(spec: ChartSpec) {
        self.spec = spec
        self.numericX = spec.isNumericX
        self.grouped = !spec.stacked && spec.series.count > 1
    }

    private var xKey: String { spec.xLabel ?? "x" }
    private var yKey: String { spec.yLabel ?? "Value" }

    private var legendVisible: Bool {
        spec.type == .pie || spec.series.count > 1
    }

    /// Honored only when every series declares a parseable hex color.
    private var seriesColors: [Color]? {
        guard spec.type != .pie else { return nil }
        let colors = spec.series.compactMap { $0.colorHex.flatMap { Color(hex: $0) } }
        return colors.count == spec.series.count ? colors : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = spec.title {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Theme.primary)
            }
            styledChart
                .frame(height: 280)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .topTrailing) {
                    if let readout {
                        ReadoutCapsule(readout: readout)
                    }
                }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.border, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var styledChart: some View {
        if let colors = seriesColors {
            selectableChart
                .chartForegroundStyleScale(domain: spec.series.map(\.name), range: colors)
        } else {
            selectableChart
        }
    }

    @ViewBuilder
    private var selectableChart: some View {
        if spec.type == .pie {
            baseChart
        } else if numericX {
            baseChart.chartXSelection(value: $selectedNumericX)
        } else {
            baseChart.chartXSelection(value: $selectedCategoryX)
        }
    }

    private var baseChart: some View {
        Chart {
            content
        }
        .chartPlotStyle { $0.background(Color.clear) }
        .chartLegend(legendVisible ? .visible : .hidden)
        .chartXAxis {
            AxisMarks { _ in
                AxisGridLine().foregroundStyle(Theme.border.opacity(0.6))
                AxisTick().foregroundStyle(Theme.border)
                AxisValueLabel().foregroundStyle(Theme.secondary)
            }
        }
        .chartYAxis {
            AxisMarks { _ in
                AxisGridLine().foregroundStyle(Theme.border.opacity(0.6))
                AxisTick().foregroundStyle(Theme.border)
                AxisValueLabel().foregroundStyle(Theme.secondary)
            }
        }
        .chartXAxisLabel(position: .bottom, alignment: .center) {
            if let label = spec.xLabel {
                Text(label).font(.caption2).foregroundStyle(Theme.secondary)
            }
        }
        .chartYAxisLabel(position: .leading, alignment: .center) {
            if let label = spec.yLabel {
                Text(label).font(.caption2).foregroundStyle(Theme.secondary)
            }
        }
    }

    // MARK: Marks

    @ChartContentBuilder
    private var content: some ChartContent {
        if spec.type == .pie {
            pieMarks
        } else {
            ForEach(spec.series.indices, id: \.self) { s in
                let series = spec.series[s]
                ForEach(series.points.indices, id: \.self) { i in
                    xyMarks(series.points[i], series: series)
                }
            }
        }
    }

    @ChartContentBuilder
    private var pieMarks: some ChartContent {
        let points = spec.series[0].points
        ForEach(points.indices, id: \.self) { i in
            SectorMark(
                angle: .value(yKey, points[i].y),
                innerRadius: .ratio(0.55),
                angularInset: 1.5
            )
            .foregroundStyle(by: .value("Category", points[i].x.labelValue))
        }
    }

    @ChartContentBuilder
    private func xyMarks(_ point: ChartPoint, series: ChartSeries) -> some ChartContent {
        switch spec.type {
        case .bar:
            barMark(point, series: series)
        case .line:
            lineMark(point, series: series)
        case .area:
            areaMarks(point, series: series)
        case .scatter, .pie: // .pie unreachable, handled above
            pointMark(point, series: series)
        }
    }

    @ChartContentBuilder
    private func barMark(_ point: ChartPoint, series: ChartSeries) -> some ChartContent {
        let mark = numericX
            ? BarMark(x: .value(xKey, point.x.numberValue ?? 0), y: .value(yKey, point.y))
            : BarMark(x: .value(xKey, point.x.labelValue), y: .value(yKey, point.y))
        if grouped {
            mark
                .foregroundStyle(by: .value("Series", series.name))
                .position(by: .value("Series", series.name))
        } else {
            mark
                .foregroundStyle(by: .value("Series", series.name))
        }
    }

    @ChartContentBuilder
    private func lineMark(_ point: ChartPoint, series: ChartSeries) -> some ChartContent {
        let mark = numericX
            ? LineMark(x: .value(xKey, point.x.numberValue ?? 0), y: .value(yKey, point.y))
            : LineMark(x: .value(xKey, point.x.labelValue), y: .value(yKey, point.y))
        mark
            .foregroundStyle(by: .value("Series", series.name))
            .symbol(.circle)
            .interpolationMethod(.catmullRom)
    }

    @ChartContentBuilder
    private func areaMarks(_ point: ChartPoint, series: ChartSeries) -> some ChartContent {
        let stacking: MarkStackingMethod = spec.stacked ? .standard : .unstacked
        if numericX {
            AreaMark(x: .value(xKey, point.x.numberValue ?? 0), y: .value(yKey, point.y), stacking: stacking)
                .foregroundStyle(by: .value("Series", series.name))
                .opacity(0.3)
                .interpolationMethod(.catmullRom)
        } else {
            AreaMark(x: .value(xKey, point.x.labelValue), y: .value(yKey, point.y), stacking: stacking)
                .foregroundStyle(by: .value("Series", series.name))
                .opacity(0.3)
                .interpolationMethod(.catmullRom)
        }
        if !spec.stacked || spec.series.count == 1 {
            let line = numericX
                ? LineMark(x: .value(xKey, point.x.numberValue ?? 0), y: .value(yKey, point.y))
                : LineMark(x: .value(xKey, point.x.labelValue), y: .value(yKey, point.y))
            line
                .foregroundStyle(by: .value("Series", series.name))
                .interpolationMethod(.catmullRom)
        }
    }

    @ChartContentBuilder
    private func pointMark(_ point: ChartPoint, series: ChartSeries) -> some ChartContent {
        let mark = numericX
            ? PointMark(x: .value(xKey, point.x.numberValue ?? 0), y: .value(yKey, point.y))
            : PointMark(x: .value(xKey, point.x.labelValue), y: .value(yKey, point.y))
        mark.foregroundStyle(by: .value("Series", series.name))
    }

    // MARK: Selection readout

    private var readout: ChartReadout? {
        if numericX {
            guard let sel = selectedNumericX else { return nil }
            let allXs = spec.series.flatMap { $0.points.compactMap(\.x.numberValue) }
            guard let nearest = allXs.min(by: { abs($0 - sel) < abs($1 - sel) }) else { return nil }
            let entries = spec.series.compactMap { series -> (String, String)? in
                guard let p = series.points.first(where: { $0.x.numberValue == nearest }) else { return nil }
                return (series.name, fmt(p.y))
            }
            guard !entries.isEmpty else { return nil }
            return ChartReadout(title: fmt(nearest), entries: entries)
        } else {
            guard let sel = selectedCategoryX else { return nil }
            let entries = spec.series.compactMap { series -> (String, String)? in
                guard let p = series.points.first(where: { $0.x.labelValue == sel }) else { return nil }
                return (series.name, fmt(p.y))
            }
            guard !entries.isEmpty else { return nil }
            return ChartReadout(title: sel, entries: entries)
        }
    }

    private func fmt(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }
}

// MARK: - Readout

private struct ChartReadout {
    let title: String
    let entries: [(String, String)]
}

private struct ReadoutCapsule: View {
    let readout: ChartReadout

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(readout.title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.primary)
            ForEach(readout.entries.indices, id: \.self) { i in
                Text("\(readout.entries[i].0): \(readout.entries[i].1)")
                    .font(.caption2)
                    .foregroundStyle(Theme.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.background.opacity(0.92), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.border, lineWidth: 0.5)
        )
        .padding(6)
        .allowsHitTesting(false)
    }
}

// MARK: - Streaming Placeholder

private struct StreamingPlaceholder: View {
    var body: some View {
        VStack(spacing: 8) {
            HermesProgressView()
            Text("Building chart…")
                .font(.caption2)
                .foregroundStyle(Theme.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.border, lineWidth: 0.5)
        )
    }
}

// MARK: - Error Card

private struct ChartErrorCard: View {
    let message: String
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("Chart parse failed")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }

            Text(message)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Theme.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
                .overlay(Theme.border.opacity(0.5))

            Text(source)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Theme.tertiary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(8)
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }
}
