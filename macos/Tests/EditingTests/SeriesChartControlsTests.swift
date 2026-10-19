import Foundation
import Testing
@testable import HECRAS2025
import RASWorkspaceCore

struct SeriesChartControlsTests {
    @Test func chartAxisTicksUseSourcePixelDensityAndViewDerivedZoomLevel() throws {
        let fit = try #require(ChartAxisTickMath.layout(domain: 0...100, visibleRange: -15...115,
                                                       pixelLength: 500, pixelsPerTick: 175))
        #expect(fit.zoomLevel == 0)
        #expect(fit.interval == 50)
        #expect(fit.values == [-50, 0, 50, 100, 150])

        let zoomed = try #require(ChartAxisTickMath.layout(domain: 0...100, visibleRange: 10...60,
                                                          pixelLength: 500, pixelsPerTick: 175))
        #expect(zoomed.zoomLevel == 1)
        #expect(zoomed.interval == 20)

        let dense = try #require(ChartAxisTickMath.layout(domain: 0...100, visibleRange: -15...115,
                                                         pixelLength: 500, pixelsPerTick: 75))
        let sparse = try #require(ChartAxisTickMath.layout(domain: 0...100, visibleRange: -15...115,
                                                          pixelLength: 500, pixelsPerTick: 300))
        #expect(dense.values.count > sparse.values.count)
    }

    @Test func chartDateTicksUseRetainedSixtySecondNiceIntervalLadder() throws {
        let layout = try #require(ChartAxisTickMath.layout(domain: 0...3_600, visibleRange: -540...4_140,
                                                          pixelLength: 780, pixelsPerTick: 175, isDate: true))
        #expect(layout.zoomLevel == 0)
        #expect(layout.interval == 900)
        #expect(layout.values.first == -900)
        #expect(layout.values.last == 4_500)
        #expect(ChartAxisTickMath.layout(domain: 0...100, visibleRange: -15...115,
                                         pixelLength: 500, pixelsPerTick: 175,
                                         isDate: true, logarithmic: true) == nil)
    }

    @Test func linearAxisRangeRoundTripsThroughViewportAndRejectsOutOfSourceBounds() throws {
        let source = 2.0...10.0
        let requested = 3.5...7.5
        let viewport = try #require(PlotDisplayMath.viewport(for: requested, within: source, logarithmic: false))
        #expect(abs(viewport.position - requested.lowerBound) < 0.000_000_1)
        #expect(abs(viewport.fraction - 0.5) < 0.000_000_1)

        let visible = try #require(PlotDisplayMath.visibleRange(source, position: viewport.position,
                                                                 fraction: viewport.fraction, logarithmic: false))
        #expect(abs(visible.lowerBound - requested.lowerBound) < 0.000_000_1)
        #expect(abs(visible.upperBound - requested.upperBound) < 0.000_000_1)
        #expect(PlotDisplayMath.viewport(for: 1.0...7.5, within: source, logarithmic: false) == nil)
        #expect(PlotDisplayMath.viewport(for: 5.0...5.0, within: source, logarithmic: false) == nil)
    }

    @Test func logarithmicScrollbarProgressUsesScaleSpaceAndRejectsNonpositiveRanges() throws {
        let source = 1.0...100.0
        let initialPosition = PlotDisplayMath.position(atScrollProgress: 0, in: source, fraction: 0.5, logarithmic: true)
        let middlePosition = PlotDisplayMath.position(atScrollProgress: 0.5, in: source, fraction: 0.5, logarithmic: true)
        let finalPosition = PlotDisplayMath.position(atScrollProgress: 1, in: source, fraction: 0.5, logarithmic: true)
        #expect(abs(initialPosition - 1) < 0.000_000_1)
        #expect(abs(PlotDisplayMath.scrollProgress(source, position: middlePosition, fraction: 0.5, logarithmic: true) - 0.5) < 0.000_000_1)
        #expect(abs(finalPosition - 10) < 0.000_000_1)

        let viewport = try #require(PlotDisplayMath.viewport(for: 10.0...100.0, within: source, logarithmic: true))
        let visible = try #require(PlotDisplayMath.visibleRange(source, position: viewport.position,
                                                                 fraction: viewport.fraction, logarithmic: true))
        #expect(abs(visible.lowerBound - 10) < 0.000_000_1)
        #expect(abs(visible.upperBound - 100) < 0.000_000_1)
        #expect(PlotDisplayMath.viewport(for: 0.0...10.0, within: source, logarithmic: true) == nil)
    }

    @Test func pointerZoomKeepsTheAnchorAtTheSameRelativePlotPosition() throws {
        let linear = try #require(PlotDisplayMath.zoomedViewport(0.0...100.0, position: 20, fraction: 0.5,
                                                                  anchor: 45, factor: 0.5, logarithmic: false))
        let linearVisible = try #require(PlotDisplayMath.visibleRange(0.0...100.0, position: linear.position,
                                                                       fraction: linear.fraction, logarithmic: false))
        #expect(abs(linearVisible.lowerBound - 32.5) < 0.000_000_1)
        #expect(abs(linearVisible.upperBound - 57.5) < 0.000_000_1)

        let logarithmic = try #require(PlotDisplayMath.zoomedViewport(1.0...100.0, position: 10, fraction: 0.5,
                                                                      anchor: 10 * sqrt(10), factor: 0.5, logarithmic: true))
        let logVisible = try #require(PlotDisplayMath.visibleRange(1.0...100.0, position: logarithmic.position,
                                                                    fraction: logarithmic.fraction, logarithmic: true))
        #expect(abs(log10(logVisible.lowerBound) - log10(10 * sqrt(10)) + 0.25) < 0.000_000_1)
        #expect(abs(log10(logVisible.upperBound) - log10(10 * sqrt(10)) - 0.25) < 0.000_000_1)
    }

    @Test func fitAllAddsTheSourceChartFifteenPercentExtentAndScrollbarTracksThatExtent() throws {
        let source = try #require(PlotDisplayMath.range([0, 100], addNavigationMargin: true))
        #expect(abs(source.lowerBound + 15) < 0.000_000_1)
        #expect(abs(source.upperBound - 115) < 0.000_000_1)

        let view = try #require(PlotDisplayMath.visibleRange(source, position: source.lowerBound,
                                                              fraction: 0.5, logarithmic: false))
        let progress = PlotDisplayMath.scrollProgress(source, position: view.lowerBound,
                                                      fraction: 0.5, logarithmic: false)
        #expect(abs(progress) < 0.000_000_1)
        let finalPosition = PlotDisplayMath.position(atScrollProgress: 1, in: source,
                                                    fraction: 0.5, logarithmic: false)
        #expect(abs(finalPosition - 50) < 0.000_000_1)
        let pageProgress = PlotDisplayMath.scrollPageStepProgress(fraction: 0.25)
        #expect(abs(pageProgress - 1.0 / 3.0) < 0.000_000_1)
        let onePage = PlotDisplayMath.position(atScrollProgress: pageProgress, in: 0.0...100.0,
                                               fraction: 0.25, logarithmic: false)
        #expect(abs(onePage - 25) < 0.000_000_1)
        #expect(PlotDisplayMath.scrollPageStepProgress(fraction: 0.75) == 1)

        let logarithmic = try #require(PlotDisplayMath.range([1, 100], logarithmic: true,
                                                               addNavigationMargin: true))
        #expect(abs(log10(logarithmic.lowerBound) + 0.3) < 0.000_000_1)
        #expect(abs(log10(logarithmic.upperBound) - 2.3) < 0.000_000_1)
    }

    @Test func pointerDragPansBothLinearAxesAndLogAxesInDisplaySpace() throws {
        let x = try #require(PlotDisplayMath.pannedViewport(0.0...100.0, position: 20, fraction: 0.5,
                                                             translationFraction: -0.1, logarithmic: false))
        let y = try #require(PlotDisplayMath.pannedViewport(0.0...100.0, position: 20, fraction: 0.5,
                                                             translationFraction: 0.1, logarithmic: false))
        #expect(abs(x.position - 15) < 0.000_000_1)
        #expect(abs(y.position - 25) < 0.000_000_1)

        let logarithmic = try #require(PlotDisplayMath.pannedViewport(1.0...100.0, position: sqrt(10), fraction: 0.5,
                                                                       translationFraction: 0.25, logarithmic: true))
        #expect(abs(log10(logarithmic.position) - 0.75) < 0.000_000_1)
        let clamped = try #require(PlotDisplayMath.pannedViewport(1.0...100.0, position: 10, fraction: 0.5,
                                                                  translationFraction: 0.25, logarithmic: true))
        #expect(abs(log10(clamped.position) - 1) < 0.000_000_1)
        #expect(PlotDisplayMath.pannedViewport(0.0...100.0, position: 0, fraction: 0.5,
                                                translationFraction: .nan, logarithmic: false) == nil)
    }

    @Test func chartStateIdentityChangesWithSourceSamplesAndDatasetPresentation() throws {
        let source = SeriesChartPresentation(
            title: "Stored Result",
            axes: [
                .init(id: "time", direction: .x, title: "Time", isDate: true),
                .init(id: "flow", direction: .y, title: "Flow", units: "m³/s")
            ],
            datasets: [.init(id: "result-a", name: "Result A", xAxisID: "time", yAxisID: "flow")]
        )
        let group = try #require(SeriesChartGroup.groups(source).first)
        let sample = ChartSample(id: "step-1", x: 1_800_000_000, y: 12, series: "Result A", datasetID: "result-a")
        let baseline = SeriesChartDataIdentity(group: group, samples: [sample], source: source, sourceIdentity: "table/result-a")

        var changedSample = sample
        changedSample.y = 14
        let changedData = SeriesChartDataIdentity(group: group, samples: [changedSample], source: source,
                                                  sourceIdentity: "table/result-a")
        #expect(baseline != changedData)

        var changedSource = source
        changedSource.showLegend = false
        let changedDisplay = SeriesChartDataIdentity(group: group, samples: [sample], source: changedSource,
                                                     sourceIdentity: "table/result-a")
        #expect(baseline != changedDisplay)

        changedSource = source
        changedSource.mapID = UUID()
        let changedMap = SeriesChartDataIdentity(group: group, samples: [sample], source: changedSource,
                                                 sourceIdentity: "table/result-a")
        #expect(baseline != changedMap)

        let changedDraftIdentity = SeriesChartDataIdentity(group: group, samples: [sample], source: source,
                                                            sourceIdentity: "table/result-b")
        #expect(baseline != changedDraftIdentity)
    }

    @Test func missingValuesRemainGapsInsteadOfConnectingSeriesSegments() {
        let points = SeriesPlotPoint.segments([
            .init(id: "first", x: 0, y: 2, series: "Flow", datasetID: "flow"),
            .init(id: "missing", x: 1, y: .nan, series: "Flow", datasetID: "flow"),
            .init(id: "last", x: 2, y: 5, series: "Flow", datasetID: "flow")
        ])

        #expect(points.count == 2)
        #expect(points[0].segment != points[1].segment)
        #expect(points.allSatisfy { $0.isIsolated })
    }
}
