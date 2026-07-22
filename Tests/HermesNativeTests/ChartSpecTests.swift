import Testing
import Foundation
@testable import HermesNative

@Suite("Chart Spec")
struct ChartSpecTests {

    private func parse(_ json: String) -> Result<ChartSpec, ChartSpecError> {
        ChartSpec.parse(json)
    }

    @Test("Existing xy types still parse (regression)")
    func xyStillParses() {
        let result = parse("""
        {"type": "line", "series": [
          {"name": "A", "points": [{"x": 1, "y": 2}, {"x": "Feb", "y": 3}]}
        ]}
        """)
        guard case .success(let spec) = result else {
            Issue.record("parse failed")
            return
        }
        #expect(spec.type == .line)
        #expect(!spec.isNumericX) // mixed x → categorical
        #expect(spec.series[0].points.count == 2)
    }

    @Test("Heatmap points carry row category and magnitude")
    func heatmapParses() {
        let result = parse("""
        {"type": "heatmap", "series": [
          {"name": "Activity", "points": [
            {"x": "Mon", "y": "Week 1", "v": 4},
            {"x": "Tue", "y": "Week 1", "v": 0},
            {"x": "Mon", "y": "Week 2", "v": 9}
          ]}
        ]}
        """)
        guard case .success(let spec) = result else {
            Issue.record("parse failed")
            return
        }
        let points = spec.series[0].points
        #expect(points.count == 3)
        #expect(points[0].row == "Week 1")
        #expect(points[0].value == 4)
        #expect(points[2].row == "Week 2")
    }

    @Test("Heatmap without v per point is rejected with a pointed message")
    func heatmapRejectsMissingV() {
        let result = parse("""
        {"type": "heatmap", "series": [
          {"name": "A", "points": [{"x": "Mon", "y": 3}]}
        ]}
        """)
        guard case .failure(let error) = result else {
            Issue.record("should have failed")
            return
        }
        #expect(error.message.contains("heatmap"))
    }

    @Test("Histogram takes raw values; points degrade to their y values")
    func histogramParses() {
        let fromValues = parse("""
        {"type": "histogram", "bins": 4, "series": [
          {"name": "Latency", "values": [1, 2, 2, 3, 8]}
        ]}
        """)
        guard case .success(let spec) = fromValues else {
            Issue.record("parse failed")
            return
        }
        #expect(spec.isDistribution)
        #expect(spec.bins == 4)
        #expect(spec.series[0].values == [1, 2, 2, 3, 8])

        // A model that emitted points anyway still renders.
        let fromPoints = parse("""
        {"type": "boxplot", "series": [
          {"name": "A", "points": [{"x": 0, "y": 5}, {"x": 1, "y": 7}]}
        ]}
        """)
        guard case .success(let degraded) = fromPoints else {
            Issue.record("degrade parse failed")
            return
        }
        #expect(degraded.series[0].values == [5, 7])
    }

    @Test("Distribution series without values fail with a pointed message")
    func distributionRejectsEmpty() {
        let result = parse("""
        {"type": "histogram", "series": [{"name": "A"}]}
        """)
        guard case .failure(let error) = result else {
            Issue.record("should have failed")
            return
        }
        #expect(error.message.contains("values"))
    }

    @Test("Binning: equal widths, top edge in last bin, Sturges default")
    func binning() {
        let bins = ChartDistribution.bins(for: [0, 1, 2, 3, 4, 5, 6, 7, 8, 10], count: 5)
        #expect(bins.count == 5)
        #expect(bins.map(\.count).reduce(0, +) == 10)
        // Top edge value (10) lands in the last bin, not out of range.
        #expect(bins.last?.count ?? 0 > 0)

        // Sturges: ceil(log2(8) + 1) = 4 bins for 8 samples.
        let auto = ChartDistribution.bins(for: [1, 2, 3, 4, 5, 6, 7, 8])
        #expect(auto.count == 4)

        // Degenerate: identical values → one bin holding everything.
        let flat = ChartDistribution.bins(for: [3, 3, 3])
        #expect(flat.count == 1)
        #expect(flat[0].count == 3)
    }

    @Test("Five-number summary uses interpolated quartiles")
    func fiveNumber() {
        let f = ChartDistribution.fiveNumber(for: [7, 1, 3, 5])!
        #expect(f.min == 1)
        #expect(f.max == 7)
        #expect(f.median == 4)   // (3+5)/2
        #expect(f.q1 == 2.5)     // R-7 interpolation
        #expect(f.q3 == 5.5)
        #expect(ChartDistribution.fiveNumber(for: []) == nil)
    }
}

@Suite("Waterfall")
struct WaterfallTests {

    @Test("Waterfall parses with total markers (y optional on totals)")
    func parses() {
        let result = ChartSpec.parse("""
        {"type": "waterfall", "title": "Q2 Bridge", "series": [
          {"name": "Bridge", "points": [
            {"x": "Revenue", "y": 500},
            {"x": "COGS", "y": -180},
            {"x": "Gross profit", "total": true},
            {"x": "Opex", "y": -220},
            {"x": "Net", "total": true}
          ]}
        ]}
        """)
        guard case .success(let spec) = result else {
            Issue.record("parse failed")
            return
        }
        #expect(spec.type == .waterfall)
        #expect(spec.series[0].points[2].isTotal)
        #expect(spec.series[0].points[2].y == 0)   // omitted y defaults
    }

    @Test("Segments compute running levels; totals span from zero")
    func segments() {
        let points = [
            ChartPoint(x: .label("Revenue"), y: 500),
            ChartPoint(x: .label("COGS"), y: -180),
            ChartPoint(x: .label("Gross"), y: 0, isTotal: true),
            ChartPoint(x: .label("Opex"), y: -220),
            ChartPoint(x: .label("Net"), y: 0, isTotal: true),
        ]
        let segments = ChartWaterfall.segments(for: points)
        #expect(segments[0].start == 0 && segments[0].end == 500)
        #expect(segments[1].start == 500 && segments[1].end == 320)   // fall
        #expect(!segments[1].isRise)
        #expect(segments[2].isTotal && segments[2].start == 0 && segments[2].end == 320)
        #expect(segments[3].end == 100)
        #expect(segments[4].isTotal && segments[4].end == 100)
    }

    @Test("Duplicate step labels get disambiguated, not collapsed")
    func duplicateLabels() {
        let points = [
            ChartPoint(x: .label("Adjustment"), y: 10),
            ChartPoint(x: .label("Adjustment"), y: -4),
        ]
        let segments = ChartWaterfall.segments(for: points)
        #expect(segments.count == 2)
        #expect(segments[0].label != segments[1].label)
        #expect(segments[1].end == 6)
    }
}

@Suite("Timeline")
struct TimelineTests {

    @Test("Spec parses bars, milestones, lanes; drops unparseable items")
    func parsing() {
        let spec = TimelineSpec.parse("""
        {"title": "Q3", "items": [
          {"label": "Design", "start": "2026-07-01", "end": "2026-07-14", "lane": "Product", "group": "done"},
          {"label": "Build", "start": "2026-07-10", "end": "2026-08-15", "lane": "Eng"},
          {"label": "GA", "at": "2026-08-20", "lane": "Launch"},
          {"label": "Backwards", "start": "2026-08-01", "end": "2026-07-01"},
          {"label": "", "start": "2026-07-01", "end": "2026-07-02"},
          {"label": "No dates"}
        ]}
        """)!
        #expect(spec.items.count == 3)
        #expect(spec.items[2].isMilestone)
        #expect(spec.items[2].start == spec.items[2].end)
        #expect(spec.lanes == ["Product", "Eng", "Launch"])
        #expect(spec.groups == ["done"])
        #expect(TimelineSpec.parse("{\"items\": []}") == nil)
    }

    @Test("Date range spans min start to max end")
    func range() {
        let spec = TimelineSpec.parse("""
        {"items": [
          {"label": "A", "start": "2026-07-10", "end": "2026-07-20"},
          {"label": "B", "start": "2026-07-01", "end": "2026-07-05"}
        ]}
        """)!
        let range = spec.dateRange!
        #expect(range.lowerBound == TimelineSpec.parseDate("2026-07-01"))
        #expect(range.upperBound == TimelineSpec.parseDate("2026-07-20"))
    }

    @Test("Single milestone pads the axis instead of collapsing")
    func singleInstant() {
        let spec = TimelineSpec.parse("""
        {"items": [{"label": "GA", "at": "2026-08-20"}]}
        """)!
        let range = spec.dateRange!
        #expect(range.upperBound > range.lowerBound)
    }

    @Test("Dates parse as yyyy-MM-dd and full ISO-8601")
    func dates() {
        #expect(TimelineSpec.parseDate("2026-07-01") != nil)
        #expect(TimelineSpec.parseDate("2026-07-01T14:30:00Z") != nil)
        #expect(TimelineSpec.parseDate("2026-07-01T14:30:00.250Z") != nil)
        #expect(TimelineSpec.parseDate("July 1") == nil)
        #expect(TimelineSpec.parseDate("2026-13-99") == nil)
    }

    @Test("Fence routing: JSON timeline/gantt is ours, mermaid text falls through")
    func fenceRouting() {
        #expect(MarkdownParser.isTimelineBlock(language: "timeline", code: "{\"items\": []}"))
        #expect(MarkdownParser.isTimelineBlock(language: " Gantt ", code: "  {\"items\": []}"))
        // Mermaid timeline/gantt syntax is line-oriented — falls through.
        #expect(!MarkdownParser.isTimelineBlock(language: "timeline", code: "title History of Social Media"))
        #expect(!MarkdownParser.isTimelineBlock(language: "gantt", code: "dateFormat YYYY-MM-DD"))
        #expect(!MarkdownParser.isTimelineBlock(language: "chart", code: "{\"items\": []}"))
    }
}
