import CryptoKit
import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@Suite(.serialized)
struct BackendGeometryMeshElementChartWorkflowTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_GEOMETRY_MESH_ELEMENT_CHART_ACCEPTANCE_DIRECTORY"] != nil
        && ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil)) @MainActor
    func bundledHostComputesUnsavedChildAndPlotsExactGeometryTable() async throws {
        let environment = ProcessInfo.processInfo.environment
        let fixtureDirectory = URL(fileURLWithPath: try #require(
            environment["HECRAS_GEOMETRY_MESH_ELEMENT_CHART_ACCEPTANCE_DIRECTORY"]), isDirectory: true)
        let backendPath = try #require(environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let fixtureData = try Data(contentsOf: fixtureDirectory.appendingPathComponent("chart-request.json"))
        let fixture = try JSONDecoder().decode(GeometryMeshElementChartWireFixture.self, from: fixtureData)
        let sourcePath = URL(fileURLWithPath: fixture.model.assetPath)
        let sourceBytes = try Data(contentsOf: sourcePath)
        let client = BackendProcessClient(executableURL: URL(fileURLWithPath: backendPath))
        let geometryProvider = BackendGeometryMeshProvider(client: client)

        let computeRequest = GeometryMeshPropertyTablesRequest(model: fixture.model,
            revision: fixture.revision, draftState: fixture.draftState,
            topologyDraftState: fixture.topologyDraftState, selectedRegionIDs: [])
        let computeOperation = try geometryProvider.startComputePropertyTables(computeRequest)
        for try await _ in computeOperation.events {}
        let computed = try await computeOperation.value()
        #expect(computed.succeeded)
        #expect(computed.snapshot.isDirty)
        #expect(computed.snapshot.flowAreas.first(where: { $0.id == fixture.flowAreaID })?.hasPropertyTables == true)
        #expect(try Data(contentsOf: sourcePath) == sourceBytes)

        let chartRequest = GeometryMeshElementPropertyChartRequest(projectSessionID: fixture.projectSessionID,
            assetID: fixture.assetID, model: fixture.model, revision: fixture.revision,
            draftState: computed.snapshot.draftState, topologyDraftState: fixture.topologyDraftState,
            meshDraftSHA256: geometryChartSHA256(computed.snapshot.draftState),
            topologyDraftSHA256: fixture.topologyDraftSHA256,
            flowAreaID: fixture.flowAreaID, expectedFlowAreaName: fixture.expectedFlowAreaName,
            elementKind: fixture.elementKind, elementIndex: fixture.elementIndex)
        let chartProvider = BackendGeometryMeshElementChartProvider(client: client)
        var progress: [BackendProgressUpdate] = []
        let result = try await chartProvider.load(chartRequest) { progress.append($0) }
        #expect(result.state == "ready")
        #expect(result.operationID == chartRequest.operationID)
        #expect(result.projectSessionID.caseInsensitiveCompare(fixture.projectSessionID) == .orderedSame)
        #expect(result.meshDraftSHA256.caseInsensitiveCompare(chartRequest.meshDraftSHA256) == .orderedSame)
        #expect(result.elementKind == "Cell" && result.elementIndex == fixture.elementIndex)
        #expect(result.xQuantity == "Volume" && result.yQuantity == "Elevation")
        #expect(result.xUnits == "m³" && result.yUnits == "m")
        #expect(result.points.count >= 2 && result.points.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        #expect(progress.contains { $0.taskName != nil || $0.fraction != nil || $0.message != nil })
        #expect(try Data(contentsOf: sourcePath) == sourceBytes)
    }
}

private struct GeometryMeshElementChartWireFixture: Decodable {
    let projectSessionID: String
    let assetID: String
    let model: GeometryMeshModelRequest
    let revision: String
    let draftState: String
    let topologyDraftState: String
    let meshDraftSHA256: String
    let topologyDraftSHA256: String
    let flowAreaID: String
    let expectedFlowAreaName: String
    let elementKind: String
    let elementIndex: Int
}

private func geometryChartSHA256(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02X", $0) }.joined()
}
