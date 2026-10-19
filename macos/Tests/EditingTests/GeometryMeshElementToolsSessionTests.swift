import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@Suite(.serialized)
@MainActor
struct GeometryMeshElementToolsSessionTests {
    @Test
    func lateFindIsDroppedAfterFlowAreaSelectionChanges() async throws {
        let (session, _) = await makeSession()
        let provider = DeferredMeshElementToolsProvider()
        var context = GeometryMeshToolsProjectContext(projectSessionID: UUID(), coreLayerContext: nil)
        session.selectFlowArea("area-a")

        let request = Task { @MainActor in
            await session.findElement(flowAreaID: "area-a", elementKind: .cell, index: 0,
                currentProjectContext: { context }, provider: provider)
        }
        try await waitUntil { provider.pendingFindRequest != nil }
        session.selectFlowArea("area-b")
        provider.completeFind()
        #expect(await request.value == false)
        #expect(session.meshElementFind == nil)
        #expect(!session.isFindingMeshElement)

        // A response for the original project-session token is also rejected
        // if selection remains stable but the host switches project owners.
        session.selectFlowArea("area-a")
        let second = Task { @MainActor in
            await session.findElement(flowAreaID: "area-a", elementKind: .node, index: 0,
                currentProjectContext: { context }, provider: provider)
        }
        try await waitUntil { provider.pendingFindRequest != nil }
        context = GeometryMeshToolsProjectContext(projectSessionID: UUID(), coreLayerContext: nil)
        provider.completeFind()
        #expect(await second.value == false)
        #expect(session.meshElementFind == nil)
    }

    @Test
    func cancellationBeforeCommitStoresNoReceipt() async throws {
        let (session, _) = await makeSession()
        let provider = DeferredMeshElementToolsProvider()
        let context = GeometryMeshToolsProjectContext(projectSessionID: UUID(), coreLayerContext: nil)
        session.selectFlowArea("area-a")
        let output = uniqueOutputURL("cancelled")
        let task = Task { @MainActor in
            await session.exportShapefile(flowAreaID: "area-a", exportKind: .cellCenters,
                outputURL: output, currentProjectContext: { context }, provider: provider)
        }
        try await waitUntil { provider.pendingExportRequest != nil }
        let operationID = try #require(provider.pendingExportRequest?.operationID)
        session.cancelMeshShapefileExport()
        #expect(provider.cancelledOperationIDs.contains(operationID))
        provider.completeExport(state: "cancelled")
        await task.value

        #expect(session.meshShapefileExportOutcome == "cancelled")
        #expect(session.meshShapefileExportReceipts.isEmpty)
    }

    @Test
    func committedReceiptSurvivesOwnerChangeAfterCancellationRequest() async throws {
        let (session, _) = await makeSession()
        let provider = DeferredMeshElementToolsProvider()
        let context = GeometryMeshToolsProjectContext(projectSessionID: UUID(), coreLayerContext: nil)
        session.selectFlowArea("area-a")
        let output = uniqueOutputURL("committed")
        let task = Task { @MainActor in
            await session.exportShapefile(flowAreaID: "area-a", exportKind: .perimeterFaces,
                outputURL: output, currentProjectContext: { context }, provider: provider)
        }
        try await waitUntil { provider.pendingExportRequest != nil }
        let request = try #require(provider.pendingExportRequest)
        session.cancelMeshShapefileExport()
        session.selectFlowArea("area-b")
        #expect(provider.cancelledOperationIDs.contains(request.operationID))

        // The backend may have committed just before it receives cancellation.
        // Its completed terminal response is the durable receipt and must be kept.
        provider.completeExport(state: "completed")
        await task.value

        let receipt = try #require(session.meshShapefileExportReceipts.first)
        #expect(receipt.id == request.operationID)
        #expect(receipt.result.state == "completed")
        #expect(receipt.result.outputPath == request.outputPath)
        #expect(receipt.result.artifacts.count == 3)
        #expect(session.meshToolsError == nil)
    }

    private func makeSession() async -> (GeometryMeshSession, ToolSessionProvider) {
        let meshProvider = ToolSessionProvider()
        let session = GeometryMeshSession(provider: meshProvider)
        let asset = ProjectAsset(url: URL(fileURLWithPath: "/temporary/mesh-tools-geometry.h5"),
            section: .geometries)
        await session.ensureLoaded(asset: asset, sourceRevision: "source-r1", topologyDraftState: nil)
        return (session, meshProvider)
    }

    private func uniqueOutputURL(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mesh-tools-\(UUID().uuidString)-\(suffix).shp")
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition())
    }
}

@MainActor
private final class ToolSessionProvider: GeometryMeshProvider {
    private let rows = [
        GeometryMeshFlowAreaRow(id: "area-a", rowIndex: 0, name: "Area A", targetedCellSpacing: nil,
            hasMesh: true, cellCount: 1, faceCount: 4, nodeCount: 4, extent: nil,
            hasMeshErrors: false, hasPropertyTables: false, propertyTablesQueuedForParentSave: false,
            propertyTablesPinned: false, metadata: []),
        GeometryMeshFlowAreaRow(id: "area-b", rowIndex: 1, name: "Area B", targetedCellSpacing: nil,
            hasMesh: true, cellCount: 1, faceCount: 4, nodeCount: 4, extent: nil,
            hasMeshErrors: false, hasPropertyTables: false, propertyTablesQueuedForParentSave: false,
            propertyTablesPinned: false, metadata: [])
    ]

    func modelRequest(for asset: ProjectAsset) -> GeometryMeshModelRequest {
        .init(assetPath: asset.url.path, kind: "Geometry", projectPath: "/temporary/project.ras",
            projectXml: "<Project />")
    }
    func currentTopologyDraftState() -> String? { nil }

    func load(_ model: GeometryMeshModelRequest, expectedRevision: String?, draftState: String?,
              topologyDraftState: String?, selectedRegionIDs: [Int]) async throws -> GeometryMeshSnapshot {
        GeometryMeshSnapshot(revision: expectedRevision ?? "source-r1", draftState: draftState ?? "mesh-draft",
            topologyFingerprint: "topology", canEdit: true, isDirty: false, flowAreas: rows,
            regions: .init(featureKind: "region", columns: [], editableFields: [], rows: []),
            selectedRegionIDs: [], patchSizing: nil, generationReport: nil, prepareSummary: nil)
    }

    func edit(_ model: GeometryMeshModelRequest, revision: String, draftState: String,
              topologyDraftState: String?, mutation: GeometryMeshMutation,
              selectedRegionIDs: [Int]) async throws -> GeometryMeshSnapshot {
        throw CocoaError(.featureUnsupported)
    }

    func scanDegreeErrors(_ model: GeometryMeshModelRequest, revision: String, draftState: String,
                          topologyDraftState: String?, maxFacesPerNode: Int) async throws -> GeometryMeshDegreeScan {
        .init(maxFacesPerNode: maxFacesPerNode, issues: [])
    }
}

@MainActor
private final class DeferredMeshElementToolsProvider: GeometryMeshElementToolsProviding {
    private(set) var pendingFindRequest: GeometryMeshElementFindRequest?
    private var findContinuation: CheckedContinuation<GeometryMeshElementFindResult, any Error>?
    private(set) var pendingExportRequest: GeometryMeshShapefileExportRequest?
    private var exportContinuation: CheckedContinuation<GeometryMeshShapefileExportResult, any Error>?
    private(set) var cancelledOperationIDs: Set<String> = []

    func findElement(_ request: GeometryMeshElementFindRequest) async throws -> GeometryMeshElementFindResult {
        try await withCheckedThrowingContinuation { continuation in
            pendingFindRequest = request
            findContinuation = continuation
        }
    }

    func exportShapefile(_ request: GeometryMeshShapefileExportRequest,
                         progress: @escaping @MainActor (BackendProgressUpdate) -> Void) async throws
        -> GeometryMeshShapefileExportResult {
        try await withCheckedThrowingContinuation { continuation in
            pendingExportRequest = request
            exportContinuation = continuation
        }
    }

    func cancelExport(operationID: String) -> Bool {
        cancelledOperationIDs.insert(operationID)
        return true
    }

    func completeFind() {
        guard let request = pendingFindRequest, let continuation = findContinuation else { return }
        pendingFindRequest = nil
        findContinuation = nil
        let coordinate = GeometryTopologyCoordinate(x: 2, y: 3)
        let coordinates: [GeometryTopologyCoordinate]
        switch request.elementKind {
        case GeometryMeshElementKind.cell.rawValue:
            coordinates = [coordinate, .init(x: 3, y: 3), .init(x: 2, y: 4)]
        case GeometryMeshElementKind.face.rawValue:
            coordinates = [coordinate, .init(x: 3, y: 3)]
        default:
            coordinates = [coordinate]
        }
        continuation.resume(returning: GeometryMeshElementFindResult(
            canonicalAssetPath: request.model.assetPath, sourceRevision: request.revision,
            flowAreaID: request.flowAreaID, flowAreaName: request.expectedFlowAreaName,
            elementKind: request.elementKind, index: request.index,
            meshDraftSHA256: request.meshDraftSHA256, topologyDraftSHA256: request.topologyDraftSHA256,
            x: coordinate.x, y: coordinate.y,
            viewport: .init(minX: 0, minY: 0, maxX: 5, maxY: 5),
            coordinates: coordinates))
    }

    func completeExport(state: String) {
        guard let request = pendingExportRequest, let continuation = exportContinuation else { return }
        pendingExportRequest = nil
        exportContinuation = nil
        let path = URL(fileURLWithPath: request.outputPath)
        let artifacts: [GeometryMeshShapefileExportArtifactReceipt]
        if state == "completed" {
            artifacts = ["shp", "shx", "dbf"].map { suffix in
                .init(path: path.deletingPathExtension().appendingPathExtension(suffix).path,
                    sizeBytes: 1, sha256: String(repeating: "0", count: 64))
            }
        } else {
            artifacts = []
        }
        continuation.resume(returning: GeometryMeshShapefileExportResult(
            operationID: request.operationID, state: state,
            canonicalAssetPath: request.model.assetPath, sourceRevision: request.revision,
            flowAreaID: request.flowAreaID, flowAreaName: request.expectedFlowAreaName,
            exportKind: request.exportKind, meshDraftSHA256: request.meshDraftSHA256,
            topologyDraftSHA256: request.topologyDraftSHA256,
            outputPath: state == "completed" ? request.outputPath : nil,
            featureCount: state == "completed" ? 1 : 0, projectionWKT: nil, artifacts: artifacts))
    }
}
