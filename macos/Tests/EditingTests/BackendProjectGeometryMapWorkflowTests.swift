import CryptoKit
import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct BackendProjectGeometryMapWorkflowTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_GEOMETRY_MAP_ACCEPTANCE_DIRECTORY"] != nil
        && ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil)) @MainActor
    func actualGeometryProviderReadsEverySourceCellAndDrainsEmptyViewportPages() async throws {
        let fixture = try GeometryMapWorkflowFixture()
        defer { fixture.cleanup() }
        let client = try fixture.client()
        let capture = try await fixture.capture(client: client, mapName: "Map A", geometryName: "Map geometry A")
        let provider = BackendProjectGeometryMapProvider(client: client, isCurrent: { true })
        let initial = try await provider.load(fixture.request(capture), capture: capture)
        let first = try #require(initial.flowAreas)
        #expect(first.sourceCellCount > 16_384)
        #expect(first.cells.count == 512 && !first.complete)
        #expect(initial.geometryEffectiveVisible && initial.flowAreasState.effectiveVisible)
        let areas = Set(first.areas.map(\.id))
        #expect(!areas.isEmpty)

        var allCells = first.cells
        var scanned = first.scannedSourceCellCount
        var invalid = first.invalidCellCount
        var cursor = first.nextCursor
        var seenCursors: Set<String> = []
        while let next = cursor {
            guard seenCursors.insert(next).inserted else {
                Issue.record("Source pagination repeated a continuation cursor.")
                return
            }
            guard seenCursors.count <= first.sourceCellCount else {
                Issue.record("Source cell pagination did not make bounded progress.")
                return
            }
            let snapshot = try await provider.load(fixture.request(capture,
                contextToken: initial.contextToken, cellCursor: next,
                skipTopology: true, skipCulverts: true), capture: capture)
            let page = try #require(snapshot.flowAreas)
            #expect(snapshot.geometryRevision == initial.geometryRevision)
            #expect(snapshot.contextToken == initial.contextToken)
            #expect(page.sourceCellCount == first.sourceCellCount)
            allCells += page.cells
            scanned += page.scannedSourceCellCount
            invalid += page.invalidCellCount
            cursor = page.nextCursor
        }
        #expect(scanned == first.sourceCellCount)
        #expect(invalid == 0)
        #expect(allCells.count == first.sourceCellCount)
        #expect(Set(allCells.map(\.id)).count == allCells.count)
        #expect(allCells.allSatisfy { cell in
            areas.contains(cell.flowAreaID) && cell.coordinates.count >= 3
                && cell.coordinates.allSatisfy { $0.x.isFinite && $0.y.isFinite }
        })

        let outside = try #require(MapGeometryViewport(extent: ViewportRequest(
            lowerLeft: MapPoint(x: 100_000, y: 100_000),
            upperRight: MapPoint(x: 100_010, y: 100_010))))
        var empty = try await provider.load(fixture.request(capture, viewport: outside,
            contextToken: initial.contextToken, skipTopology: true, skipCulverts: true), capture: capture)
        let firstEmpty = try #require(empty.flowAreas)
        #expect(firstEmpty.cells.isEmpty && !firstEmpty.complete)
        #expect(firstEmpty.scannedSourceCellCount == 16_384)
        #expect(firstEmpty.nextCursor != nil)
        var emptyScanned = firstEmpty.scannedSourceCellCount
        seenCursors = []
        while let next = empty.flowAreas?.nextCursor {
            guard seenCursors.insert(next).inserted else {
                Issue.record("Source pagination repeated a continuation cursor.")
                return
            }
            guard seenCursors.count <= first.sourceCellCount else {
                Issue.record("Empty viewport pagination did not make bounded progress.")
                return
            }
            empty = try await provider.load(fixture.request(capture, viewport: outside,
                contextToken: initial.contextToken, cellCursor: next,
                skipTopology: true, skipCulverts: true), capture: capture)
            let page = try #require(empty.flowAreas)
            #expect(page.cells.isEmpty)
            emptyScanned += page.scannedSourceCellCount
        }
        #expect(empty.flowAreas?.complete == true)
        #expect(emptyScanned == first.sourceCellCount)

        let culvertCapture = try await fixture.capture(client: client,
            mapName: "Map B", geometryName: "Map geometry B")
        let culvertProvider = BackendProjectGeometryMapProvider(client: client, isCurrent: { true })
        let barrels = try await culvertProvider.load(fixture.request(culvertCapture, pageSize: 1), capture: culvertCapture)
        let firstBarrel = try #require(barrels.culverts)
        #expect(firstBarrel.sourceBarrelCount == 2 && firstBarrel.features.count == 1 && !firstBarrel.complete)
        let barrelCursor = try #require(firstBarrel.nextCursor)
        let remainder = try await culvertProvider.load(fixture.request(culvertCapture,
            contextToken: barrels.contextToken, culvertCursor: barrelCursor,
            skipTopology: true, skipFlowAreas: true, pageSize: 1), capture: culvertCapture)
        let lastBarrel = try #require(remainder.culverts)
        #expect(lastBarrel.complete && lastBarrel.features.count == 1)
        let sourceBarrels = firstBarrel.features + lastBarrel.features
        #expect(Set(sourceBarrels.map(\.id)).count == 2)
        #expect(sourceBarrels.allSatisfy { $0.polyline.count >= 2 && $0.polyline.allSatisfy { $0.x.isFinite && $0.y.isFinite } })
        #expect(culvertCapture.mapID != capture.mapID)
        #expect(try fixture.originalsUnchanged())
        #expect(try fixture.workingCopyUnchanged())
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_GEOMETRY_MAP_ACCEPTANCE_DIRECTORY"] != nil
        && ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil)) @MainActor
    func actualGeometryProviderRejectsStaleVisualizationProjectAndHDFBetweenPages() async throws {
        let fixture = try GeometryMapWorkflowFixture()
        defer { fixture.cleanup() }
        let client = try fixture.client()
        let capture = try await fixture.capture(client: client, mapName: "Map A", geometryName: "Map geometry A")
        let provider = BackendProjectGeometryMapProvider(client: client, isCurrent: { true })
        let first = try await provider.load(fixture.request(capture), capture: capture)
        let nextCursor = try #require(first.flowAreas?.nextCursor)
        let next = fixture.request(capture, contextToken: first.contextToken, cellCursor: nextCursor,
            skipTopology: true, skipCulverts: true)
        let sourceURL = URL(fileURLWithPath: capture.geometryCanonicalPath)
        for url in [fixture.visualizationURL, fixture.projectURL, sourceURL] {
            let saved = try Data(contentsOf: url)
            var changed = saved
            changed.append(0x0A)
            try changed.write(to: url)
            do {
                _ = try await provider.load(next, capture: capture)
                Issue.record("Geometry pagination accepted an externally changed source: \(url.lastPathComponent)")
            } catch let error as BackendServiceError {
                #expect(error.code == "sourceChanged")
            } catch ProjectGeometryMapError.sourceChanged {
                // The frontend's own byte guard can reject before publication.
            }
            try saved.write(to: url)
        }
        #expect(try fixture.originalsUnchanged())
        #expect(try fixture.workingCopyUnchanged())
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_GEOMETRY_MAP_ACCEPTANCE_DIRECTORY"] != nil
        && ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil)) @MainActor
    func actualGeometryProviderRejectsRemovedHDFWithoutInventingAnEmptyMap() async throws {
        let fixture = try GeometryMapWorkflowFixture()
        defer { fixture.cleanup() }
        let client = try fixture.client()
        let capture = try await fixture.capture(client: client, mapName: "Map A", geometryName: "Map geometry A")
        let source = URL(fileURLWithPath: capture.geometryCanonicalPath)
        let held = source.appendingPathExtension("held")
        try FileManager.default.moveItem(at: source, to: held)
        defer {
            if FileManager.default.fileExists(atPath: held.path) {
                try? FileManager.default.moveItem(at: held, to: source)
            }
        }
        let provider = BackendProjectGeometryMapProvider(client: client, isCurrent: { true })
        do {
            _ = try await provider.load(fixture.request(capture), capture: capture)
            Issue.record("A removed live Geometry was accepted as an empty map.")
        } catch let error as BackendServiceError {
            // Retained Project.Load enumerates existing Geometry HDF files.
            // A serialized .vis row cannot replace that live source identity.
            #expect(error.code == "sourceChanged")
        }
        try FileManager.default.moveItem(at: held, to: source)
        #expect(try fixture.originalsUnchanged())
        #expect(try fixture.workingCopyUnchanged())
    }
}

private struct GeometryMapWorkflowFixture {
    let original: URL
    let root: URL
    let projectURL: URL
    let visualizationURL: URL
    private let originalHashes: [String: String]

    init() throws {
        let environment = ProcessInfo.processInfo.environment
        original = URL(fileURLWithPath: try #require(environment["HECRAS_GEOMETRY_MAP_ACCEPTANCE_DIRECTORY"]))
        originalHashes = try Self.hashes(in: original)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("geometry-project-map-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.copyItem(at: original, to: root)
        projectURL = root.appendingPathComponent("Geometry project map.ras")
        visualizationURL = projectURL.deletingPathExtension().appendingPathExtension("vis")
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
    func originalsUnchanged() throws -> Bool { try Self.hashes(in: original) == originalHashes }
    func workingCopyUnchanged() throws -> Bool { try Self.hashes(in: root) == originalHashes }

    func client() throws -> BackendProcessClient {
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        return BackendProcessClient(executableURL: URL(fileURLWithPath: executable))
    }

    @MainActor
    func capture(client: BackendProcessClient, mapName: String, geometryName: String) async throws -> ProjectGeometryMapCapture {
        var projectXML = try String(contentsOf: projectURL, encoding: .utf8)
        if projectXML.first == "\u{FEFF}" { projectXML.removeFirst() }
        let document = try VisualizationDocument(projectURL: projectURL)
        let sourceMap = try #require(document.maps.first { $0.name == mapName })
        let mapID = UUID()
        let map = MapTreeMapIdentity(projectPath: projectURL.path, projectXml: projectXML,
            projectXmlSHA: Self.sha(Data(projectXML.utf8)), mapID: mapID.uuidString,
            mapIndex: sourceMap.index, mapName: sourceMap.name, mapType: sourceMap.type,
            expectedVisualizationRevision: Self.sha(try Data(contentsOf: visualizationURL)))
        let tree: GeometryMapWorkflowTree = try await client.request("map.tree.load", parameters: map, as: GeometryMapWorkflowTree.self)
        let node = try #require(Self.walk(tree.roots).first { $0.locator?.nodeType == "Geometry" && $0.name == geometryName })
        let locator = try #require(node.locator)
        let asset = try #require(node.assetID ?? locator.assetID)
        return try ProjectGeometryMapCapture(projectSessionID: UUID(), mapID: mapID,
            mapWorkflowIdentity: "provider-workflow-" + mapID.uuidString,
            map: map, geometryNode: locator, geometryAssetPath: asset, geometryName: node.name)
    }

    func request(_ capture: ProjectGeometryMapCapture, viewport: MapGeometryViewport? = nil,
                 contextToken: String? = nil, cellCursor: String? = nil, culvertCursor: String? = nil,
                 skipTopology: Bool = false, skipFlowAreas: Bool = false, skipCulverts: Bool = false,
                 pageSize: Int = 512) -> MapGeometryRequest {
        MapGeometryRequest(map: capture.map, geometryNode: capture.geometryNode, viewport: viewport,
            contextToken: contextToken, cellCursor: cellCursor, culvertCursor: culvertCursor,
            skipTopologyPage: skipTopology, skipFlowAreasPage: skipFlowAreas,
            skipCulvertsPage: skipCulverts, pageSize: pageSize)
    }

    private static func walk(_ nodes: [GeometryMapWorkflowTree.Node]) -> [GeometryMapWorkflowTree.Node] {
        nodes.flatMap { [$0] + walk($0.children ?? []) }
    }

    private static func hashes(in directory: URL) throws -> [String: String] {
        let enumerator = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]))
        let prefix = SourceFilePaths.canonical(directory) + "/"
        var result: [String: String] = [:]
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                let physicalPath = SourceFilePaths.canonical(url)
                guard physicalPath.hasPrefix(prefix) else {
                    throw CocoaError(.fileReadInvalidFileName)
                }
                let path = String(physicalPath.dropFirst(prefix.count))
                result[path] = Self.sha(try Data(contentsOf: url))
            }
        }
        return result
    }

    private static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }
}

private struct GeometryMapWorkflowTree: Decodable, Sendable {
    let roots: [Node]
    struct Node: Decodable, Sendable {
        let name: String
        let assetID: String?
        let locator: CatalogTreeNodeLocator?
        let children: [Node]?
    }
}
