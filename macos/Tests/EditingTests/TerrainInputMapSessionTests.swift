import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class TerrainInputMapProviderFixture: TerrainInputMapContextProvider {
    private(set) var requests: [TerrainInputMapContextRequest] = []
    var response: TerrainInputMapContextData?
    private var continuation: CheckedContinuation<TerrainInputMapContextData, any Error>?

    func renderTerrainInput(_ request: TerrainInputMapContextRequest) async throws -> TerrainInputMapContextData {
        requests.append(request)
        if let response { return response }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func complete(_ response: TerrainInputMapContextData) {
        continuation?.resume(returning: response)
        continuation = nil
    }
}

@MainActor
private final class TerrainInputSourceReadPermission {
    var isAllowed = true
}

@MainActor
struct TerrainInputMapSessionTests {
    private let nodeID = "terrain-input:4A9F"
    private let terrainPath = "/tmp/terrain-input-map-session.hdf"

    @Test
    func checkedInputInstallsOnlyMatchingSourceGeometry() async {
        let provider = TerrainInputMapProviderFixture()
        provider.response = response(sourceClass: "ChannelModTerrainInputParentVC")
        let session = makeSession(provider: provider)

        await session.setChecked(nodeID: nodeID, sourceClass: "ChannelModTerrainInputParentVC",
            terrainPath: terrainPath, isChecked: true)

        #expect(session.isChecked(nodeID))
        #expect(session.features.count == 1)
        #expect(session.features.first?.inputNodeID == nodeID)
        #expect(session.features.first?.inputIndex == 0)
        #expect(session.features.first?.terrainRevision == String(repeating: "A", count: 64))
        #expect(provider.requests.first?.expectedTerrainPath == SourceFilePaths.canonical(URL(fileURLWithPath: terrainPath)))
    }

    @Test
    func uncheckingCancelsAndRejectsLateReplyWhenSourceReadIsGated() async {
        let provider = TerrainInputMapProviderFixture()
        let sourceReadPermission = TerrainInputSourceReadPermission()
        let session = makeSession(provider: provider, canReadSource: { sourceReadPermission.isAllowed })
        let checkTask = Task {
            await session.setChecked(nodeID: nodeID, sourceClass: "ChannelModTerrainInputParentVC",
                terrainPath: terrainPath, isChecked: true)
        }
        for _ in 0..<16 where provider.requests.isEmpty { await Task.yield() }
        #expect(provider.requests.count == 1)
        sourceReadPermission.isAllowed = false
        await session.setChecked(nodeID: nodeID, sourceClass: "ChannelModTerrainInputParentVC",
            terrainPath: terrainPath, isChecked: false)
        provider.complete(response(sourceClass: "ChannelModTerrainInputParentVC"))
        await checkTask.value

        #expect(!session.isChecked(nodeID))
        #expect(session.features.isEmpty)
        #expect(!session.loadingNodeIDs.contains(nodeID))
    }

    @Test
    func changingMapContextClearsAndRejectsLateReply() async {
        let provider = TerrainInputMapProviderFixture()
        let session = makeSession(provider: provider)
        let checkTask = Task {
            await session.setChecked(nodeID: nodeID, sourceClass: "ChannelModTerrainInputParentVC",
                terrainPath: terrainPath, isChecked: true)
        }
        for _ in 0..<16 where provider.requests.isEmpty { await Task.yield() }
        #expect(provider.requests.count == 1)

        session.configure(mapRequest: mapRequest(id: UUID()), resultSelectionOverrides: [],
            projectSessionID: UUID(), mapWorkflowIdentity: "replacement-map-context",
            provider: provider, isCurrent: { true }, canReadSource: { true })
        provider.complete(response(sourceClass: "ChannelModTerrainInputParentVC"))
        await checkTask.value

        #expect(!session.isChecked(nodeID))
        #expect(session.features.isEmpty)
        #expect(session.loadingNodeIDs.isEmpty)
    }

    private func makeSession(provider: TerrainInputMapProviderFixture,
                             canReadSource: @escaping @MainActor () -> Bool = { true }) -> TerrainInputMapSession {
        let session = TerrainInputMapSession()
        let map = mapRequest(id: UUID())
        session.configure(mapRequest: map, resultSelectionOverrides: [], projectSessionID: UUID(),
            mapWorkflowIdentity: "map-context-v1", provider: provider, isCurrent: { true }, canReadSource: canReadSource)
        return session
    }

    private func mapRequest(id: UUID) -> MapResultChartMapRequest {
        MapResultChartMapRequest(projectPath: "/tmp/project.ras", projectXml: "<Project />",
            projectXmlSHA: String(repeating: "B", count: 64), mapID: id.uuidString,
            mapIndex: 0, mapName: "Map", mapType: "Project",
            expectedVisualizationRevision: String(repeating: "C", count: 64))
    }

    private func response(sourceClass: String) -> TerrainInputMapContextData {
        TerrainInputMapContextData(inputNodeID: nodeID, inputIndex: 0, terrainPath: terrainPath,
            terrainRevision: String(repeating: "A", count: 64), sourceClass: sourceClass,
            features: [TerrainInputMapContextFeature(id: nodeID + ":feature:0", kind: "line",
                points: [.init(x: 1, y: 2), .init(x: 4, y: 5)], closed: false)])
    }
}
