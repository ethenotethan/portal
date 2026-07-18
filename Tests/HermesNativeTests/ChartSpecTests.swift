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
