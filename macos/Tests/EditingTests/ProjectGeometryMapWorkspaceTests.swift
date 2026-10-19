import CryptoKit
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct ProjectGeometryMapWorkspaceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_GEOMETRY_MAP_ACCEPTANCE_DIRECTORY"] != nil
        && ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil)) @MainActor
    func exactGeometryStyleOwnerIsIndependentAcrossMapsAndLeavesSourceFilesUntouched() async throws {
        let fixture = try GeometryMapWorkspaceFixture()
        defer { fixture.cleanup() }
        try fixture.addSecondMapClonedFrom(name: "Map A", cloneName: "Map A style copy")

        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let preferencesSuite = "HECRAS2025.GeometryMapStyles.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: preferencesSuite))
        defaults.removePersistentDomain(forName: preferencesSuite)
        defer { defaults.removePersistentDomain(forName: preferencesSuite) }
        let store = WorkspaceStore(
            system: SourceWorkflowFixtureServices(recoveryFolder: fixture.root.appendingPathComponent("Recovery")),
            modelProvider: BackendModelProvider(client: BackendProcessClient(executableURL: URL(fileURLWithPath: executable))),
            globalVectorStylePreferences: GlobalVectorStylePreferences(defaults: defaults))
        store.requestOpen(fixture.projectURL)
        try await waitForProjectOpen(store)

        let firstMapID = try #require(store.catalogMapDocuments.first {
            $0.name == "Map A" && $0.kind == "Project"
        }.flatMap { UUID(uuidString: $0.id) })
        let secondMapID = try #require(store.catalogMapDocuments.first {
            $0.name == "Map A style copy" && $0.kind == "Project"
        }.flatMap { UUID(uuidString: $0.id) })
        #expect(firstMapID != secondMapID)

        // Loading each saved map tree establishes both exact .vis owners without
        // borrowing the last-active map's style or opening an editor preview.
        await store.refreshVectorSymbologyContexts(mapID: firstMapID)
        await store.refreshVectorSymbologyContexts(mapID: secondMapID)
        let firstContext = try #require(store.vectorSymbologyContexts(mapID: firstMapID).first {
            $0.specializedNode?.nodeType == "FlowAreaLayer"
                && $0.specializedNode?.geometryName == "Map geometry A"
        })
        let secondContext = try #require(store.vectorSymbologyContexts(mapID: secondMapID).first {
            $0.specializedNode?.nodeType == "FlowAreaLayer"
                && $0.specializedNode?.geometryName == "Map geometry A"
        })
        #expect(firstContext.specializedNode?.geometryAssetID == secondContext.specializedNode?.geometryAssetID)
        #expect(firstContext.specializedNode?.nodePath == secondContext.specializedNode?.nodePath)
        #expect(firstContext.specializedNode?.mapIndex != secondContext.specializedNode?.mapIndex)

        let provider = try #require(store.vectorSymbologyProvider)
        let firstBefore = try #require(try await provider.snapshot(firstContext))
        let secondBefore = try #require(try await provider.snapshot(secondContext))
        let firstMesh = try #require(firstBefore.options.firstIndex { $0.id == "Mesh_Line_Symbology" })
        let secondMesh = try #require(secondBefore.options.first { $0.id == "Mesh_Line_Symbology" })
        let projectBytes = try Data(contentsOf: fixture.projectURL)
        let geometryHashes = try fixture.geometryHashes()
        let visualizationBefore = try Data(contentsOf: fixture.visualizationURL)

        var edited = firstBefore.options
        let changedColor = edited[firstMesh].style.penColor == "#FF13579B" ? "#FF2468AC" : "#FF13579B"
        edited[firstMesh].style.penColor = changedColor
        let update = try await provider.apply(options: edited,
            additionalOptions: firstBefore.additionalOptions, context: firstContext)
        store.installMapUpdate(update, mapID: firstMapID)
        #expect(try Data(contentsOf: fixture.visualizationURL) != visualizationBefore)
        #expect(try Data(contentsOf: fixture.projectURL) == projectBytes)
        #expect(try fixture.geometryHashes() == geometryHashes)

        // The saved .vis revision invalidates both old contexts. Refreshing
        // each map must reload its own node path: only Map A changed.
        await store.refreshVectorSymbologyContexts(mapID: firstMapID)
        await store.refreshVectorSymbologyContexts(mapID: secondMapID)
        let refreshedFirst = try #require(store.vectorSymbologyContexts(mapID: firstMapID).first {
            $0.specializedNode == firstContext.specializedNode
        })
        let refreshedSecond = try #require(store.vectorSymbologyContexts(mapID: secondMapID).first {
            $0.specializedNode == secondContext.specializedNode
        })
        let firstAfter = try #require(try await provider.snapshot(refreshedFirst))
        let secondAfter = try #require(try await provider.snapshot(refreshedSecond))
        let firstColor = try #require(firstAfter.options.first { $0.id == "Mesh_Line_Symbology" }).style.penColor
        let secondColor = try #require(secondAfter.options.first { $0.id == "Mesh_Line_Symbology" }).style.penColor
        #expect(firstColor == changedColor)
        #expect(secondColor == secondMesh.style.penColor)

        // Resolve the map canvas style through the exact Geometry child
        // returned by each live backend map tree. This verifies the renderer
        // does not read a global or last-active-map style as a substitute.
        let client = BackendProcessClient(executableURL: URL(fileURLWithPath: executable))
        let firstCapture = try await geometryCapture(store: store, mapID: firstMapID)
        let firstWorkflow = store.mapWorkflowIdentity(firstMapID)
        let firstGeometryProvider = BackendProjectGeometryMapProvider(client: client,
            isCurrent: { store.mapWorkflowIdentity(firstMapID) == firstWorkflow })
        let firstSnapshot = try await firstGeometryProvider.load(
            MapGeometryRequest(map: firstCapture.map, geometryNode: firstCapture.geometryNode,
                viewport: nil, contextToken: nil), capture: firstCapture)
        var firstSource = ProjectGeometryMapSourceState(capture: firstCapture)
        firstSource.snapshot = firstSnapshot
        firstSource.topologyExtent = firstSnapshot.topology?.sourceExtent
        firstSource.flowAreasExtent = firstSnapshot.flowAreas?.sourceExtent
        firstSource.culvertsExtent = firstSnapshot.culverts?.sourceExtent
        let sourceFitPoints = firstSource.visiblePoints
        #expect(sourceFitPoints.count >= 2)
        #expect(sourceFitPoints.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        let renderedFirst = ProjectGeometryMapStyleResolver.values(for: firstSource,
            state: firstSnapshot.flowAreasState, nodeType: "FlowAreaLayer",
            ids: ["Mesh_Line_Symbology"], store: store, mapID: firstMapID)

        let secondCapture = try await geometryCapture(store: store, mapID: secondMapID)
        let secondWorkflow = store.mapWorkflowIdentity(secondMapID)
        let secondGeometryProvider = BackendProjectGeometryMapProvider(client: client,
            isCurrent: { store.mapWorkflowIdentity(secondMapID) == secondWorkflow })
        let secondSnapshot = try await secondGeometryProvider.load(
            MapGeometryRequest(map: secondCapture.map, geometryNode: secondCapture.geometryNode,
                viewport: nil, contextToken: nil), capture: secondCapture)
        var secondSource = ProjectGeometryMapSourceState(capture: secondCapture)
        secondSource.snapshot = secondSnapshot
        let renderedSecond = ProjectGeometryMapStyleResolver.values(for: secondSource,
            state: secondSnapshot.flowAreasState, nodeType: "FlowAreaLayer",
            ids: ["Mesh_Line_Symbology"], store: store, mapID: secondMapID)
        #expect(renderedFirst?["Mesh_Line_Symbology"]?.penColor == changedColor)
        #expect(renderedSecond?["Mesh_Line_Symbology"]?.penColor == secondMesh.style.penColor)
    }

    @MainActor
    private func waitForProjectOpen(_ store: WorkspaceStore) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while (store.document == nil || store.isOpeningProject || store.isMapLoading) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!store.isOpeningProject)
        #expect(store.document != nil)
    }

    @MainActor
    private func geometryCapture(store: WorkspaceStore, mapID: UUID) async throws
        -> ProjectGeometryMapCapture {
        let map = try #require(store.mapIdentityRequest(for: mapID))
        let rows = try await store.sourceMapLayerNodes(mapID)
        let geometry = try #require(rows.first {
            $0.sourceLocator?.nodeType == "Geometry" && $0.name == "Map geometry A"
        })
        let locator = try #require(geometry.sourceLocator)
        let path = try #require(geometry.assetID ?? locator.assetID)
        return try ProjectGeometryMapCapture(
            projectSessionID: store.projectSessionID,
            mapID: mapID,
            mapWorkflowIdentity: store.mapWorkflowIdentity(mapID),
            map: map,
            geometryNode: locator,
            geometryAssetPath: path,
            geometryName: geometry.name)
    }
}

private struct GeometryMapWorkspaceFixture {
    let original: URL
    let root: URL
    let projectURL: URL
    var visualizationURL: URL { projectURL.deletingPathExtension().appendingPathExtension("vis") }

    init() throws {
        original = URL(fileURLWithPath: try #require(
            ProcessInfo.processInfo.environment["HECRAS_GEOMETRY_MAP_ACCEPTANCE_DIRECTORY"]), isDirectory: true)
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "geometry-map-workspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: original, to: root)
        projectURL = root.appendingPathComponent("Geometry project map.ras")
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func addSecondMapClonedFrom(name sourceName: String, cloneName: String) throws {
        let xml = try XMLDocument(data: Data(contentsOf: visualizationURL),
            options: [.nodePreserveAll, .nodeLoadExternalEntitiesNever])
        guard let rootNode = xml.rootElement(),
              let maps = rootNode.elements(forName: "Maps").first,
              let source = maps.elements(forName: "Map").first(where: {
                  $0.attribute(forName: "Name")?.stringValue == sourceName
                      && $0.attribute(forName: "Type")?.stringValue == "Project"
              }),
              let duplicate = source.copy() as? XMLElement,
              let name = duplicate.attribute(forName: "Name") else {
            throw GeometryMapWorkspaceFixtureError.invalidVisualization
        }
        name.stringValue = cloneName
        maps.addChild(duplicate)
        try xml.xmlData(options: [.nodePreserveAll]).write(to: visualizationURL, options: .atomic)
    }

    func geometryHashes() throws -> [String: String] {
        let enumerator = try #require(FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey]))
        var result: [String: String] = [:]
        for case let url as URL in enumerator
        where ["h5", "hdf"].contains(url.pathExtension.lowercased()) {
            result[String(url.path.dropFirst(root.path.count + 1))] = Self.sha(try Data(contentsOf: url))
        }
        return result
    }

    private static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }
}

private enum GeometryMapWorkspaceFixtureError: Error {
    case invalidVisualization
}
