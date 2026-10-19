import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class ContextBoundCulvertProvider: GeometryCulvertProvider {
    var projectXML = "terrain=A"
    private(set) var loadRequests: [GeometryCulvertModelRequest] = []

    func modelRequest(for asset: ProjectAsset) -> GeometryCulvertModelRequest {
        GeometryCulvertModelRequest(assetPath: asset.url.path, kind: "Geometry",
            projectPath: "/fixture/project.ras", projectXml: projectXML)
    }

    func load(_ model: GeometryCulvertModelRequest, expectedRevision: String?, draftState: String?,
              selectedBarrelIDs: [String]) async throws -> GeometryCulvertSnapshot {
        loadRequests.append(model)
        if model.projectXml == "terrain=B", draftState != nil { throw CulvertDraftContextError.stale }
        return snapshot(revision: expectedRevision ?? "geometry-revision",
            draftState: draftState ?? "opaque-clean", isDirty: draftState != nil)
    }

    func edit(_ model: GeometryCulvertModelRequest, revision: String, draftState: String,
              mutation: GeometryCulvertMutation, selectedBarrelIDs: [String]) async throws -> GeometryCulvertSnapshot {
        snapshot(revision: revision, draftState: "opaque-dirty", isDirty: true)
    }

    private func snapshot(revision: String, draftState: String, isDirty: Bool) -> GeometryCulvertSnapshot {
        let barrels = GeometryCulvertFeatureTable(featureKind: "barrel", columns: [], editableFields: [], rows: [])
        let barrelProperties = GeometryCulvertFeatureTable(featureKind: "barrelProperties", columns: [], editableFields: [], rows: [])
        let openingProperties = GeometryCulvertFeatureTable(featureKind: "openingProperties", columns: [], editableFields: [], rows: [])
        return GeometryCulvertSnapshot(revision: revision, draftState: draftState, canEdit: true, isDirty: isDirty,
            barrels: barrels, barrelProperties: barrelProperties, openingProperties: openingProperties,
            associatedTerrainName: "Terrain A", profiles: [])
    }
}

private enum CulvertDraftContextError: Error, LocalizedError {
    case stale
    var errorDescription: String? { "The selected terrain changed while culvert edits are pending." }
}

struct GeometryCulvertSessionTests {
    @Test @MainActor
    func unrelatedProjectXMLChangeReplaysDraftAndChangedTerrainKeepsDraftVisibleAsStale() async throws {
        let provider = ContextBoundCulvertProvider()
        let child = GeometryCulvertSession(provider: provider)
        let asset = ProjectAsset(url: URL(fileURLWithPath: "/fixture/geometry.h5"), section: .geometries)

        await child.ensureLoaded(asset: asset, sourceRevision: "geometry-revision")
        await child.addPropertySet(featureKind: "barrelProperties")
        #expect(child.isDirty)

        provider.projectXML = "terrain=A;description=updated"
        await child.ensureLoaded(asset: asset, sourceRevision: "geometry-revision")
        #expect(provider.loadRequests.count == 2)
        #expect(provider.loadRequests.last?.projectXml == "terrain=A;description=updated")
        #expect(child.isDirty && child.error == nil && !child.isProfileContextStale)

        provider.projectXML = "terrain=B"
        await child.ensureLoaded(asset: asset, sourceRevision: "geometry-revision")
        #expect(provider.loadRequests.count == 3)
        #expect(child.isDirty && child.error != nil)
        #expect(child.isProfileContextStale)
        #expect(child.geometryCulvertStateForParentSave == "opaque-dirty")
    }
}
