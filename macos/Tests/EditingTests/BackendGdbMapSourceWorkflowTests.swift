import CryptoKit
import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct BackendGdbMapSourceWorkflowTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_GDB_SOURCE_ACCEPTANCE_DIRECTORY"] != nil
        && ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil))
    @MainActor
    func bundledBackendImportsAndLoadsExactGdbLeafFromPrivateFixtureCopy() async throws {
        let environment = ProcessInfo.processInfo.environment
        let fixtureRoot = URL(fileURLWithPath:
            try #require(environment["HECRAS_GDB_SOURCE_ACCEPTANCE_DIRECTORY"]), isDirectory: true)
            .standardizedFileURL
        let executable = URL(fileURLWithPath:
            try #require(environment["HECRAS_BACKEND_TEST_EXECUTABLE"]))
        let manifest = try JSONDecoder().decode(GdbSourceAcceptanceManifest.self,
            from: Data(contentsOf: fixtureRoot.appendingPathComponent("acceptance.json")))
        #expect(manifest.schema == "hecras.gdb-map-source-acceptance.v1")
        #expect(manifest.sourceLayerName == "Route_XYZM")
        #expect(manifest.displayLayerName == "Visible route label")
        #expect(manifest.vectorType == "LineCollection" && manifest.featureCount == 1)
        #expect(manifest.expectedRasterSubdatasetCount == 0)

        let originalSnapshot = try fileSnapshot(fixtureRoot)
        let workingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("gdb-map-source-workflow-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workingRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workingRoot) }

        let projectURL = workingRoot.appendingPathComponent(manifest.projectPath)
        let visualizationURL = workingRoot.appendingPathComponent(manifest.visualizationPath)
        let sourceURL = workingRoot.appendingPathComponent(manifest.sourceDirectory, isDirectory: true)
        try FileManager.default.copyItem(at: fixtureRoot.appendingPathComponent(manifest.projectPath), to: projectURL)
        try FileManager.default.copyItem(at: fixtureRoot.appendingPathComponent(manifest.visualizationPath), to: visualizationURL)
        try FileManager.default.copyItem(at: fixtureRoot.appendingPathComponent(manifest.sourceDirectory), to: sourceURL)
        // The acceptance exporter copied the GDB but kept the temporary source
        // path in .vis. Rebind only this private work copy to the matching GDB.
        try rebindGdbSourceReferences(in: visualizationURL, projectURL: projectURL,
            sourceURL: sourceURL, expectedSourceDirectory: manifest.sourceDirectory)
        let sourceBytesBefore = try fileSnapshot(sourceURL)
        let projectBytesBefore = try Data(contentsOf: projectURL)
        let initialVisualizationRevision = try digest(Data(contentsOf: visualizationURL))

        let client = BackendProcessClient(executableURL: executable)
        let store = WorkspaceStore(
            system: SourceWorkflowFixtureServices(recoveryFolder: workingRoot.appendingPathComponent("Recovery")),
            modelProvider: BackendModelProvider(client: client))
        defer {
            store.requestClose()
            if store.showDiscardConfirmation { store.discardAndContinue() }
        }
        store.requestOpen(projectURL)
        func matchingPersistedMap() -> CatalogMapDocument? {
            let matches = store.catalogMapDocuments.filter {
                $0.sourceIndex == manifest.mapIndex && $0.name == manifest.mapName
                    && $0.kind == manifest.mapType
            }
            return matches.count == 1 ? matches[0] : nil
        }
        // The manifest's map ID belongs to the export-time Host request; .vis
        // persists the map by its index/name/type, and the Store assigns the
        // session's native map ID when it reopens that persisted map.
        try await waitUntil(stage: "the project catalog to expose the persisted GDB map") {
            store.hasProject && !store.isOpeningProject && !store.isMapLoading
                && matchingPersistedMap() != nil
        }
        let persistedMap = try #require(matchingPersistedMap())
        let mapID = try #require(UUID(uuidString: persistedMap.id))
        _ = store.mapState(for: mapID)
        await store.configureMapResultSources(mapID)

        // Capture the copied directory through the real bundled Host. Its
        // source revision includes the new canonical path, so it is deliberately
        // recaptured instead of reusing the exporter-side receipt.
        let gdbProvider = BackendGdbMapSourceProvider(client: client)
        let sourcePath = SourceFilePaths.canonical(sourceURL)
        let catalog = try await gdbProvider.catalog(sourcePath: sourcePath, expectedSourceRevision: nil)
        try catalog.source.validate(expectedPath: sourceURL)
        #expect(catalog.source.revision.caseInsensitiveCompare(manifest.sourceRevision) != .orderedSame)
        #expect(catalog.layers.count == 1)
        let descriptor = try #require(catalog.layers.first)
        #expect(descriptor.name == manifest.sourceLayerName)
        #expect(descriptor.vectorType == manifest.vectorType)
        #expect(descriptor.featureCount == manifest.featureCount)
        #expect(catalog.rasterSubdatasets.count == manifest.expectedRasterSubdatasetCount)
        #expect(catalog.source.files.map(\.relativePath) == manifest.sourceFiles.map(\.relativePath))
        #expect(catalog.source.files.map(\.length) == manifest.sourceFiles.map(\.length))
        #expect(catalog.source.files.map(\.revision) == manifest.sourceFiles.map(\.revision))

        let mapTreeProvider = try #require(store.layerTreeProvider as? BackendMapTreeProvider)
        let initialContext = store.sourceMapTreeContext(mapID)
        let initialTree = try await mapTreeProvider.load(initialContext)
        let persistedLeaf = try #require(findNode(initialTree.roots) { node in
            node.sourceLocator?.nodeType == "GdbVectorLayer"
                && node.properties.first(where: { $0.id == "Source/GdbLayerName" })?.value == manifest.sourceLayerName
                && node.name == manifest.displayLayerName
        })
        let persistedDataset = try #require(findNode(initialTree.roots) { node in
            node.sourceLocator?.nodeType == "GdbDataset"
                && node.assetID.map {
                    SourceFilePaths.canonical(URL(fileURLWithPath: $0)) == sourcePath
                } == true
        })
        let initialMapIdentity = try #require(store.mapIdentityRequest(for: mapID))
        let persistedLocator = try #require(persistedLeaf.sourceLocator)
        let directResponse = try await gdbProvider.load(.init(map: initialMapIdentity,
            node: persistedLocator, expectedSourceRevision: catalog.source.revision))
        let directLayer = try GdbMapSourceConverter.makeLayer(response: directResponse,
            expectedMap: initialMapIdentity, expectedNode: persistedLocator,
            expectedNodeID: persistedLeaf.id, expectedSource: catalog.source,
            expectedLayerName: manifest.sourceLayerName, expectedLayer: descriptor, mapID: mapID)
        #expect(directLayer.features.count == 1)
        #expect(directLayer.features.first?.sourceCoordinatePaths?.first?.first?.z == 12.5)
        #expect(directLayer.features.first?.sourceCoordinatePaths?.first?.first?.m == 100.25)

        // Exercise a second real .vis transaction so the native import session
        // adds the source instead of merely reopening the exporter's row.
        let removedTree = try await mapTreeProvider.removeSourceNode(nodeID: persistedDataset.id,
            sourcePath: sourcePath, revision: catalog.source.revision, context: initialContext)
        #expect(findNode(removedTree.roots) { $0.sourceLocator?.nodeType == "GdbDataset" } == nil)
        let afterRemovalRevision = try digest(Data(contentsOf: visualizationURL))
        #expect(afterRemovalRevision != initialVisualizationRevision)

        #expect(await store.connectMapSource(sourceURL, for: mapID))
        let session = try #require(store.pendingGdbMapImport)
        #expect(session.isCurrent(in: store))
        await session.loadCatalog()
        #expect(session.catalog.count == 1)
        #expect(session.catalog.first?.name == manifest.sourceLayerName)
        #expect(session.catalog.first?.kind == "Vector")
        #expect(session.catalog.first?.canImport == true)
        #expect(await session.importSelected())

        let importedVisualizationRevision = try digest(Data(contentsOf: visualizationURL))
        #expect(importedVisualizationRevision != afterRemovalRevision)
        #expect(try Data(contentsOf: projectURL) == projectBytesBefore)
        #expect(try fileSnapshot(sourceURL) == sourceBytesBefore)

        let mapRows = try await store.sourceMapLayerNodes(mapID)
        let importedLeaf = try #require(mapRows.first { node in
            node.sourceLocator?.nodeType == "GdbVectorLayer"
                && node.sourceLocator?.mapType == "GdbVectorLayer"
                && node.properties.first(where: { $0.id == "Source/GdbLayerName" })?.value == manifest.sourceLayerName
                && node.name == manifest.sourceLayerName
        })
        #expect(importedLeaf.assetID.map {
            SourceFilePaths.canonical(URL(fileURLWithPath: $0)) == sourcePath
        } == true)

        let readRequests = store.sourceMapVectorReadRequests(mapRows, mapID: mapID)
        #expect(readRequests.files.isEmpty)
        #expect(readRequests.gdbLayers.count == 1)
        #expect(readRequests.gdbLayers.first?.layerName == manifest.sourceLayerName)
        await store.refreshSourceMapVectors(mapRows, mapID: mapID)
        try await waitUntil(stage: "the imported GDB vector to finish loading") {
            store.sourceMapVectorLoadStates[mapID]?.phase == .completed
                && store.mapState(for: mapID).vectors(store.mapLayers).contains {
                    $0.id == store.sourceVectorInstanceID(importedLeaf, mapID: mapID)
                }
        }

        let loadedLayer = try #require(store.mapState(for: mapID).vectors(store.mapLayers).first {
            $0.id == store.sourceVectorInstanceID(importedLeaf, mapID: mapID)
        })
        #expect(loadedLayer.sourceMapID == mapID)
        #expect(loadedLayer.sourceRevision == catalog.source.revision.uppercased())
        #expect(loadedLayer.visualName == manifest.sourceLayerName)
        #expect(loadedLayer.features.count == 1)
        let feature = try #require(loadedLayer.features.first)
        #expect(feature.sourceFeatureIndex == 0)
        let firstVertex = try #require(feature.sourceCoordinatePaths?.first?.first)
        #expect(firstVertex.x == 116 && firstVertex.y == 39)
        #expect(firstVertex.z == 12.5 && firstVertex.m == 100.25)

        let columns = try #require(feature.sourceAttributeColumns)
        let largeID = try #require(columns.first { $0.name == "LargeID" })
        #expect(largeID.sourceMetadata?.sourceType.caseInsensitiveCompare("Integer64") == .orderedSame)
        #expect(largeID.sourceMetadata?.rawLexeme == "9223372036854775000")
        let nullText = try #require(columns.first { $0.name == "NullText" })
        let unsetText = try #require(columns.first { $0.name == "UnsetText" })
        #expect(nullText.sourceMetadata?.isSet == true && nullText.sourceMetadata?.isNull == true)
        #expect(unsetText.sourceMetadata?.isSet == true && unsetText.sourceMetadata?.isNull == true)
        let enabled = try #require(columns.first { $0.name == "Enabled" })
        #expect(enabled.sourceMetadata?.sourceType == "Integer")
        #expect(enabled.sourceMetadata?.rawLexeme == "1" && enabled.sourceMetadata?.booleanValue == nil)

        // The exporter fixture is immutable; all .vis writes occurred in the
        // isolated work copy above.
        #expect(try fileSnapshot(fixtureRoot) == originalSnapshot)
    }

    @MainActor
    private func waitUntil(_ timeout: Duration = .seconds(30), stage: String,
                           _ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !predicate() {
            guard ContinuousClock.now < deadline else {
                throw NSError(domain: "HECRAS2025.BackendGdbMapSourceWorkflowTests", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for \(stage)."])
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private func rebindGdbSourceReferences(in visualizationURL: URL, projectURL: URL,
        sourceURL: URL, expectedSourceDirectory: String) throws {
        let document = try XMLDocument(data: Data(contentsOf: visualizationURL),
            options: [.nodePreserveAll, .nodeLoadExternalEntitiesNever])
        guard let root = document.rootElement() else { throw CocoaError(.fileReadCorruptFile) }
        let relativeSourcePath = Self.relativePath(from: projectURL.deletingLastPathComponent(), to: sourceURL)
        let canonicalSourcePath = SourceFilePaths.canonical(sourceURL)
        var datasetCount = 0
        var vectorLayerCount = 0

        func setAttribute(_ name: String, value: String, on element: XMLElement) {
            if let attribute = element.attribute(forName: name) { attribute.stringValue = value }
            else { element.addAttribute(XMLNode.attribute(withName: name, stringValue: value) as! XMLNode) }
        }

        func visit(_ element: XMLElement) {
            if element.name == "Node" {
                let type = element.attribute(forName: "Type")?.stringValue
                if type == "GdbDataset" || type == "GdbVectorLayer",
                   let filename = element.attribute(forName: "Filename")?.stringValue,
                   URL(fileURLWithPath: filename).lastPathComponent == expectedSourceDirectory {
                    setAttribute("Filename", value: canonicalSourcePath, on: element)
                    setAttribute("FilenameRelative", value: relativeSourcePath, on: element)
                    if type == "GdbDataset" { datasetCount += 1 }
                    else { vectorLayerCount += 1 }
                }
            }
            for child in element.children ?? [] {
                if let childElement = child as? XMLElement { visit(childElement) }
            }
        }

        visit(root)
        guard datasetCount == 1, vectorLayerCount == 1 else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey:
                "Expected one GDB dataset and one GDB vector layer in the acceptance visualization."])
        }
        try document.xmlData(options: [.nodePreserveAll]).write(to: visualizationURL, options: .atomic)
    }

    private static func relativePath(from baseDirectory: URL, to destination: URL) -> String {
        let base = baseDirectory.standardizedFileURL.pathComponents
        let target = destination.standardizedFileURL.pathComponents
        let commonCount = zip(base, target).prefix { $0.0 == $0.1 }.count
        return (Array(repeating: "..", count: base.count - commonCount)
            + Array(target.dropFirst(commonCount))).joined(separator: "/")
    }

    private func findNode(_ nodes: [LayerTreeNode], where predicate: (LayerTreeNode) -> Bool) -> LayerTreeNode? {
        for node in nodes {
            if predicate(node) { return node }
            if let match = findNode(node.children ?? [], where: predicate) { return match }
        }
        return nil
    }

    private func fileSnapshot(_ root: URL) throws -> [String: String] {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw CocoaError(.fileReadUnknown)
        }
        var snapshot: [String: String] = [:]
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if name.hasSuffix(".lock") || name.hasSuffix(".lck")
                || name.hasPrefix(".~lock.") { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            snapshot[relative] = try digest(Data(contentsOf: url))
        }
        return snapshot
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }
}

private struct GdbSourceAcceptanceManifest: Decodable {
    struct SourceFile: Decodable {
        let relativePath: String
        let length: Int64
        let revision: String
    }

    let schema: String
    let projectPath: String
    let visualizationPath: String
    let sourceDirectory: String
    let mapIndex: Int
    let mapName: String
    let mapType: String
    let sourceLayerName: String
    let displayLayerName: String
    let vectorType: String
    let featureCount: Int64
    let expectedRasterSubdatasetCount: Int
    let sourceRevision: String
    let sourceFiles: [SourceFile]
}
