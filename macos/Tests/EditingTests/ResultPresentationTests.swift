import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class DeferredProfileProvider: ProfileProvider {
    var calls: [Int] = []
    private var completion: CheckedContinuation<MapUpdate, any Error>?
    func selectProfile(_ index: Int) async throws -> MapUpdate {
        calls.append(index)
        return try await withCheckedThrowingContinuation { completion = $0 }
    }
    func finish(_ result: Result<MapUpdate, any Error>) { let pending = completion; completion = nil; pending?.resume(with: result) }
}

@MainActor
private final class ChartRefreshProvider: ModelEditorProvider {
    var saved = 0
    var editable = false
    var returnWrongPage = false
    var refreshed = false
    private func snapshot() -> EditorSnapshot {
        let chart = SeriesChartPresentation(axes: [.init(id: "x", direction: .x, title: "Time"), .init(id: "y", direction: .y, title: "Value")],
            datasets: [.init(id: "source-series", name: "Result", xAxisID: "x", yAxisID: "y")], canRefresh: true)
        return .init(fields: ["Description": "on disk"], rows: [:], samples: [returnWrongPage ? "Wrong Page" : "Time Series": [.init(id: "one", x: 0, y: refreshed ? 2 : 1, series: "Result", datasetID: "source-series")]],
            canEdit: editable, images: [:], seriesPresentations: ["Time Series": .init(chart: chart)])
    }
    func load(_ asset: ProjectAsset, kind: ModelEditorKind) async throws -> EditorSnapshot { snapshot() }
    func save(_ asset: ProjectAsset, changes: EditorEdits) async throws { saved += 1 }
    func perform(_ asset: ProjectAsset, action: EditorAction) async throws -> EditorSnapshot {
        guard case .refreshSeries(let pageID) = action, pageID == "Time Series" else { throw CocoaError(.featureUnsupported) }
        refreshed = true; return snapshot()
    }
}

struct ResultPresentationTests {
    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(1)) }
        #expect(condition())
    }
    private func presentation(_ source: String) -> MapProfilePresentation {
        .init(sourceID: source, steps: [.init(id: 10, label: "first"), .init(id: 20, label: "second"), .init(id: 30, label: "last")], selectedID: 10)
    }
    private func update(_ selected: String) -> MapUpdate { .init(vectors: [], rasters: [], preview: [], selectedLayerID: selected, selectedFeatureID: nil) }
    @Test @MainActor func rapidScrubsUseActualSourceIDsAndInstallOnlyTheFinalFrame() async throws {
        let provider = DeferredProfileProvider(), session = MapProfileSession()
        var installed: [String] = []
        session.didSelect = { update, _ in installed.append(update.selectedLayerID ?? "") }
        try session.configure(presentation("result-a"), provider: provider, context: .init(projectSessionID: UUID(), mapID: UUID(), sourceID: "result-a"))
        session.select(position: 1)
        try await waitUntil { provider.calls.count == 1 }
        session.select(position: 2)
        provider.finish(.success(update("intermediate")))
        try await waitUntil { provider.calls.count == 2 }
        #expect(installed.isEmpty && provider.calls == [20, 30])
        provider.finish(.success(update("final")))
        try await waitUntil { !session.busy }
        #expect(session.currentID == 30 && session.currentStep?.label == "last" && installed == ["final"])
    }
    @Test @MainActor func failedFinalFrameReturnsToTheLastConfirmedSourceFrame() async throws {
        let provider = DeferredProfileProvider(), session = MapProfileSession()
        var installed: [String] = []
        session.didSelect = { update, _ in installed.append(update.selectedLayerID ?? "") }
        try session.configure(presentation("result-a"), provider: provider, context: .init(projectSessionID: UUID(), mapID: UUID(), sourceID: "result-a"))
        session.select(position: 1); try await waitUntil { provider.calls.count == 1 }
        session.select(position: 2); provider.finish(.success(update("confirmed")))
        try await waitUntil { provider.calls.count == 2 }
        provider.finish(.failure(CocoaError(.fileReadCorruptFile)))
        try await waitUntil { !session.busy }
        #expect(session.currentID == 20 && session.error != nil && installed == ["confirmed"])
    }
    @Test @MainActor func changedProfileContextRejectsOldRepliesAndInvalidSourceSelections() async throws {
        let provider = DeferredProfileProvider(), session = MapProfileSession()
        let map = UUID(), project = UUID()
        var installed = 0
        session.didSelect = { _, _ in installed += 1 }
        try session.configure(presentation("old"), provider: provider, context: .init(projectSessionID: project, mapID: map, sourceID: "old"))
        session.select(position: 1); try await waitUntil { provider.calls.count == 1 }
        try session.configure(presentation("new"), provider: nil, context: .init(projectSessionID: project, mapID: map, sourceID: "new"))
        provider.finish(.success(update("old")))
        await Task.yield()
        #expect(installed == 0 && session.currentID == 10 && !session.canSelect)
        #expect(throws: ProjectFileError.self) {
            try session.configure(.init(sourceID: "bad", steps: [.init(id: 2, label: "a"), .init(id: 2, label: "b")], selectedID: 2), provider: nil,
                context: .init(projectSessionID: project, mapID: map, sourceID: "bad"))
        }
        #expect(session.currentID == 10)
    }
    @Test @MainActor func frameRepliesStayInTheirMapAndProjectCloseInvalidatesPendingWork() async throws {
        let store = WorkspaceStore(), provider = DeferredProfileProvider()
        let mapA = UUID(), mapB = UUID()
        let first = store.mapState(for: mapA), second = store.mapState(for: mapB)
        try store.configureProfiles(presentation("result-a"), mapID: mapA, provider: provider)
        store.activateMap(mapB)
        first.profiles.select(position: 1); try await waitUntil { provider.calls.count == 1 }
        provider.finish(.success(update("frame-a")))
        try await waitUntil { !first.profiles.busy }
        #expect(first.profileVectors?.isEmpty == true && first.profileRasters?.isEmpty == true)
        #expect(second.profileVectors == nil && second.profileRasters == nil)
        #expect(store.mapLayers.isEmpty && store.rasterLayers.isEmpty && store.selectedAssetID == nil)
        first.profiles.select(position: 2); try await waitUntil { provider.calls.count == 2 }
        store.requestClose()
        provider.finish(.success(update("closed-project")))
        await Task.yield()
        #expect(first.profiles.steps.isEmpty && first.profileVectors == nil)
        #expect(store.mapState(for: mapA).profileVectors == nil)
    }
    @Test @MainActor func refreshingChartsIsReadonlyNavigationAndRejectsWrongPageReplies() async throws {
        let provider = ChartRefreshProvider()
        let session = ModelEditorSession(provider: provider)
        let asset = ProjectAsset(url: URL(fileURLWithPath: "/fixture/result.h5"), section: .results)
        await session.load(asset, kind: .result)
        #expect(!session.canEdit)
        #expect(await session.perform(.refreshSeries(pageID: "Time Series")))
        #expect(session.samples["Time Series"]?.first?.y == 2 && provider.saved == 0 && !session.modified)
        provider.editable = true; provider.refreshed = false
        await session.load(asset, kind: .result)
        session.set("Description", "existing draft")
        #expect(await session.perform(.refreshSeries(pageID: "Time Series")))
        #expect(session.fields["Description"] == "existing draft" && session.modified && provider.saved == 0)
        provider.returnWrongPage = true
        #expect(!(await session.perform(.refreshSeries(pageID: "Time Series"))))
        #expect(session.samples["Time Series"]?.first?.y == 2 && session.fields["Description"] == "existing draft")
        #expect(session.error != nil && provider.saved == 0)
    }
    @Test @MainActor func changingFrameBoundsPreservesWorldViewportWithoutRepeatedFitPadding() throws {
        let state = MapState()
        let size = CGSize(width: 800, height: 600)
        let firstPoints = [MapPoint(x: 0, y: 0), MapPoint(x: 100, y: 100)]
        let original = MapTransform(points: firstPoints, size: size, scale: 3, offset: CGSize(width: 25, height: -10))
        let lower = original.world(CGPoint(x: 0, y: size.height)), upper = original.world(CGPoint(x: size.width, y: 0))
        state.currentExtent = .init(lowerLeft: lower, upperRight: upper)
        let nextPoints = [MapPoint(x: 1000, y: 2000), MapPoint(x: 5000, y: 8000)]
        for _ in 0..<4 {
            state.installProfile(.init(vectors: [], rasters: [], preview: [], selectedLayerID: nil, selectedFeatureID: nil))
            let request = try #require(state.viewport)
            #expect(!request.animated && request.padding == 0)
            let fit = try #require(MapViewportFit(request: request, points: nextPoints, size: size))
            let transformed = MapTransform(points: nextPoints, size: size, scale: fit.scale, offset: fit.offset)
            let newLower = transformed.world(CGPoint(x: 0, y: size.height)), newUpper = transformed.world(CGPoint(x: size.width, y: 0))
            #expect(abs(newLower.x - lower.x) < 0.000001 && abs(newLower.y - lower.y) < 0.000001)
            #expect(abs(newUpper.x - upper.x) < 0.000001 && abs(newUpper.y - upper.y) < 0.000001)
            state.currentExtent = .init(lowerLeft: newLower, upperRight: newUpper)
        }
        state.clearProfileRender()
        let clearedRequest = try #require(state.viewport)
        #expect(clearedRequest.padding == 0 && !clearedRequest.animated)
        let fit = try #require(MapViewportFit(request: clearedRequest, points: firstPoints, size: size))
        let restored = MapTransform(points: firstPoints, size: size, scale: fit.scale, offset: fit.offset)
        #expect(abs(restored.world(.zero).x - original.world(.zero).x) < 0.000001)
    }
    @Test @MainActor func monitorHistoryUsesOnlyObservedValuesAndResetsForNewRuns() {
        let history = MonitorHistory(capacity: 2), start = Date(timeIntervalSince1970: 1_000)
        history.configure("run-a")
        history.record(nil, at: start); history.record(.nan, at: start); history.record(.infinity, at: start)
        #expect(history.observations.isEmpty && history.minimum == nil)
        for (index, value) in [3.0, 8, 4].enumerated() { history.record(value, at: start.addingTimeInterval(Double(index))) }
        #expect(history.observations.map(\.value) == [8, 4] && history.minimum == 3 && history.maximum == 8)
        history.configure("run-a"); #expect(history.observations.count == 2)
        history.clear(); #expect(history.minimum == nil && history.maximum == nil)
        history.record(20, at: start); history.configure("run-b")
        #expect(history.observations.isEmpty && history.minimum == nil)
    }
    @Test func cursorReadoutsPreservePolylineCrossingsGapsAndLogarithmicCoordinates() {
        let curve: [ChartSample] = [.init(id: "a", x: 0, y: 0, series: "line"), .init(id: "b", x: 2, y: 2, series: "line"), .init(id: "c", x: 0, y: 4, series: "line")]
        #expect(PlotDisplayMath.scrub(curve, x: 1, logX: false, logY: false) == [1, 3])
        let log: [ChartSample] = [.init(id: "a", x: 1, y: 1, series: "line"), .init(id: "b", x: 100, y: 10_000, series: "line")]
        #expect(abs((PlotDisplayMath.scrub(log, x: 10, logX: true, logY: true).first ?? 0) - 100) < 0.000001)
        #expect(PlotDisplayMath.scrub(log, x: 1, logX: true, logY: true) == [1])
        let gap: [ChartSample] = [.init(id: "a", x: 0, y: .nan, series: "line"), .init(id: "b", x: 2, y: 2, series: "line")]
        #expect(PlotDisplayMath.scrub(gap, x: 1, logX: false, logY: false).isEmpty)
        let missing = ChartSample(id: "missing", x: 0, y: -9999, series: "source")
        let definition = PlotDatasetPresentation(id: "source", name: "source", xAxisID: "x", yAxisID: "y", noDataValue: -9999)
        #expect(definition.forDisplay(missing).y.isNaN && missing.y == -9999)

        #expect(abs(PlotDisplayMath.visibleLength(1...1_000, position: 1, fraction: 0.5, logarithmic: true) - (sqrt(1_000) - 1)) < 0.000001)
    }
    @Test @MainActor func datasetsWithIdenticalNamesKeepIndependentAxesUnitsAndPointIdentities() throws {
        let source = SeriesChartPresentation(axes: [.init(id: "time", direction: .x, title: "Time"),
            .init(id: "depth", direction: .y, title: "Depth", units: "m"), .init(id: "flow", direction: .y, title: "Flow", units: "m³/s")],
            datasets: [.init(id: "a", name: "same name", xAxisID: "time", yAxisID: "depth"), .init(id: "b", name: "same name", xAxisID: "time", yAxisID: "flow")])
        let samples: [ChartSample] = [.init(id: "0", x: 1, y: 2, series: "same name", datasetID: "a"), .init(id: "0", x: 1, y: 200, series: "same name", datasetID: "b")]
        try source.validate(samples: samples)
        #expect(SeriesChartGroup.groups(source).map(\.yAxis.units) == ["m", "m³/s"])
        #expect(Set(SeriesPlotPoint.segments(samples).map(\.id)).count == 2)
        let editor = ModelEditorSession()
        editor.startDraft(.init(fields: [:], rows: [:], samples: ["plot": samples], canEdit: true, images: [:], editableSamplePages: ["plot"]))
        editor.setSample(page: "plot", id: "0", y: 300, datasetID: "b")
        #expect(editor.samples["plot"]?.map(\.y) == [2, 300])

        try EditorSnapshot(fields: [:], rows: [:], samples: ["plot": samples], canEdit: false, images: [:], seriesPresentations: ["plot": .init(chart: source)]).validatePresentation()
        #expect(throws: ProjectFileError.self) { try source.validate(samples: [.init(id: "bad", x: 0, y: 1, series: "unknown")]) }
    }
    @Test func missingDataLeavesVisibleIsolatedPointsWithoutJoiningAcrossGapsOrDatasets() {
        let samples: [ChartSample] = [
            .init(id: "0", x: 0, y: 1, series: "same", datasetID: "a"),
            .init(id: "0", x: 0, y: 2, series: "same", datasetID: "b"),
            .init(id: "1", x: 1, y: .nan, series: "same", datasetID: "a"),
            .init(id: "2", x: 2, y: 3, series: "same", datasetID: "a"),
            .init(id: "3", x: 3, y: 4, series: "same", datasetID: "a"),
            .init(id: "4", x: 4, y: .nan, series: "same", datasetID: "a"),
            .init(id: "5", x: 5, y: 6, series: "same", datasetID: "a")]
        let points = SeriesPlotPoint.segments(samples)
        #expect(points.map(\.isIsolated) == [true, true, false, false, true])
        #expect(points.map(\.segment) == [0, 0, 1, 1, 2])
        #expect(points[0].segmentID != points[1].segmentID)
        #expect(points[2].segmentID == points[3].segmentID)
    }
}
