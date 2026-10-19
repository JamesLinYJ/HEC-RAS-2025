import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class SeriesAndSpatialProvider: ModelEditorProvider {
    var snapshot: EditorSnapshot
    var result = SeriesEditResult(changed: false)
    var saved: [EditorEdits] = []
    var requests: [SeriesEditRequest] = []
    var actions: [EditorAction] = []
    var delay = false
    private var ready: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<SeriesEditResult, Never>?
    init(_ snapshot: EditorSnapshot) { self.snapshot = snapshot }
    func load(_ asset: ProjectAsset, kind: ModelEditorKind) async throws -> EditorSnapshot { snapshot }
    func save(_ asset: ProjectAsset, changes: EditorEdits) async throws { saved.append(changes) }
    func perform(_ asset: ProjectAsset, action: EditorAction) async throws -> EditorSnapshot {
        actions.append(action)
        var value = snapshot
        if case .selectSpatialTime(let layer, let step) = action { value.spatialPresentations[layer]?.selectedTimeStepID = step }
        return value
    }
    func editSeries(_ asset: ProjectAsset, request: SeriesEditRequest) async throws -> SeriesEditResult {
        requests.append(request); ready?.resume(); ready = nil
        if delay { return await withCheckedContinuation { completion = $0 } }
        return result
    }
    func waitForRequest() async { if requests.isEmpty { await withCheckedContinuation { ready = $0 } } }
    func finish() { completion?.resume(returning: result); completion = nil }
}

struct SeriesAndSpatialTests {
    private let page = "upstream/Time Series"
    private let table = "upstream/TimeSeriesPayloadTable"
    private var asset: ProjectAsset { .init(url: URL(fileURLWithPath: "/ui-fixture/boundary.h5"), section: .boundaryConditions) }
    private func fixture() -> EditorSnapshot {
        let times = [DataToolTimeStep(id: "t0", title: "08:00", date: Date(timeIntervalSince1970: 0)),
                     DataToolTimeStep(id: "t1", title: "09:00", date: Date(timeIntervalSince1970: 3600))]
        return .init(fields: ["BoundaryConditionsSummary/BoundaryCondition_Description": "original"],
            rows: [table: [.init(id: "r1", values: ["Time": "08:00", "Value": "2"])]],
            samples: [page: [.init(id: "s1", x: 0, y: 2, series: "Flow")]], canEdit: true, images: [:], editableSamplePages: [page],
            tablePresentations: [table: .init(columns: [.init(id: "Time", title: "Time", sourceType: "string", readOnly: true), .init(id: "Value", title: "Flow", sourceType: "double")])],
            sourceRevision: "source-v1", seriesPresentations: [page: .init(tableID: table, operations: [.clear, .interpolate, .addStation])],
            spatialPresentations: ["precipitation": .init(timeSteps: times, selectedTimeStepID: "t0", canSelectTime: true)])
    }
    @Test @MainActor func stationChangesRemainDraftsAcrossNavigationAndDiscardRestoresSourceColumns() async throws {
        let provider = SeriesAndSpatialProvider(fixture()), session = ModelEditorSession(provider: provider)
        await session.load(asset, kind: .boundaryCondition)
        let columns = try #require(session.tablePresentations[table])
        let updated = EditorTablePresentation(columns: columns.columns + [.init(id: "Station1", title: "Station 1", sourceType: "double")])
        provider.result = .init(changed: true, rows: [.init(id: "r1", values: ["Time": "08:00", "Value": "2", "Station1": "4"])], table: updated)
        #expect(await session.editSeries(pageID: page, operation: .addStation))
        #expect(session.modified && provider.saved.isEmpty)
        #expect(provider.requests.first?.edits.sourceRevision == "source-v1")
        #expect(await session.perform(.selectSpatialTime(layerID: "precipitation", stepID: "t1")))
        #expect(session.tablePresentations[table]?.columns.map(\.id) == ["Time", "Value", "Station1"])
        #expect(session.rows[table]?.first?.values["Station1"] == "4")
        #expect(provider.saved.isEmpty)
        session.discardEdits()
        #expect(!session.modified)
        #expect(session.tablePresentations[table]?.columns.map(\.id) == ["Time", "Value"])
        #expect(session.rows[table]?.first?.values["Station1"] == nil)
    }
    @Test @MainActor func sourceDateColumnsAreReadonlyAndClearKeepsMissingValuesWithoutSaving() async throws {
        let provider = SeriesAndSpatialProvider(fixture()), session = ModelEditorSession(provider: provider)
        await session.load(asset, kind: .boundaryCondition)
        session.setSample(page: page, id: "s1", x: 100)
        session.setCell(table: table, rowID: "r1", column: "Time", value: "changed")
        #expect(!session.modified)
        provider.result = .init(changed: true, samples: [.init(id: "s1", x: 0, y: .nan, series: "Flow")], rows: [.init(id: "r1", values: ["Time": "08:00", "Value": ""])])
        #expect(await session.editSeries(pageID: page, operation: .clear))
        #expect(session.samples[page]?.first?.y.isNaN == true)
        #expect(provider.saved.isEmpty)
        session.discardEdits()
        #expect(session.samples[page]?.first?.y == 2)
    }
    @Test @MainActor func lateSeriesReplyCannotReplaceAnotherLoadedModel() async throws {
        let provider = SeriesAndSpatialProvider(fixture()), session = ModelEditorSession(provider: provider)
        await session.load(asset, kind: .boundaryCondition)
        provider.delay = true; provider.result = .init(changed: true, samples: [.init(id: "old", x: 0, y: 999, series: "old")])
        let pending = Task { await session.editSeries(pageID: page, operation: .interpolate) }
        await provider.waitForRequest()
        let next = ProjectAsset(url: URL(fileURLWithPath: "/ui-fixture/next-boundary.h5"), section: .boundaryConditions)
        await session.load(next, kind: .boundaryCondition)
        provider.finish()
        #expect(!(await pending.value))
        #expect(session.modelAssetID == next.id && !session.modified)
        #expect(session.samples[page]?.first?.y == 2)
    }
    @Test @MainActor func spatialTimeNavigationKeepsDirtyFieldsAndAllowsReadonlyViewing() async throws {
        let provider = SeriesAndSpatialProvider(fixture()), session = ModelEditorSession(provider: provider)
        await session.load(asset, kind: .boundaryCondition)
        let description = "BoundaryConditionsSummary/BoundaryCondition_Description"
        session.set(description, "中文草稿")
        #expect(await session.perform(.selectSpatialTime(layerID: "precipitation", stepID: "t1")))
        #expect(session.fields[description] == "中文草稿" && session.modified && provider.saved.isEmpty)
        #expect(!(await session.perform(.selectSpatialTime(layerID: "precipitation", stepID: "unknown"))))
        provider.snapshot = .init(fields: [:], rows: [:], samples: [:], canEdit: false, images: [:], spatialPresentations: fixture().spatialPresentations)
        await session.load(asset, kind: .boundaryCondition)
        #expect(await session.perform(.selectSpatialTime(layerID: "precipitation", stepID: "t1")))
        #expect(!session.modified && !session.canEdit)
    }
    @Test @MainActor func duplicateTimestepIdentitiesAreRejectedBeforeRenderingPickers() async {
        var initial = fixture()
        initial.spatialPresentations["precipitation"]?.timeSteps.append(.init(id: "t0", title: "duplicate", date: .now))
        let session = ModelEditorSession(provider: SeriesAndSpatialProvider(initial))
        await session.load(asset, kind: .boundaryCondition)
        #expect(!session.loaded && session.error != nil)
    }
    @Test func missingValuesSplitLinesWithoutChangingOtherSeries() {
        let points = SeriesPlotPoint.segments([.init(id: "a", x: 0, y: 1, series: "Flow"),
            .init(id: "missing", x: 1, y: .nan, series: "Flow"), .init(id: "b", x: 2, y: 3, series: "Flow"),
            .init(id: "other", x: 2, y: 7, series: "Stage")])
        #expect(points.map(\.sample.id) == ["a", "b", "other"])
        #expect(points.map(\.id.dataset) == ["Flow", "Flow", "Stage"])
        #expect(points.map(\.segment) == [0, 1, 0])
    }
}
