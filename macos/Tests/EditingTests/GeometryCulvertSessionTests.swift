import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class ContextBoundCulvertProvider: GeometryCulvertProvider {
    var projectXML = "terrain=A"
    var failNextEditWithSourceChanged = false
    private(set) var loadRequests: [GeometryCulvertModelRequest] = []
    private(set) var editRequests: [GeometryCulvertMutation] = []

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
        editRequests.append(mutation)
        if failNextEditWithSourceChanged {
            failNextEditWithSourceChanged = false
            throw BackendServiceError(code: "sourceChanged", message: "The geometry source changed during this edit.")
        }
        return snapshot(revision: revision, draftState: "opaque-dirty", isDirty: true, applying: mutation)
    }

    private func snapshot(revision: String, draftState: String, isDirty: Bool,
                          applying mutation: GeometryCulvertMutation? = nil) -> GeometryCulvertSnapshot {
        let barrels = GeometryCulvertFeatureTable(featureKind: "barrel", columns: [], editableFields: [], rows: [])
        let nameColumn = GeometryCulvertColumn(id: "Name", title: "Name", sourceType: "string", readOnly: false)
        let nameField = GeometryCulvertField(id: "Name", title: "Name", sourceType: "string", choices: [],
            readOnly: false, minimum: nil, maximum: nil)
        let barrelPropertyRows = (0...1).map { fid in
            let id = "barrelProperties:source:\(fid)"
            var values = ["Name": fid == 0 ? "Barrel A" : "Barrel B"]
            if let mutation, mutation.operation == "setField", mutation.featureKind == "barrelProperties",
               mutation.featureIDs.contains(id), mutation.fieldID == "Name", let value = mutation.value {
                values["Name"] = value
            }
            return GeometryCulvertFeatureRow(id: id, fid: fid, values: values, polyline: [])
        }
        let barrelProperties = GeometryCulvertFeatureTable(featureKind: "barrelProperties", columns: [nameColumn],
            editableFields: [nameField], rows: barrelPropertyRows)
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
    func sourceChangedEditFailureMarksCulvertContextStaleAndBlocksFurtherApply() async throws {
        let provider = ContextBoundCulvertProvider()
        let child = GeometryCulvertSession(provider: provider)
        let asset = ProjectAsset(url: URL(fileURLWithPath: "/fixture/geometry.h5"), section: .geometries)
        await child.ensureLoaded(asset: asset, sourceRevision: "geometry-revision")
        let selectedIDs: Set<String> = ["barrelProperties:source:0"]
        await child.select(selectedIDs, featureKind: "barrelProperties")
        let capturedContext = child.selectionDraftContextIdentity
        provider.failNextEditWithSourceChanged = true

        let applied = await child.setField(featureKind: "barrelProperties", fieldID: "Name", value: "Updated",
            expectedSelectedIDs: selectedIDs, expectedContextIdentity: capturedContext)
        #expect(!applied)
        #expect(child.isProfileContextStale)
        #expect(!child.canEdit)
        #expect(child.selectionDraftContextIdentity != capturedContext)
        #expect(provider.editRequests.count == 1)

        let retry = await child.setField(featureKind: "barrelProperties", fieldID: "Name", value: "Updated",
            expectedSelectedIDs: selectedIDs, expectedContextIdentity: child.selectionDraftContextIdentity)
        #expect(!retry)
        #expect(provider.editRequests.count == 1)
    }

    @Test @MainActor
    func staleSelectionOrDraftContextCannotSubmitCapturedCulvertFieldEdit() async throws {
        let provider = ContextBoundCulvertProvider()
        let child = GeometryCulvertSession(provider: provider)
        let asset = ProjectAsset(url: URL(fileURLWithPath: "/fixture/geometry.h5"), section: .geometries)
        await child.ensureLoaded(asset: asset, sourceRevision: "geometry-revision")

        let selectedIDs: Set<String> = ["barrelProperties:source:0"]
        await child.select(selectedIDs, featureKind: "barrelProperties")
        let capturedContext = child.selectionDraftContextIdentity
        provider.projectXML = "terrain=A;description=changed"
        await child.ensureLoaded(asset: asset, sourceRevision: "geometry-revision")
        #expect(child.selectionDraftContextIdentity != capturedContext)
        let staleSourceApplied = await child.setField(featureKind: "barrelProperties", fieldID: "Name", value: "Old source",
            expectedSelectedIDs: selectedIDs, expectedContextIdentity: capturedContext)
        #expect(!staleSourceApplied)
        #expect(provider.editRequests.isEmpty)

        let currentContext = child.selectionDraftContextIdentity
        let applied = await child.setField(featureKind: "barrelProperties", fieldID: "Name", value: "Updated",
            expectedSelectedIDs: selectedIDs, expectedContextIdentity: currentContext)
        #expect(applied)
        #expect(provider.editRequests.count == 1)

        let staleDraftApplied = await child.setField(featureKind: "barrelProperties", fieldID: "Name", value: "Stale",
            expectedSelectedIDs: selectedIDs, expectedContextIdentity: currentContext)
        #expect(!staleDraftApplied)
        #expect(provider.editRequests.count == 1)

        let updatedDraftContext = child.selectionDraftContextIdentity
        await child.select(["barrelProperties:source:1"], featureKind: "barrelProperties")
        let staleSelectionApplied = await child.setField(featureKind: "barrelProperties", fieldID: "Name", value: "Wrong row",
            expectedSelectedIDs: selectedIDs, expectedContextIdentity: updatedDraftContext)
        #expect(!staleSelectionApplied)
        #expect(provider.editRequests.count == 1)
    }

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
