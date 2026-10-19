import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class CulvertMapHoverParentProvider: ModelEditorProvider {
    func load(_ asset: ProjectAsset, kind: ModelEditorKind) async throws -> EditorSnapshot {
        EditorSnapshot(fields: [:], rows: [:], samples: [:], canEdit: true, images: [:],
            sourceRevision: "geometry-source-sha")
    }

    func save(_ asset: ProjectAsset, changes: EditorEdits) async throws {}

    func perform(_ asset: ProjectAsset, action: EditorAction) async throws -> EditorSnapshot {
        throw CocoaError(.featureUnsupported)
    }
}

@MainActor
private final class CulvertMapHoverChildProvider: GeometryCulvertProvider {
    private var current: GeometryCulvertSnapshot
    private(set) var loadCount = 0

    init() {
        current = Self.snapshot(revision: "geometry-source-sha", draftState: "clean",
            isDirty: false, points: [GeometryCulvertCoordinate(x: 1, y: 2),
                                     GeometryCulvertCoordinate(x: 3, y: 4)])
    }

    func modelRequest(for asset: ProjectAsset) -> GeometryCulvertModelRequest {
        GeometryCulvertModelRequest(assetPath: asset.url.path, kind: "Geometry",
            projectPath: nil, projectXml: nil)
    }

    func load(_ model: GeometryCulvertModelRequest, expectedRevision: String?, draftState: String?,
              selectedBarrelIDs: [String]) async throws -> GeometryCulvertSnapshot {
        loadCount += 1
        return current
    }

    func edit(_ model: GeometryCulvertModelRequest, revision: String, draftState: String,
              mutation: GeometryCulvertMutation, selectedBarrelIDs: [String]) async throws -> GeometryCulvertSnapshot {
        guard mutation.operation == "reverseBarrel",
              let row = current.barrels.rows.first(where: { mutation.featureIDs.contains($0.id) }) else {
            return current
        }
        current = Self.snapshot(revision: revision, draftState: "dirty-draft",
            isDirty: true, points: Array(row.polyline.reversed()))
        return current
    }

    private static func snapshot(revision: String, draftState: String, isDirty: Bool,
                                 points: [GeometryCulvertCoordinate]) -> GeometryCulvertSnapshot {
        let row = GeometryCulvertFeatureRow(id: "barrel:source:7", fid: 7,
            values: ["Name": "Culvert 7"], polyline: points)
        let barrels = GeometryCulvertFeatureTable(featureKind: "barrel", columns: [],
            editableFields: [], rows: [row])
        let emptyBarrels = GeometryCulvertFeatureTable(featureKind: "barrelProperties", columns: [],
            editableFields: [], rows: [])
        let emptyOpenings = GeometryCulvertFeatureTable(featureKind: "openingProperties", columns: [],
            editableFields: [], rows: [])
        return GeometryCulvertSnapshot(revision: revision, draftState: draftState,
            canEdit: true, isDirty: isDirty, barrels: barrels,
            barrelProperties: emptyBarrels, openingProperties: emptyOpenings,
            associatedTerrainName: nil, profiles: [])
    }
}

struct GeometryCulvertMapHoverOwnerTests {
    @Test @MainActor
    func hoverCaptureRequiresOneReadyExactOwnerAndReturnsDirtyBarrelGeometry() async throws {
        let parentProvider = CulvertMapHoverParentProvider()
        let childProvider = CulvertMapHoverChildProvider()
        let asset = ProjectAsset(url: URL(fileURLWithPath: "/fixture/geometry.h5"), section: .geometries)
        let editor = ModelEditorSession(provider: parentProvider, culvertProvider: childProvider)
        await editor.load(asset, kind: .geometry)
        let store = WorkspaceStore(modelProvider: parentProvider)
        store.registerEditor(editor)
        let model = childProvider.modelRequest(for: asset)

        // A registered parent blocks saved-source fallback until its child
        // has loaded the exact same HDF revision and model context.
        #expect(store.geometryCulvertMapHoverSnapshot(assetID: asset.id,
            projectSessionID: store.projectSessionID, expectedRevision: "geometry-source-sha",
            model: model).map(\.revision) == nil)
        #expect(childProvider.loadCount == 0)
        let clean = try #require(await store.prepareGeometryCulvertMapHoverSnapshot(assetID: asset.id,
            projectSessionID: store.projectSessionID, expectedRevision: "geometry-source-sha",
            model: model))
        #expect(childProvider.loadCount == 1)
        #expect(!clean.isDirty)
        #expect(clean.barrels.rows.first?.polyline == [
            GeometryCulvertCoordinate(x: 1, y: 2), GeometryCulvertCoordinate(x: 3, y: 4)
        ])
        #expect(await store.prepareGeometryCulvertMapHoverSnapshot(assetID: asset.id,
            projectSessionID: store.projectSessionID, expectedRevision: "geometry-source-sha",
            model: model)?.revision == "geometry-source-sha")
        #expect(childProvider.loadCount == 1)

        #expect(store.geometryCulvertMapHoverSnapshot(assetID: asset.id,
            projectSessionID: store.projectSessionID, expectedRevision: "stale-source-sha",
            model: model).map(\.revision) == nil)
        let wrongModel = GeometryCulvertModelRequest(assetPath: model.assetPath, kind: model.kind,
            projectPath: "/another/project.ras", projectXml: model.projectXml,
            coreLayerContext: model.coreLayerContext)
        #expect(store.geometryCulvertMapHoverSnapshot(assetID: asset.id,
            projectSessionID: store.projectSessionID, expectedRevision: "geometry-source-sha",
            model: wrongModel).map(\.revision) == nil)
        #expect(await store.prepareGeometryCulvertMapHoverSnapshot(assetID: asset.id,
            projectSessionID: store.projectSessionID, expectedRevision: "geometry-source-sha",
            model: wrongModel).map(\.revision) == nil)
        #expect(childProvider.loadCount == 1)

        await editor.geometryCulvert?.select(["barrel:source:7"], featureKind: "barrel")
        #expect(await editor.geometryCulvert?.reverseBarrel(id: "barrel:source:7") == true)
        let dirty = try #require(store.geometryCulvertMapHoverSnapshot(assetID: asset.id,
            projectSessionID: store.projectSessionID, expectedRevision: "geometry-source-sha",
            model: model))
        #expect(dirty.isDirty)
        #expect(dirty.barrels.rows.first?.polyline == [
            GeometryCulvertCoordinate(x: 3, y: 4), GeometryCulvertCoordinate(x: 1, y: 2)
        ])

        let duplicate = ModelEditorSession(provider: parentProvider, culvertProvider: childProvider)
        await duplicate.load(asset, kind: .geometry)
        store.registerEditor(duplicate)
        #expect(store.geometryMeshEditorCount(for: asset.id) == 2)
        #expect(store.geometryCulvertMapHoverSnapshot(assetID: asset.id,
            projectSessionID: store.projectSessionID, expectedRevision: "geometry-source-sha",
            model: model).map(\.revision) == nil)
        #expect(store.geometryCulvertMapHoverSnapshot(assetID: asset.id,
            projectSessionID: UUID(), expectedRevision: "geometry-source-sha",
            model: model).map(\.revision) == nil)
    }
}
