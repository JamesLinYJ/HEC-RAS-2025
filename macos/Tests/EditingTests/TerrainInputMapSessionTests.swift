import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class TerrainInputMapProviderFixture: TerrainInputMapContextProvider {
    private(set) var requests: [TerrainInputMapContextRequest] = []
    var response: TerrainInputMapContextData?
    private var continuations: [Int: CheckedContinuation<TerrainInputMapContextData, any Error>] = [:]

    func renderTerrainInput(_ request: TerrainInputMapContextRequest) async throws -> TerrainInputMapContextData {
        let requestIndex = requests.count
        requests.append(request)
        if let response { return response }
        return try await withCheckedThrowingContinuation { continuations[requestIndex] = $0 }
    }

    func complete(_ response: TerrainInputMapContextData) {
        guard let requestIndex = continuations.keys.min() else { return }
        complete(at: requestIndex, with: response)
    }

    func complete(at requestIndex: Int, with response: TerrainInputMapContextData) {
        continuations.removeValue(forKey: requestIndex)?.resume(returning: response)
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

    @Test
    func cameraChangeRetiresLeveeProfileRenderAndRejectsOldViewportPixels() async {
        let provider = TerrainInputMapProviderFixture()
        provider.response = response(sourceClass: "LeveeModTerrainInputVC")
        let session = makeSession(provider: provider)
        await session.setChecked(nodeID: nodeID, sourceClass: "LeveeModTerrainInputVC",
            terrainPath: terrainPath, isChecked: true)
        let firstViewport = viewport(minX: 0)
        let secondViewport = viewport(minX: 100)
        await session.updateRenderViewport(firstViewport)
        provider.response = nil

        let firstRender = Task { await session.setShowsProfileStations(true, nodeID: nodeID) }
        for _ in 0..<32 where provider.requests.count < 2 { await Task.yield() }
        #expect(provider.requests.count == 2)
        #expect(provider.requests[1].renderOptions?.viewport == firstViewport.extent)

        let cameraChange = Task { await session.updateRenderViewport(secondViewport) }
        for _ in 0..<32 where provider.requests.count < 3 { await Task.yield() }
        #expect(provider.requests.count == 3)
        #expect(provider.requests[2].renderOptions?.viewport == secondViewport.extent)

        provider.complete(at: 2, with: leveeRenderResponse(for: provider.requests[2]))
        await cameraChange.value
        provider.complete(at: 1, with: leveeRenderResponse(for: provider.requests[1]))
        await firstRender.value

        #expect(session.leveeRenderersByNodeID[nodeID]?.data.viewport == secondViewport.extent)
        #expect(session.visibleRasterOverlays.count == 1)
        #expect(session.visibleRasterOverlays[0].frame.viewport == secondViewport.extent)
        #expect(session.leveeRenderersByNodeID[nodeID]?.profileStationsImage != nil)
        #expect(!session.loadingNodeIDs.contains(nodeID))
    }

    @Test
    func changingLeveeTinPlotOptionsCancelsPreviousRenderAndInstallsOnlyLatestSourcePixels() async {
        let provider = TerrainInputMapProviderFixture()
        provider.response = response(sourceClass: "LeveeModTerrainInputVC")
        let session = makeSession(provider: provider)
        await session.setChecked(nodeID: nodeID, sourceClass: "LeveeModTerrainInputVC",
            terrainPath: terrainPath, isChecked: true)
        let camera = viewport(minX: 5)
        await session.updateRenderViewport(camera)
        provider.response = nil

        let firstRender = Task { await session.setShowsTin(true, nodeID: nodeID, debugMode: true) }
        for _ in 0..<32 where provider.requests.count < 2 { await Task.yield() }
        #expect(provider.requests.count == 2)
        #expect(provider.requests[1].renderOptions?.tinOptions == .sourceDefault)

        var latestOptions = TerrainInputMapTinRenderOptions.sourceDefault
        latestOptions.surfaceFillMode = .z
        latestOptions.renderPoints = false
        let optionsChange = Task { await session.setTinOptions(latestOptions, nodeID: nodeID) }
        for _ in 0..<32 where provider.requests.count < 3 { await Task.yield() }
        #expect(provider.requests.count == 3)
        #expect(provider.requests[2].renderOptions?.tinOptions == latestOptions)

        provider.complete(at: 2, with: leveeRenderResponse(for: provider.requests[2]))
        await optionsChange.value
        provider.complete(at: 1, with: leveeRenderResponse(for: provider.requests[1]))
        await firstRender.value

        let installed = session.leveeRenderersByNodeID[nodeID]
        #expect(installed != nil)
        #expect(installed?.data.tin?.viewport == camera.extent)
        #expect(installed?.tinImage != nil)
        let options = Dictionary(uniqueKeysWithValues:
            (installed?.data.tinPlotOptions ?? []).map { ($0.propertyName, $0.value) })
        #expect(options["PaintZ"] == "true")
        #expect(options["PaintM"] == "false")
        #expect(options["RenderPoints"] == "false")
        #expect(session.tinOptions(nodeID) == latestOptions)
        #expect(!session.loadingNodeIDs.contains(nodeID))
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

    private func viewport(minX: Double) -> MapSourceRenderViewport {
        MapSourceRenderViewport(extent: RasterMapViewExtent(minX: minX, minY: 0,
            maxX: minX + 10, maxY: 10, pixelWidth: 32, pixelHeight: 24), renderScale: 0.75)
    }

    private func leveeRenderResponse(for request: TerrainInputMapContextRequest) -> TerrainInputMapContextData {
        let options = request.renderOptions!
        let renderer = TerrainInputMapLeveeRendererData(viewport: options.viewport,
            profileStations: options.showProfileStations ? frame(options.viewport) : nil,
            tin: options.showTin ? frame(options.viewport) : nil,
            tinFeatureCount: options.showTin ? 1 : 0, tinWarning: nil,
            tinPlotOptions: options.showTin ? tinDescriptors(options.tinOptions ?? .sourceDefault) : [])
        let base = response(sourceClass: "LeveeModTerrainInputVC")
        return TerrainInputMapContextData(inputNodeID: base.inputNodeID, inputIndex: base.inputIndex,
            terrainPath: base.terrainPath, terrainRevision: base.terrainRevision,
            sourceClass: base.sourceClass, features: base.features, leveeRenderer: renderer)
    }

    private func frame(_ viewport: RasterMapViewExtent) -> MapSourceRasterFrame {
        MapSourceRasterFrame(viewport: viewport, width: viewport.pixelWidth, height: viewport.pixelHeight,
            rgba: Data(repeating: 255, count: viewport.pixelWidth * viewport.pixelHeight * 4),
            minX: viewport.minX, minY: viewport.minY, maxX: viewport.maxX, maxY: viewport.maxY,
            labels: [])
    }

    private func tinDescriptors(_ options: TerrainInputMapTinRenderOptions) -> [TerrainInputMapTinPlotOptionDescriptor] {
        [
            .init(propertyName: "PaintZ", name: "PaintZ", label: "Paint Z Surface", description: "",
                value: options.surfaceFillMode == .z ? "true" : "false", isEnabled: true, hasDrawingImplementation: true),
            .init(propertyName: "PaintM", name: "PaintM", label: "Paint M Surface", description: "",
                value: options.surfaceFillMode == .m ? "true" : "false", isEnabled: true, hasDrawingImplementation: true),
            .init(propertyName: "RenderEdges", name: "RenderEdges", label: "Render TIN Edges", description: "",
                value: options.renderEdges ? "true" : "false", isEnabled: true, hasDrawingImplementation: true),
            .init(propertyName: "RenderPoints", name: "RenderPoints", label: "Render Points", description: "",
                value: options.renderPoints ? "true" : "false", isEnabled: true, hasDrawingImplementation: true),
            .init(propertyName: "RenderDeletedTris", name: "RenderDeletedTris", label: "Render Deleted Triangles", description: "",
                value: options.renderDeletedTriangles ? "true" : "false", isEnabled: true, hasDrawingImplementation: true),
            .init(propertyName: "LabelTris", name: "LabelTriangles", label: "Label Triangles", description: "",
                value: options.labelTriangles ? "true" : "false", isEnabled: true, hasDrawingImplementation: true),
            .init(propertyName: "LabelEdges", name: "LabelEdges", label: "Label Edges", description: "",
                value: "false", isEnabled: false, hasDrawingImplementation: false),
            .init(propertyName: "LabelPoints", name: "LabelPoints", label: "Label Points", description: "",
                value: "false", isEnabled: false, hasDrawingImplementation: false)
        ]
    }
}
