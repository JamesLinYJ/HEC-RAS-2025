import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class CancellationBoundaryProvider: ModelEditorProvider {
    let snapshot: EditorSnapshot

    init(snapshot: EditorSnapshot) { self.snapshot = snapshot }

    func load(_ asset: ProjectAsset, kind: ModelEditorKind) async throws -> EditorSnapshot { snapshot }

    func save(_ asset: ProjectAsset, changes: EditorEdits) async throws {
        throw CocoaError(.featureUnsupported)
    }

    func perform(_ asset: ProjectAsset, action: EditorAction) async throws -> EditorSnapshot {
        throw CocoaError(.featureUnsupported)
    }

    func editSeries(_ asset: ProjectAsset, request: SeriesEditRequest) async throws -> SeriesEditResult {
        throw CancellationError()
    }

    func editBoundary(_ asset: ProjectAsset, action: EditorAction, edits: EditorEdits) async throws -> EditorSnapshot {
        throw CancellationError()
    }
}

struct ModelEditorCancellationTests {
    @Test @MainActor
    func boundaryOperationCancellationDoesNotAppearAsEditorFailure() async {
        let line = BoundaryLinePresentation(id: "line:river", scope: "BoundaryConditionLine[0]",
            name: "River", payloads: [], newPayload: NewPayloadPresentation(fields: [:]))
        let snapshot = EditorSnapshot(fields: [:], rows: [:], samples: [:], canEdit: true, images: [:],
            boundaryLines: BoundaryLinesPresentation(lines: [line], selectedLineID: line.id))
        let provider = CancellationBoundaryProvider(snapshot: snapshot)
        let session = ModelEditorSession(provider: provider)
        let asset = ProjectAsset(url: URL(fileURLWithPath: "/fixture/Boundary Conditions/River.hdf"),
                                 section: .boundaryConditions)
        await session.load(asset, kind: .boundaryCondition)

        let succeeded = await session.perform(.createBoundaryPayload(lineID: line.id, fields: [:]))

        #expect(!succeeded)
        #expect(session.error == nil)
        #expect(!session.modified)
    }

    @Test @MainActor
    func automaticSeriesRefreshCancellationDoesNotAppearAsEditorFailure() async {
        let series = SeriesEditorPresentation(operations: [.refresh],
            chart: SeriesChartPresentation(canRefresh: true))
        let snapshot = EditorSnapshot(fields: [:], rows: [:], samples: [:], canEdit: true, images: [:],
            seriesPresentations: ["BoundaryCondition/Flow": series])
        let provider = CancellationBoundaryProvider(snapshot: snapshot)
        let session = ModelEditorSession(provider: provider)
        let asset = ProjectAsset(url: URL(fileURLWithPath: "/fixture/Boundary Conditions/River.hdf"),
                                 section: .boundaryConditions)
        await session.load(asset, kind: .boundaryCondition)

        let succeeded = await session.editSeries(pageID: "BoundaryCondition/Flow", operation: .refresh)

        #expect(!succeeded)
        #expect(session.error == nil)
        #expect(!session.modified)
    }
}
