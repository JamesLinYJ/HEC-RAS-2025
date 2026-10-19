import CryptoKit
import Foundation
import Testing
import RASWorkspaceCore
@testable import HECRAS2025

struct BackendMapLayerActionWorkflowTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil))
    @MainActor
    func geoJSONMapLayerActionsUseExactPersistedMapAndSourceFileRevisions() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("map-layer-actions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let projectURL = directory.appendingPathComponent("Map Actions.ras")
        let visualizationURL = directory.appendingPathComponent("Map Actions.vis")
        let project = try ProjectDocument(name: "Map Actions", units: "SI")
        try project.save(to: projectURL)
        let originalProject = try Data(contentsOf: projectURL)
        project.description = "Unpublished map action draft"

        let vectorDirectory = directory.appendingPathComponent("Map Data", isDirectory: true)
        try FileManager.default.createDirectory(at: vectorDirectory, withIntermediateDirectories: true)
        let vectorURL = vectorDirectory.appendingPathComponent("Channel.geojson")
        let sourceBytes = Data(#"{"type":"FeatureCollection","features":[{"type":"Feature","properties":{"name":"channel"},"geometry":{"type":"LineString","coordinates":[[0,0],[1,1]]}}]}"#.utf8)
        try sourceBytes.write(to: vectorURL)
        let sourcePath = SourceFilePaths.canonical(vectorURL)
        let sourceRevision = digest(sourceBytes)

        let client = BackendProcessClient(executableURL: URL(fileURLWithPath: executable))
        let sessionID = UUID()
        var maps: [CatalogMapDocument] = []
        var visualizationRevision: String?
        var mutationRunning = false
        let provider = BackendMapTreeProvider(
            client: client,
            projectXML: { project.editorXML },
            mapDocuments: { maps },
            isContextCurrent: { context in
                context.projectSessionID == sessionID && context.projectURL == projectURL
            },
            visualizationRevision: { visualizationRevision },
            beginMapMutation: {
                guard !mutationRunning else { return false }
                mutationRunning = true
                return true
            },
            endMapMutation: { mutationRunning = false },
            acceptMapChange: { previous, current in
                guard previous == visualizationRevision else {
                    throw BackendServiceError(code: "sourceChanged", message: "The visualization revision changed during the test.")
                }
                visualizationRevision = current
                maps = maps.map { map in
                    var updated = map
                    updated.visualizationRevision = current
                    return updated
                }
            })

        let projectReceipt = try await provider.createMap(projectPath: projectURL.path, kind: "Project")
        maps.append(mapDocument(projectReceipt, id: UUID()))
        let buildableReceipt = try await provider.createMap(projectPath: projectURL.path, kind: "Buildable")
        let buildableID = UUID()
        maps.append(mapDocument(buildableReceipt, id: buildableID))

        let buildableMap = try #require(maps.first { $0.id == buildableID.uuidString })
        let buildableContext = try context(for: buildableMap, maps: maps, project: project, projectURL: projectURL,
            sessionID: sessionID)
        let initialBuildable = try await provider.load(buildableContext)
        #expect(initialBuildable.roots.map(\.name) == ["Layers"])

        let addedBuildable = try await provider.addGeoJSONVector(sourcePath: sourcePath,
            revision: sourceRevision, context: buildableContext)
        let buildableLayer = try #require(findNode(in: addedBuildable.roots) {
            $0.sourceClass == "PolylineMapLayerVisualContext" && $0.name == "Channel"
        })
        #expect({ if case .checked? = buildableLayer.checked { true } else { false } }())
        #expect(buildableLayer.assetID.map { SourceFilePaths.canonical(URL(fileURLWithPath: $0)) } == sourcePath)
        #expect(buildableLayer.sourceLocator?.mapType == "PolylinesVector")

        let hidden = try await provider.perform(.visibility(id: buildableLayer.id, checked: false),
            context: context(for: try #require(maps.first { $0.id == buildableID.uuidString }), maps: maps,
                project: project, projectURL: projectURL, sessionID: sessionID))
        #expect(hidden.hiddenLayerIDs?.map { SourceFilePaths.canonical(URL(fileURLWithPath: $0)) }.contains(sourcePath) == true
            && hidden.hiddenLayerIDs?.count == 1)

        let projectMap = try #require(maps.first { $0.kind == "Project" })
        let projectSnapshot = try await provider.addGeoJSONVector(sourcePath: sourcePath,
            revision: sourceRevision,
            context: context(for: projectMap, maps: maps, project: project, projectURL: projectURL,
                sessionID: sessionID))
        #expect(findNode(in: projectSnapshot.roots) {
            $0.sourceClass == "PolylineMapLayerVisualContext" && $0.name == "Channel"
        } != nil)

        // An inspected SHA remains the authorization boundary. A changed source
        // file cannot be removed with the revision shown when the node loaded.
        var changedSource = sourceBytes
        changedSource.append(contentsOf: Data("\n".utf8))
        try changedSource.write(to: vectorURL)
        let beforeStaleRemove = try Data(contentsOf: visualizationURL)
        let staleError = await errorCode {
            _ = try await provider.removeSourceNode(nodeID: buildableLayer.id, sourcePath: sourcePath,
                revision: sourceRevision,
                context: context(for: try #require(maps.first { $0.id == buildableID.uuidString }), maps: maps,
                    project: project, projectURL: projectURL, sessionID: sessionID))
        }
        #expect(staleError == "sourceChanged")
        #expect(try Data(contentsOf: visualizationURL) == beforeStaleRemove)

        let changedRevision = digest(changedSource)
        let removedBuildable = try await provider.removeSourceNode(nodeID: buildableLayer.id,
            sourcePath: sourcePath, revision: changedRevision,
            context: context(for: try #require(maps.first { $0.id == buildableID.uuidString }), maps: maps,
                project: project, projectURL: projectURL, sessionID: sessionID))
        #expect(findNode(in: removedBuildable.roots) {
            $0.sourceClass == "PolylineMapLayerVisualContext"
        } == nil)

        let buildableReadback = try await provider.load(context(for:
            try #require(maps.first { $0.id == buildableID.uuidString }), maps: maps, project: project,
            projectURL: projectURL, sessionID: sessionID))
        #expect(findNode(in: buildableReadback.roots) {
            $0.sourceClass == "PolylineMapLayerVisualContext"
        } == nil)
        let projectReadback = try await provider.load(context(for:
            try #require(maps.first { $0.kind == "Project" }), maps: maps, project: project,
            projectURL: projectURL, sessionID: sessionID))
        #expect(findNode(in: projectReadback.roots) {
            $0.sourceClass == "PolylineMapLayerVisualContext"
                && $0.assetID.map { SourceFilePaths.canonical(URL(fileURLWithPath: $0)) } == sourcePath
        } != nil)
        #expect(try Data(contentsOf: projectURL) == originalProject)
        #expect(project.description == "Unpublished map action draft")
        #expect(!mutationRunning)
    }

    private func mapDocument(_ receipt: MapDocumentMutationReceipt, id: UUID) -> CatalogMapDocument {
        CatalogMapDocument(id: id.uuidString, name: receipt.mapName, kind: receipt.mapType,
            sourceIndex: receipt.mapIndex, visualizationRevision: receipt.visualizationRevision)
    }

    private func context(for map: CatalogMapDocument, maps: [CatalogMapDocument], project: ProjectDocument,
                         projectURL: URL, sessionID: UUID) throws -> LayerTreeContext {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let mapsJSON = String(decoding: try encoder.encode(maps), as: UTF8.self)
        return LayerTreeContext(projectSessionID: sessionID, projectURL: projectURL,
            mapID: try #require(UUID(uuidString: map.id)), mode: "Project", focusedGeometryIDs: [],
            focusedPlanIDs: [], projectRevision: project.editorXML + "\n" + mapsJSON)
    }

    private func findNode(in roots: [LayerTreeNode], where predicate: (LayerTreeNode) -> Bool) -> LayerTreeNode? {
        for root in roots {
            if predicate(root) { return root }
            if let found = root.children.flatMap({ findNode(in: $0, where: predicate) }) { return found }
        }
        return nil
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }

    @MainActor
    private func errorCode(_ operation: @MainActor () async throws -> Void) async -> String? {
        do { try await operation(); return nil }
        catch let error as BackendServiceError { return error.code }
        catch { return "unexpected" }
    }
}
