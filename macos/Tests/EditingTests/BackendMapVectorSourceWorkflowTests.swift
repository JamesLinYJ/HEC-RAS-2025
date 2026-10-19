import CryptoKit
import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct BackendMapVectorSourceWorkflowTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_MAP_VECTOR_SOURCE_ACCEPTANCE_DIRECTORY"] != nil
        && ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil))
    @MainActor
    func bundledBackendLoadsAllPersistedShapefileKindsAndPreservesTheirFamilies() async throws {
        let environment = ProcessInfo.processInfo.environment
        let fixtureDirectory = URL(fileURLWithPath: try #require(environment["HECRAS_MAP_VECTOR_SOURCE_ACCEPTANCE_DIRECTORY"]))
        let executable = URL(fileURLWithPath: try #require(environment["HECRAS_BACKEND_TEST_EXECUTABLE"]))
        let manifestURL = fixtureDirectory.appendingPathComponent("MAP_VECTOR_SOURCE_FIXTURE.json")
        let manifest = try JSONDecoder().decode(ShapefileAcceptanceManifest.self,
            from: Data(contentsOf: manifestURL))
        #expect(manifest.version == 1)
        #expect(manifest.sourceFamilies.count == 3)
        #expect(Set(manifest.sourceFamilies.map(\.mapType)) == Set(["PointsVector", "PolylinesVector", "PolygonsVector"]))

        let projectURL = fixtureDirectory.appendingPathComponent(manifest.projectPath).standardizedFileURL
        let visualizationURL = fixtureDirectory.appendingPathComponent(manifest.visualizationPath).standardizedFileURL
        let primary = try #require(manifest.sourceFamilies.first(where: { $0.sourcePath == manifest.primarySourcePath }))
        #expect(primary.mapType == "PolylinesVector")
        #expect(primary.locator == manifest.result.source.locator)
        #expect(primary.expectedFamily == manifest.result.source.family)
        #expect(primary.result.data.count == manifest.result.data.count)
        #expect(primary.result.data.projectionStatus == manifest.result.data.projectionStatus)
        #expect(primary.result.data.features.first?.sourceOrdinal == manifest.result.data.features.first?.sourceOrdinal)
        #expect(primary.result.data.features.first?.parts.first?.vertices.first == manifest.result.data.features.first?.parts.first?.vertices.first)

        // The producer captures File.ReadAllText's original XML, without the
        // UTF-8 preamble. Keep that exact snapshot paired with its source SHA.
        let projectBytes = try Data(contentsOf: projectURL)
        let projectTextBytes = projectBytes.starts(with: [0xEF, 0xBB, 0xBF])
            ? Data(projectBytes.dropFirst(3)) : projectBytes
        let projectXML = try #require(String(data: projectTextBytes, encoding: .utf8))
        #expect(digest(Data(projectXML.utf8)) == manifest.map.projectXmlSHA)
        let map = MapTreeMapIdentity(projectPath: projectURL.path, projectXml: projectXML,
            projectXmlSHA: manifest.map.projectXmlSHA, mapID: manifest.map.mapID,
            mapIndex: manifest.map.mapIndex, mapName: manifest.map.mapName,
            mapType: manifest.map.mapType,
            expectedVisualizationRevision: manifest.map.expectedVisualizationRevision)
        #expect(manifest.result.source.map.projectRevision == manifest.projectRevision)
        #expect(manifest.result.source.map.projectXmlSHA == manifest.map.projectXmlSHA)

        let sourceURLs = manifest.sourceFamilies.map { source in
            fixtureDirectory.appendingPathComponent(source.sourcePath).standardizedFileURL
        }
        let protectedURLs = Set(manifest.sourceFamilies.flatMap { source in
            source.expectedFamily.files.filter(\.exists).map { URL(fileURLWithPath: $0.path) }
        }).union([projectURL, visualizationURL])
        let expectedBytes = try Dictionary(uniqueKeysWithValues: protectedURLs.map { url in
            (SourceFilePaths.canonical(url), try Data(contentsOf: url))
        })
        let expectedFamilyFileCount = manifest.sourceFamilies.reduce(0) { total, source in
            total + source.expectedFamily.files.filter(\.exists).count
        }
        #expect(expectedBytes.count == expectedFamilyFileCount + 2)
        #expect(digest(try Data(contentsOf: projectURL)) == manifest.projectRevision)

        for (source, sourceURL) in zip(manifest.sourceFamilies, sourceURLs) {
            let expected = source.result
            let expectedSource = expected.source
            let expectedData = expected.data
            let sourceRevision = try #require(expectedSource.family.files.first(where: { $0.role == "source" })?.revision)
            let (shapeName, shapeCodes) = try shapeType(for: source.mapType)

            #expect(expectedSource.locator == source.locator)
            #expect(expectedSource.family == source.expectedFamily)
            #expect(expectedSource.family.sourcePath == SourceFilePaths.canonical(sourceURL))
            #expect(expectedData.shapeType == shapeName)
            #expect(shapeCodes.contains(expectedData.shapeTypeCode))
            #expect(expectedData.projectionStatus == "projected")
            #expect(expectedData.count == expectedData.features.count)
            #expect(expectedData.count > 0)
            #expect(expectedData.sourceProjectionWKT?.isEmpty == false)
            #expect(expectedData.targetProjectionWKT?.isEmpty == false)
            #expect(digest(try Data(contentsOf: sourceURL)) == sourceRevision)

            let provider = RecordingMapVectorSourceProvider(
                backend: BackendMapVectorSourceProvider(client: BackendProcessClient(executableURL: executable)))
            let loaded = try await MapShapefileSourceLoader.load(map: map, node: source.locator,
                expectedSourcePath: SourceFilePaths.canonical(sourceURL),
                expectedSourceRevision: sourceRevision, provider: provider)
            let backendResult = try #require(provider.result)
            let sentRequest = try #require(provider.request)

            #expect(sentRequest.map == map)
            #expect(sentRequest.node == source.locator)
            #expect(sentRequest.expectedFamily == nil)
            #expect(backendResult.source.map == expectedSource.map)
            #expect(backendResult.source.locator == expectedSource.locator)
            #expect(backendResult.source.family == expectedSource.family)
            #expect(backendResult.data.shapeType == expectedData.shapeType)
            #expect(backendResult.data.shapeTypeCode == expectedData.shapeTypeCode)
            #expect(backendResult.data.count == expectedData.count)
            #expect(backendResult.data.projectionStatus == expectedData.projectionStatus)
            #expect(backendResult.data.sourceProjectionWKT == expectedData.sourceProjectionWKT)
            #expect(backendResult.data.targetProjectionWKT == expectedData.targetProjectionWKT)
            #expect(backendResult.data.sourceExtent == expectedData.sourceExtent)
            #expect(backendResult.data.extent == expectedData.extent)
            #expect(backendResult.data.features.count == expectedData.features.count)
            #expect(loaded.family == expectedSource.family)
            #expect(loaded.layer.sourceMapID == UUID(uuidString: manifest.map.mapID))
            #expect(loaded.layer.sourceRevision == sourceRevision.uppercased())
            #expect(loaded.layer.sourceProjectionWKT == expectedData.sourceProjectionWKT)
            #expect(loaded.layer.targetProjectionWKT == expectedData.targetProjectionWKT)
            #expect(loaded.layer.features.count == expectedData.count)

            for (featureIndex, expectedFeature) in expectedData.features.enumerated() {
                let loadedFeature = try #require(loaded.layer.features.dropFirst(featureIndex).first)
                let sourceFeature = try #require(backendResult.data.features.dropFirst(featureIndex).first)
                #expect(sourceFeature.sourceOrdinal == expectedFeature.sourceOrdinal)
                #expect(sourceFeature.sourceID == expectedFeature.sourceID)
                #expect(sourceFeature.shapeType == expectedFeature.shapeType)
                #expect(sourceFeature.parts.map(\.partOrdinal) == expectedFeature.parts.map(\.partOrdinal))
                #expect(sourceFeature.attributes == expectedFeature.attributes)
                #expect(loadedFeature.sourceFeatureIndex == expectedFeature.sourceOrdinal)
                #expect(loadedFeature.stableIdentity == (expectedFeature.sourceID
                    ?? "shapefile-record:\(expectedFeature.sourceOrdinal):sha256:\(sourceRevision.uppercased())"))
                #expect(loadedFeature.paths.count == expectedFeature.parts.count)
                #expect(loadedFeature.paths.map(\.count) == expectedFeature.parts.map { $0.vertices.count })
                #expect(loadedFeature.sourceCoordinatePaths?.map(\.count) == expectedFeature.parts.map { $0.vertices.count })
                for (partIndex, expectedPart) in expectedFeature.parts.enumerated() {
                    #expect(loadedFeature.paths[partIndex].map(\.x) == expectedPart.vertices.map(\.x))
                    #expect(loadedFeature.paths[partIndex].map(\.y) == expectedPart.vertices.map(\.y))
                    #expect(loadedFeature.sourceCoordinatePaths?[partIndex].map(\.x) == expectedPart.vertices.map(\.sourceX))
                    #expect(loadedFeature.sourceCoordinatePaths?[partIndex].map(\.y) == expectedPart.vertices.map(\.sourceY))
                    #expect(loadedFeature.sourceCoordinatePaths?[partIndex].map(\.z) == expectedPart.vertices.map(\.z))
                    #expect(loadedFeature.sourceCoordinatePaths?[partIndex].map(\.m) == expectedPart.vertices.map(\.m))
                    #expect(loadedFeature.pathStableIdentities[partIndex].hasSuffix("|part:\(expectedPart.partOrdinal)"))
                }
                #expect(loadedFeature.sourceAttributeColumns?.map(\.ordinal) == expectedFeature.attributes.map(\.columnOrdinal))
                #expect(loadedFeature.sourceAttributeColumns?.map(\.name) == expectedFeature.attributes.map(\.columnName))
                let expectedAttributeValues = try expectedFeature.attributes.map { try $0.typedValue() }
                #expect(loadedFeature.sourceAttributeColumns?.map(\.value) == expectedAttributeValues)
            }
        }

        for (path, bytes) in expectedBytes {
            #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == bytes)
        }
    }

    private func shapeType(for mapType: String) throws -> (String, Set<Int32>) {
        switch mapType {
        case "PointsVector": return ("Point", Set([1, 11, 21]))
        case "PolylinesVector": return ("Polyline", Set([3, 13, 23]))
        case "PolygonsVector": return ("Polygon", Set([5, 15, 25]))
        default: throw MapSourceLayerError.unsupportedMapLayerType(mapType)
        }
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }
}

@MainActor
private final class RecordingMapVectorSourceProvider: MapVectorSourceLoading {
    private let backend: any MapVectorSourceLoading
    private(set) var result: MapVectorSourceLoadResult?
    private(set) var request: MapVectorSourceLoadRequest?

    init(backend: any MapVectorSourceLoading) { self.backend = backend }

    func load(_ request: MapVectorSourceLoadRequest) async throws -> MapVectorSourceLoadResult {
        self.request = request
        let result = try await backend.load(request)
        self.result = result
        return result
    }
}

private struct ShapefileAcceptanceManifest: Decodable {
    struct Map: Decodable {
        let mapID: String
        let mapIndex: Int
        let mapName: String
        let mapType: String
        let projectXmlSHA: String
        let expectedVisualizationRevision: String
    }

    struct Source: Decodable {
        let sourcePath: String
        let mapType: String
        let locator: CatalogTreeNodeLocator
        let expectedFamily: MapSourceFamilyCapture
        let result: MapVectorSourceLoadResult
    }

    let version: Int
    let projectPath: String
    let visualizationPath: String
    let projectRevision: String
    let map: Map
    let primarySourcePath: String
    let sourceFamilies: [Source]
    let result: MapVectorSourceLoadResult
}
