import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
struct GeometryMeshDiagnosticsHistoryTests {
    @Test func historyKeepsThreeMostRecentSourceResultsAndClearsOnEmptyBuildResult() {
        let history = GeometryMeshDiagnosticsHistory.shared
        history.clear()
        defer { history.clear() }

        for index in 0..<4 {
            history.record(event("operation-\(index)", messages: [message("message-\(index)")]),
                assetID: "geometry-\(index)", geometryName: "Geometry \(index)")
        }

        #expect(history.entries.count == 3)
        #expect(history.entries.map(\.id) == ["operation-3", "operation-2", "operation-1"])
        #expect(history.selectedEntryID == "operation-3")

        history.record(event("operation-3", messages: [message("duplicate")]),
            assetID: "geometry-3", geometryName: "Geometry 3")
        #expect(history.entries.count == 3)
        #expect(history.entries[0].messages.first?.id == "message-3")

        history.record(event("operation-empty", messages: []), assetID: "geometry", geometryName: "Geometry")
        #expect(history.entries.isEmpty)
        #expect(history.selectedEntryID == nil)
    }

    @Test func selectedHistoryRetainsSourceValueLinksAndCoordinate() throws {
        let history = GeometryMeshDiagnosticsHistory.shared
        history.clear()
        defer { history.clear() }
        let feature = GeometryTopologyMapFeature(id: "arc:41", featureKind: "arc", fid: 41,
            geometryType: "line", selectionIDs: ["arc:41"],
            paths: [[.init(x: 1, y: 2), .init(x: 3, y: 4)]])
        let sourceMessage = GeometryMeshDiagnosticMessage(id: "operation:message:0", code: "Mesh_Code",
            severity: "Warning", evaluatedMessage: "Arc 41 near coordinate.", values: [
                GeometryMeshDiagnosticValue(id: "arc-value", key: "ArcIndex", value: "0",
                    selectionIDs: ["arc:41"], targetFeatureID: "arc:41", coordinate: nil),
                GeometryMeshDiagnosticValue(id: "coordinate-value", key: "Coordinate", value: "(2, 3)",
                    selectionIDs: [], targetFeatureID: nil, coordinate: .init(x: 2, y: 3))
            ])
        history.record(GeometryMeshDiagnosticHistoryEvent(operationID: "operation", result: false,
            messages: [sourceMessage], topology: GeometryTopologyMapData(extent: .init(minX: 0, minY: 0,
                maxX: 4, maxY: 5), features: [feature])), assetID: "geometry", geometryName: "Geometry")

        let selected = try #require(history.selectedEntry)
        #expect(selected.result == false)
        #expect(selected.messages.first?.code == "Mesh_Code")
        #expect(selected.messages.first?.values.first?.selectionIDs == ["arc:41"])
        #expect(selected.messages.first?.values.last?.coordinate == .init(x: 2, y: 3))
        #expect(selected.topology.features.first?.fid == 41)
    }

    @Test func sourceEntryRoundingAndBoundsMatchMaxFacesPerNodeEntry() {
        #expect(GeometryMeshSession.normalizedMaxFacesPerNodeEntry(3.49) == 3)
        #expect(GeometryMeshSession.normalizedMaxFacesPerNodeEntry(3.5) == 4)
        #expect(GeometryMeshSession.normalizedMaxFacesPerNodeEntry(8.5) == 9)
        #expect(GeometryMeshSession.normalizedMaxFacesPerNodeEntry(2.2) == 3)
        #expect(GeometryMeshSession.normalizedMaxFacesPerNodeEntry(64.5) == 64)
        #expect(GeometryMeshSession.normalizedMaxFacesPerNodeEntry(.infinity) == nil)
    }

    @Test func changedMapScopeKeepsOldDraftSaveableAndMovesOnlyAfterAcknowledgement() async {
        let asset = ProjectAsset(url: URL(fileURLWithPath: "/fixture/geometry.h5"), section: .geometries)
        let session = GeometryMeshSession(provider: DiagnosticsPreferencesProvider())
        await session.ensureLoaded(asset: asset, sourceRevision: "hdf-1", topologyDraftState: nil)
        let firstScope = scope(assetID: asset.id, mapIndex: 0, mapName: "Project", revision: "vis-1")
        let nextScope = scope(assetID: asset.id, mapIndex: 1, mapName: "Plan A", revision: "vis-1")
        #expect(session.installDiagnosticsPreferences(.init(checkMeshErrors: false, maxFacesPerNode: 8), scope: firstScope))

        await session.setMaxFacesPerNodeEntry(12)
        #expect(session.hasUnsavedDiagnosticsPreferences)
        #expect(!session.installDiagnosticsPreferences(.init(checkMeshErrors: false, maxFacesPerNode: 6), scope: nextScope))
        #expect(session.diagnosticsPreferencesScope == firstScope)
        #expect(session.diagnosticsPreferencesScopeMismatch)
        #expect(session.canBeginDiagnosticsPreferencesSave)

        let capture = session.beginDiagnosticsPreferencesSave()
        #expect(capture?.scope == firstScope)
        #expect(capture?.settings.maxFacesPerNode == 12)
        if let capture {
            session.acceptDiagnosticsPreferencesSave(capture, newSourceRevision: "vis-2")
        }

        #expect(!session.hasUnsavedDiagnosticsPreferences)
        #expect(!session.diagnosticsPreferencesScopeMismatch)
        #expect(session.diagnosticsPreferencesScope?.mapName == "Plan A")
        #expect(session.diagnosticsPreferencesScope?.visualizationRevision == "vis-2")
        #expect(session.diagnosticsPreferences.maxFacesPerNode == 6)
    }

    @Test func failedSaveRetainsOldPreferenceDraftUntilExplicitDiscard() async throws {
        let asset = ProjectAsset(url: URL(fileURLWithPath: "/fixture/geometry.h5"), section: .geometries)
        let session = GeometryMeshSession(provider: DiagnosticsPreferencesProvider())
        await session.ensureLoaded(asset: asset, sourceRevision: "hdf-1", topologyDraftState: nil)
        let firstScope = scope(assetID: asset.id, mapIndex: 0, mapName: "Project", revision: "vis-1")
        let nextScope = scope(assetID: asset.id, mapIndex: 1, mapName: "Plan A", revision: "vis-1")
        #expect(session.installDiagnosticsPreferences(.init(checkMeshErrors: false, maxFacesPerNode: 8), scope: firstScope))
        await session.setMaxFacesPerNodeEntry(12)
        _ = session.installDiagnosticsPreferences(.init(checkMeshErrors: false, maxFacesPerNode: 6), scope: nextScope)

        let capture = try #require(session.beginDiagnosticsPreferencesSave())
        session.diagnosticsPreferencesSaveFailed(capture, message: "The source changed externally.")
        #expect(session.hasUnsavedDiagnosticsPreferences)
        #expect(session.diagnosticsPreferencesScope == firstScope)
        #expect(session.diagnosticsPreferences.maxFacesPerNode == 12)

        session.discardDiagnosticsPreferences()
        #expect(!session.hasUnsavedDiagnosticsPreferences)
        #expect(session.diagnosticsPreferencesScope?.mapName == "Plan A")
        #expect(session.diagnosticsPreferences.maxFacesPerNode == 6)
    }

    private func scope(assetID: String, mapIndex: Int, mapName: String,
                       revision: String) -> GeometryMeshDiagnosticsScope {
        GeometryMeshDiagnosticsScope(mapIndex: mapIndex, mapName: mapName, mapType: "Project",
            geometryName: "Geometry", assetID: assetID, visualizationRevision: revision)
    }

    private func event(_ id: String, messages: [GeometryMeshDiagnosticMessage]) -> GeometryMeshDiagnosticHistoryEvent {
        GeometryMeshDiagnosticHistoryEvent(operationID: id, result: false, messages: messages,
            topology: .empty)
    }

    private func message(_ id: String) -> GeometryMeshDiagnosticMessage {
        GeometryMeshDiagnosticMessage(id: id, code: "Mesh_Code", severity: "Warning",
            evaluatedMessage: id, values: [])
    }
}

@MainActor
private final class DiagnosticsPreferencesProvider: GeometryMeshProvider {
    func modelRequest(for asset: ProjectAsset) -> GeometryMeshModelRequest {
        GeometryMeshModelRequest(assetPath: asset.url.path, kind: "Geometry", projectPath: nil, projectXml: nil)
    }

    func currentTopologyDraftState() -> String? { nil }

    func load(_ model: GeometryMeshModelRequest, expectedRevision: String?, draftState: String?,
              topologyDraftState: String?, selectedRegionIDs: [Int]) async throws -> GeometryMeshSnapshot {
        GeometryMeshSnapshot(revision: expectedRevision ?? "hdf-1", draftState: draftState ?? "mesh-draft",
            topologyFingerprint: "topology", canEdit: true, isDirty: false, flowAreas: [],
            regions: GeometryTopologyFeatureTable(featureKind: "region", columns: [], editableFields: [], rows: []),
            selectedRegionIDs: [], patchSizing: nil, generationReport: nil, prepareSummary: nil)
    }

    func edit(_ model: GeometryMeshModelRequest, revision: String, draftState: String,
              topologyDraftState: String?, mutation: GeometryMeshMutation,
              selectedRegionIDs: [Int]) async throws -> GeometryMeshSnapshot {
        fatalError("Preference lifecycle tests do not edit source mesh data.")
    }

    func scanDegreeErrors(_ model: GeometryMeshModelRequest, revision: String, draftState: String,
                          topologyDraftState: String?, maxFacesPerNode: Int) async throws -> GeometryMeshDegreeScan {
        GeometryMeshDegreeScan(maxFacesPerNode: maxFacesPerNode, issues: [])
    }
}
