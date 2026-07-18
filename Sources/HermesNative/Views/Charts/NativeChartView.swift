import SwiftUI
import Charts

/// Renders a ```chart``` fenced block (JSON spec) as a native Swift Charts view.
/// While streaming, unparseable JSON shows a placeholder instead of an error.
///
/// Interactive by default: hover/drag tooltips with a crosshair, tappable
/// legend chips that toggle series, and pinch-zoom + scroll on numeric x-axes
/// (double-tap resets). Pass `interactive: false` for static contexts —
/// SessionPDFExporter renders through ImageRenderer, which rasterizes the
/// scrollable-axis plot (a scroll view) as an empty box.
struct NativeChartView: View {
    let json: String
    let isStreaming: Bool
    var interactive: Bool = true

    init(json: String, isStreaming: Bool, interactive: Bool = true) {
        self.json = json
        self.isStreaming = isStreaming
        self.interactive = interactive
    }

    var body: some View {
        switch ChartSpec.parse(json) {
        case .success(let spec):
            ChartCard(spec: spec, interactive: interactive)
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
    let interactive: Bool
    private let numericX: Bool
    private let grouped: Bool

    @State private var selectedNumericX: Double?
    @State private var selectedCategoryX: String?
    @State private var selectedPieAngle: Double?
    /// Series (or pie categories) hidden via the legend chips.
    @State private var hiddenSeries: Set<String> = []
    /// Visible x-span while pinch-zoomed; nil = full domain, no scrolling.
    @State private var visibleDomainLength: Double?
    /// visibleDomainLength at pinch start, so the gesture scales from a
    /// stable base instead of compounding every frame.
    @State private var zoomGestureBase: Double?

    /// Categorical fallback colors — the dataviz reference palette's dark
    /// column, validated against Theme.surface (#2a2a2a): CVD-safe adjacent
    /// pairs, normal-vision floor passed. Slot order is the safety mechanism;
    /// do not reorder. Green's 2.9:1 contrast WARN is relieved by the
    /// readout/tooltip carrying every value.
    private static let fallbackPalette: [Color] = [
        "#3987e5", "#008300", "#d55181", "#c98500",
        "#199e70", "#d95926", "#9085e9", "#e66767",
    ].compactMap { Color(hex: $0) }

    init(spec: ChartSpec, interactive: Bool) {
        self.spec = spec
        self.interactive = interactive
        self.numericX = spec.isNumericX
        self.grouped = !spec.stacked && spec.series.count > 1
    }

    private var xKey: String { spec.xLabel ?? "x" }
    private var yKey: String { spec.yLabel ?? "Value" }

    /// Legend entries: series names, or slice categories for pie.
    /// Order-preserving and deduplicated (pie categories can repeat).
    private var legendNames: [String] {
        if spec.type == .pie {
            var seen = Set<String>()
            return spec.series[0].points.map(\.x.labelValue).filter { seen.insert($0).inserted }
        }
        return spec.series.map(\.name)
    }

    private var legendVisible: Bool {
        spec.type == .pie || spec.series.count > 1
    }

    /// Color per legend entry. Explicit hex wins when every series declares
    /// one; otherwise the validated fallback palette by slot. Colors are keyed
    /// to the full entry list (not the visible subset) so toggling a series
    /// never repaints the survivors.
    private var legendColors: [Color] {
        if spec.type != .pie {
            let declared = spec.series.compactMap { $0.colorHex.flatMap { Color(hex: $0) } }
            if declared.count == spec.series.count { return declared }
        }
        return legendNames.indices.map { index in
            let slot = Self.fallbackPalette[index % Self.fallbackPalette.count]
            // Slots past the validated 8 reuse hues at reduced opacity — a
            // last resort; realistic chat charts stay well under 8 series.
            return index < Self.fallbackPalette.count ? slot : slot.opacity(0.65)
        }
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
                .overlay(alignment: .bottomTrailing) {
                    if visibleDomainLength != nil {
                        ZoomResetBadge { visibleDomainLength = nil }
                    }
                }
            if legendVisible {
                legendChips
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.border, lineWidth: 0.5)
        )
    }

    // MARK: Chart assembly

    private var styledChart: some View {
        zoomableChart
            .chartForegroundStyleScale(domain: legendNames, range: legendColors)
    }

    /// Pinch-zoom applies only to numeric x-axes: chartXVisibleDomain needs a
    /// numeric span, and categorical axes are short enough not to need it.
    @ViewBuilder
    private var zoomableChart: some View {
        if interactive, numericX, spec.type != .pie, let span = fullXSpan {
            if let length = visibleDomainLength {
                selectableChart
                    .chartScrollableAxes(.horizontal)
                    .chartXVisibleDomain(length: length)
                    .simultaneousGesture(zoomGesture(fullSpan: span))
                    .onTapGesture(count: 2) { visibleDomainLength = nil }
                    .help("Pinch to zoom · double-tap to reset")
            } else {
                selectableChart
                    .simultaneousGesture(zoomGesture(fullSpan: span))
                    .help("Pinch to zoom the x-axis")
            }
        } else {
            selectableChart
        }
    }

    @ViewBuilder
    private var selectableChart: some View {
        if !interactive {
            baseChart
        } else if spec.type == .pie {
            baseChart.chartAngleSelection(value: $selectedPieAngle)
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
        // Legend identity lives in the tappable chips below the plot; the
        // built-in legend would duplicate it (and can't toggle).
        .chartLegend(.hidden)
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

    // MARK: Zoom

    /// Full numeric x extent across all series; nil when degenerate.
    private var fullXSpan: Double? {
        let xs = spec.series.flatMap { $0.points.compactMap(\.x.numberValue) }
        guard let lo = xs.min(), let hi = xs.max(), hi > lo else { return nil }
        return hi - lo
    }

    private func zoomGesture(fullSpan: Double) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = zoomGestureBase ?? (visibleDomainLength ?? fullSpan)
                zoomGestureBase = base
                let proposed = base / max(0.01, value.magnification)
                let clamped = min(max(proposed, fullSpan / 50), fullSpan)
                visibleDomainLength = clamped >= fullSpan ? nil : clamped
            }
            .onEnded { _ in zoomGestureBase = nil }
    }

    // MARK: Marks

    @ChartContentBuilder
    private var content: some ChartContent {
        if spec.type == .pie {
            pieMarks
        } else {
            ForEach(spec.series.indices, id: \.self) { s in
                let series = spec.series[s]
                if !hiddenSeries.contains(series.name) {
                    ForEach(series.points.indices, id: \.self) { i in
                        xyMarks(series.points[i], series: series)
                    }
                }
            }
            crosshair
        }
    }

    /// Vertical hairline at the selection so the reader sees which x the
    /// readout describes. Lines/areas/scatter only — on bars the mark itself
    /// is the hit target and a crosshair would just overpaint it.
    @ChartContentBuilder
    private var crosshair: some ChartContent {
        if interactive, spec.type != .bar {
            if numericX, let x = nearestNumericX {
                RuleMark(x: .value(xKey, x))
                    .foregroundStyle(Theme.tertiary.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            } else if !numericX, let x = selectedCategoryX {
                RuleMark(x: .value(xKey, x))
                    .foregroundStyle(Theme.tertiary.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
    }

    @ChartContentBuilder
    private var pieMarks: some ChartContent {
        let points = spec.series[0].points
        let selected = selectedPieCategory
        ForEach(points.indices, id: \.self) { i in
            let category = points[i].x.labelValue
            if !hiddenSeries.contains(category) {
                SectorMark(
                    angle: .value(yKey, points[i].y),
                    innerRadius: .ratio(0.55),
                    angularInset: 1.5
                )
                .foregroundStyle(by: .value("Category", category))
                .opacity(selected == nil || selected == category ? 1 : 0.45)
            }
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

    // MARK: Legend chips

    private var legendChips: some View {
        ChipFlowLayout(spacing: 6) {
            ForEach(Array(legendNames.enumerated()), id: \.element) { index, name in
                LegendChip(
                    name: name,
                    color: legendColors[index],
                    swatch: swatchShape,
                    isHidden: hiddenSeries.contains(name),
                    interactive: interactive
                ) {
                    if hiddenSeries.contains(name) {
                        hiddenSeries.remove(name)
                    } else {
                        hiddenSeries.insert(name)
                    }
                }
            }
        }
    }

    /// Legend mirrors the mark: a line key for line/scatter, a filled rect
    /// for bars, areas, and pie slices.
    private var swatchShape: LegendChip.Swatch {
        switch spec.type {
        case .line, .scatter: return .line
        case .bar, .area, .pie: return .rect
        }
    }

    // MARK: Selection readout

    private var nearestNumericX: Double? {
        guard numericX, let sel = selectedNumericX else { return nil }
        let allXs = visibleSeries.flatMap { $0.points.compactMap(\.x.numberValue) }
        return allXs.min(by: { abs($0 - sel) < abs($1 - sel) })
    }

    private var visibleSeries: [ChartSeries] {
        spec.series.filter { !hiddenSeries.contains($0.name) }
    }

    /// Pie slice under the pointer: chartAngleSelection yields a value in the
    /// cumulative y domain of the *rendered* (visible) slices, in point order.
    private var selectedPieCategory: String? {
        guard spec.type == .pie, let angle = selectedPieAngle else { return nil }
        var cumulative = 0.0
        for point in spec.series[0].points where !hiddenSeries.contains(point.x.labelValue) {
            cumulative += point.y
            if angle <= cumulative { return point.x.labelValue }
        }
        return nil
    }

    private var readout: ChartReadout? {
        guard interactive else { return nil }
        if spec.type == .pie {
            guard let category = selectedPieCategory else { return nil }
            let points = spec.series[0].points.filter { !hiddenSeries.contains($0.x.labelValue) }
            guard let point = points.first(where: { $0.x.labelValue == category }) else { return nil }
            let total = points.map(\.y).reduce(0, +)
            let share = total > 0 ? " (\((point.y / total).formatted(.percent.precision(.fractionLength(0...1)))))" : ""
            return ChartReadout(title: category, entries: [(category, fmt(point.y) + share)])
        }
        if numericX {
            guard let nearest = nearestNumericX else { return nil }
            let entries = visibleSeries.compactMap { series -> (String, String)? in
                guard let p = series.points.first(where: { $0.x.numberValue == nearest }) else { return nil }
                return (series.name, fmt(p.y))
            }
            guard !entries.isEmpty else { return nil }
            return ChartReadout(title: fmt(nearest), entries: entries)
        } else {
            guard let sel = selectedCategoryX else { return nil }
            let entries = visibleSeries.compactMap { series -> (String, String)? in
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

// MARK: - Legend chip

private struct LegendChip: View {
    enum Swatch { case line, rect }

    let name: String
    let color: Color
    let swatch: Swatch
    let isHidden: Bool
    let interactive: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            switch swatch {
            case .line:
                RoundedRectangle(cornerRadius: 1)
                    .fill(color)
                    .frame(width: 12, height: 2)
            case .rect:
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: 8, height: 8)
            }
            Text(name)
                .font(.caption2)
                .foregroundStyle(isHidden ? Theme.tertiary : Theme.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Theme.surfaceHover.opacity(isHidden ? 0.3 : 0.6), in: Capsule())
        .opacity(isHidden ? 0.5 : 1)
        .contentShape(Capsule())
        .onTapGesture {
            guard interactive else { return }
            toggle()
        }
        .help(interactive ? (isHidden ? "Show \(name)" : "Hide \(name)") : name)
        .accessibilityLabel("\(name)\(isHidden ? ", hidden" : "")")
        .accessibilityAddTraits(interactive ? .isButton : [])
    }
}

/// Minimal wrapping row for legend chips — plain Layout, no ScrollView, so
/// ImageRenderer (PDF export) rasterizes it correctly.
private struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
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
            // Values lead, labels follow: the reader has the series and
            // wants the number.
            ForEach(readout.entries.indices, id: \.self) { i in
                HStack(spacing: 4) {
                    Text(readout.entries[i].1)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.primary)
                    Text(readout.entries[i].0)
                        .font(.caption2)
                        .foregroundStyle(Theme.secondary)
                }
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

// MARK: - Zoom reset badge

private struct ZoomResetBadge: View {
    let reset: () -> Void

    var body: some View {
        Button(action: reset) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.down.left.and.arrow.up.right")
                    .font(.system(size: 8, weight: .semibold))
                Text("Reset zoom")
                    .font(.caption2)
            }
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.background.opacity(0.92), in: Capsule())
            .overlay(Capsule().stroke(Theme.border, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .padding(6)
        .help("Reset zoom (or double-tap the chart)")
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
