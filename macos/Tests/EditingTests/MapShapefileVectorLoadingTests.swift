import CryptoKit
import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct MapShapefileVectorLoadingTests {
    @Test
    func conversionRetainsProjectedAndSourceCoordinatesOrderedPartsAndDuplicateTypedColumns() throws {
        let source = URL(fileURLWithPath: "/tmp/roads.shp")
        let data = polylineData()
        let mapID = try #require(UUID(uuidString: "47BE45D6-3D7A-4D61-91F7-488ABFA243D9"))

        let layer = try MapShapefileVectorConverter.makeLayer(data: data, mapType: "PolylinesVector",
            sourceURL: source, sourceMapID: mapID,
            sourceRevision: String(repeating: "A", count: 64))

        let feature = try #require(layer.features.only)
        #expect(layer.sourceMapID?.uuidString == "47BE45D6-3D7A-4D61-91F7-488ABFA243D9")
        #expect(layer.sourceRevision == String(repeating: "A", count: 64))
        #expect(layer.sourceProjectionWKT == "source-source-wkt")
        #expect(layer.targetProjectionWKT == "project-target-wkt")
        #expect(feature.stableIdentity == "retained-source-feature-id")
        #expect(feature.sourceFeatureIndex == 17)
        #expect(feature.geometryPath == "shape.parts")
        #expect(feature.paths.map(\.count) == [2, 2])
        #expect(feature.paths[0][0] == MapPoint(x: 100.5, y: 200.25))
        #expect(feature.sourceCoordinatePaths?[0][0] == MapSourceCoordinate(x: 10.5, y: 20.25, z: 4, m: 8))
        #expect(feature.pathStableIdentities == [
            "retained-source-feature-id|part:3", "retained-source-feature-id|part:8"
        ])
        #expect(feature.hasUniqueStableIdentity)
        #expect(feature.sourceFeatureIndex == 17)
        #expect(feature.sourceAttributeColumns?.map(\.ordinal) == [0, 1, 2, 3, 4])
        #expect(feature.sourceAttributeColumns?.map(\.name) == ["Label", "Label", "Ratio", "Visible", "Missing"])
        #expect(feature.sourceAttributeColumns?.map(\.value) == [
            .string("main"), .integer("42"), .number("3.125"), .boolean(false), .null
        ])
        #expect(feature.sourceAttributes?["Label"] == .integer("42"))
        #expect(feature.attributes["Label"] == "42")
        #expect(feature.attributes["Visible"] == "false")
    }

    @Test
    func conversionRejectsWrongShapeMismatchedRecordsAndMissingTargetProjection() throws {
        let source = URL(fileURLWithPath: "/tmp/roads.shp")

        #expect(throws: MapSourceLayerError.self) {
            try MapShapefileVectorConverter.makeLayer(data: polylineData(), mapType: "PointsVector",
                sourceURL: source, sourceMapID: UUID(), sourceRevision: String(repeating: "A", count: 64))
        }
        var noTarget = polylineData()
        noTarget = MapVectorSourceData(shapeType: noTarget.shapeType, shapeTypeCode: noTarget.shapeTypeCode,
            count: noTarget.count, sourceExtent: noTarget.sourceExtent, extent: noTarget.extent,
            projectionStatus: noTarget.projectionStatus,
            sourceProjectionWKT: noTarget.sourceProjectionWKT, targetProjectionWKT: nil,
            features: noTarget.features)
        #expect(throws: MapSourceLayerError.self) {
            try MapShapefileVectorConverter.makeLayer(data: noTarget, mapType: "PolylinesVector",
                sourceURL: source, sourceMapID: UUID(), sourceRevision: String(repeating: "A", count: 64))
        }
        let noGeometry = MapVectorSourceData(shapeType: "Polyline", shapeTypeCode: 3, count: 1,
            sourceExtent: nil, extent: nil, projectionStatus: "projected",
            sourceProjectionWKT: "source-crs", targetProjectionWKT: "project-crs", features: [])
        #expect(throws: MapSourceLayerError.self) {
            try MapShapefileVectorConverter.makeLayer(data: noGeometry, mapType: "PolylinesVector",
                sourceURL: source, sourceMapID: UUID(), sourceRevision: String(repeating: "A", count: 64))
        }
    }

    @Test
    func validEmptySourceProducesAnEmptyLayerWithoutSyntheticFeatures() throws {
        let data = MapVectorSourceData(shapeType: "Point", shapeTypeCode: 1, count: 0,
            sourceExtent: nil, extent: nil, projectionStatus: "projected",
            sourceProjectionWKT: "source-crs", targetProjectionWKT: "project-crs", features: [])

        let layer = try MapShapefileVectorConverter.makeLayer(data: data, mapType: "PointsVector",
            sourceURL: URL(fileURLWithPath: "/tmp/empty.shp"), sourceMapID: UUID(),
            sourceRevision: String(repeating: "E", count: 64))

        #expect(layer.features.isEmpty)
        #expect(layer.points.isEmpty)
    }

    @Test
    func conversionAcceptsRetainedThreeVertexPolygonRingWithoutInventingClosureVertex() throws {
        let vertices = [
            MapVectorSourceVertex(x: 100, y: 200, sourceX: 10, sourceY: 20, z: nil, m: nil),
            MapVectorSourceVertex(x: 110, y: 200, sourceX: 11, sourceY: 20, z: nil, m: nil),
            MapVectorSourceVertex(x: 105, y: 210, sourceX: 10.5, sourceY: 21, z: nil, m: nil)
        ]
        let data = MapVectorSourceData(shapeType: "Polygon", shapeTypeCode: 5, count: 1,
            sourceExtent: .init(minX: 10, minY: 20, maxX: 11, maxY: 21),
            extent: .init(minX: 100, minY: 200, maxX: 110, maxY: 210),
            projectionStatus: "projected",
            sourceProjectionWKT: "source-crs", targetProjectionWKT: "project-crs",
            features: [.init(sourceOrdinal: 0, sourceID: nil, shapeType: "Polygon",
                parts: [.init(partOrdinal: 0, vertices: vertices)], attributes: [])])

        let sourceRevision = String(repeating: "B", count: 64)
        let layer = try MapShapefileVectorConverter.makeLayer(data: data, mapType: "PolygonsVector",
            sourceURL: URL(fileURLWithPath: "/tmp/triangles.shp"), sourceMapID: UUID(),
            sourceRevision: sourceRevision)
        let feature = try #require(layer.features.only)
        #expect(feature.stableIdentity == "shapefile-record:0:sha256:\(sourceRevision)")
        #expect(feature.paths.only?.count == 3)
        #expect(layer.sourceProjectionWKT == "source-crs")
        #expect(layer.targetProjectionWKT == "project-crs")
    }

    @Test
    func nullShapeRecordsKeepIdentityAndAttributesWithoutDrawingPlaceholderGeometry() throws {
        let sourceRevision = String(repeating: "D", count: 64)
        let attribute = MapVectorSourceAttribute(columnOrdinal: 0, columnName: "Label",
            type: "string", value: "null-shape-record", booleanValue: nil)
        let cases: [(String, String, Int32, MapFeature.Kind)] = [
            ("PointsVector", "Point", 1, .point),
            ("PolylinesVector", "Polyline", 3, .line),
            ("PolygonsVector", "Polygon", 5, .polygon)
        ]

        for (mapType, shapeType, shapeCode, expectedKind) in cases {
            let data = MapVectorSourceData(shapeType: shapeType, shapeTypeCode: shapeCode,
                count: 1, sourceExtent: nil, extent: nil, projectionStatus: "projected",
                sourceProjectionWKT: "source-crs", targetProjectionWKT: "project-crs",
                features: [.init(sourceOrdinal: 4, sourceID: nil, shapeType: shapeType,
                    parts: [], attributes: [attribute])])
            let layer = try MapShapefileVectorConverter.makeLayer(data: data, mapType: mapType,
                sourceURL: URL(fileURLWithPath: "/tmp/null-shape.shp"), sourceMapID: UUID(),
                sourceRevision: sourceRevision)
            let feature = try #require(layer.features.only)
            #expect(feature.kind == expectedKind)
            #expect(feature.paths.isEmpty)
            #expect(feature.sourceCoordinatePaths?.isEmpty == true)
            #expect(feature.sourceFeatureIndex == 4)
            #expect(feature.stableIdentity == "shapefile-record:4:sha256:\(sourceRevision)")
            #expect(feature.sourceAttributeColumns?.map(\.name) == ["Label"])
            #expect(feature.sourceAttributes?["Label"] == .string("null-shape-record"))
        }
    }

    @Test
    func localProjectCoordinatesRemainUnprojectedWithoutInventingTargetCRS() throws {
        let projected = polylineData()
        let localFeatures = projected.features.map { feature in
            MapVectorSourceFeature(sourceOrdinal: feature.sourceOrdinal, sourceID: feature.sourceID,
                shapeType: feature.shapeType, parts: feature.parts.map { part in
                    MapVectorSourcePart(partOrdinal: part.partOrdinal, vertices: part.vertices.map { vertex in
                        MapVectorSourceVertex(x: vertex.sourceX, y: vertex.sourceY,
                            sourceX: vertex.sourceX, sourceY: vertex.sourceY, z: vertex.z, m: vertex.m)
                    })
                }, attributes: feature.attributes)
        }
        let data = MapVectorSourceData(shapeType: projected.shapeType, shapeTypeCode: projected.shapeTypeCode,
            count: projected.count, sourceExtent: projected.sourceExtent, extent: projected.sourceExtent,
            projectionStatus: "localProjectSourceCoordinates",
            sourceProjectionWKT: "source-crs", targetProjectionWKT: nil, features: localFeatures)
        let sourceRevision = String(repeating: "C", count: 64)

        let layer = try MapShapefileVectorConverter.makeLayer(data: data, mapType: "PolylinesVector",
            sourceURL: URL(fileURLWithPath: "/tmp/local-roads.shp"), sourceMapID: UUID(),
            sourceRevision: sourceRevision)

        #expect(layer.sourceProjectionWKT == "source-crs")
        #expect(layer.targetProjectionWKT == nil)
        #expect(layer.features.first?.paths.first?.map(\.x) == [10.5, 11.5])
        #expect(MapShapefileVectorConverter.hasValidProjectionContract(data))

        let falselyProjected = MapVectorSourceData(shapeType: data.shapeType, shapeTypeCode: data.shapeTypeCode,
            count: data.count, sourceExtent: data.sourceExtent, extent: data.extent,
            projectionStatus: "projected", sourceProjectionWKT: nil,
            targetProjectionWKT: "project-crs", features: data.features)
        #expect(!MapShapefileVectorConverter.hasValidProjectionContract(falselyProjected))
    }

    @Test @MainActor
    func exactBackendReplyLoadsOneCapturedFamilyAndRejectsChangedSidecar() async throws {
        let fixture = try LoaderFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let provider = StubMapVectorSourceProvider(result: fixture.result)

        let loaded = try await MapShapefileSourceLoader.load(map: fixture.map, node: fixture.node,
            expectedSourcePath: fixture.sourceURL.path, expectedSourceRevision: fixture.sourceRevision,
            provider: provider)

        #expect(provider.requests.count == 1)
        #expect(provider.requests.first?.map == fixture.map)
        #expect(provider.requests.first?.node == fixture.node)
        #expect(provider.requests.first?.expectedFamily == nil)
        #expect(loaded.family == fixture.family)
        #expect(loaded.layer.features.first?.stableIdentity == "retained-source-feature-id")

        try Data("changed DBF".utf8).write(to: fixture.dbfURL)
        do {
            _ = try await MapShapefileSourceLoader.load(map: fixture.map, node: fixture.node,
                expectedSourcePath: fixture.sourceURL.path, expectedSourceRevision: fixture.sourceRevision,
                provider: provider)
            Issue.record("The changed DBF sidecar should invalidate the captured Shapefile family.")
        } catch MapSourceLayerError.sourceChanged {
            // Expected: a family member changed after it was captured.
        } catch {
            Issue.record("Expected a sourceChanged error, got \(error).")
        }
    }

    @Test @MainActor
    func replyForDifferentNodeIsRejectedBeforeLayerConstruction() async throws {
        let fixture = try LoaderFixture()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        let mismatchedLocator = CatalogTreeNodeLocator(rootName: fixture.node.rootName,
            nodeType: fixture.node.nodeType, nodeName: "Other roads", assetID: fixture.node.assetID,
            mapType: fixture.node.mapType, filename: fixture.node.filename)
        let response = MapVectorSourceLoadResult(source: .init(map: fixture.mapCapture,
            locator: mismatchedLocator, family: fixture.family), data: polylineData())
        let provider = StubMapVectorSourceProvider(result: response)

        do {
            _ = try await MapShapefileSourceLoader.load(map: fixture.map, node: fixture.node,
                expectedSourcePath: fixture.sourceURL.path, expectedSourceRevision: fixture.sourceRevision,
                provider: provider)
            Issue.record("A reply for another saved node must not be installed.")
        } catch MapSourceLayerError.mismatchedReply {
            // Expected: the backend response is bound to a different locator.
        } catch {
            Issue.record("Expected a mismatchedReply error, got \(error).")
        }
    }

    private func polylineData() -> MapVectorSourceData {
        let firstPart = MapVectorSourcePart(partOrdinal: 3, vertices: [
            .init(x: 100.5, y: 200.25, sourceX: 10.5, sourceY: 20.25, z: 4, m: 8),
            .init(x: 101.5, y: 201.25, sourceX: 11.5, sourceY: 21.25, z: 5, m: 9)
        ])
        let secondPart = MapVectorSourcePart(partOrdinal: 8, vertices: [
            .init(x: 110.5, y: 210.25, sourceX: 20.5, sourceY: 30.25, z: nil, m: 10),
            .init(x: 111.5, y: 211.25, sourceX: 21.5, sourceY: 31.25, z: nil, m: 11)
        ])
        let attributes = [
            MapVectorSourceAttribute(columnOrdinal: 0, columnName: "Label", type: "string", value: "main", booleanValue: nil),
            MapVectorSourceAttribute(columnOrdinal: 1, columnName: "Label", type: "integer", value: "42", booleanValue: nil),
            MapVectorSourceAttribute(columnOrdinal: 2, columnName: "Ratio", type: "number", value: "3.125", booleanValue: nil),
            MapVectorSourceAttribute(columnOrdinal: 3, columnName: "Visible", type: "boolean", value: nil, booleanValue: false),
            MapVectorSourceAttribute(columnOrdinal: 4, columnName: "Missing", type: "number", value: nil, booleanValue: nil)
        ]
        let feature = MapVectorSourceFeature(sourceOrdinal: 17, sourceID: "retained-source-feature-id",
            shapeType: "Polyline", parts: [firstPart, secondPart], attributes: attributes)
        return .init(shapeType: "Polyline", shapeTypeCode: 13, count: 1,
            sourceExtent: .init(minX: 10, minY: 20, maxX: 22, maxY: 32),
            extent: .init(minX: 100, minY: 200, maxX: 112, maxY: 212),
            projectionStatus: "projected", sourceProjectionWKT: "source-source-wkt",
            targetProjectionWKT: "project-target-wkt", features: [feature])
    }
}

@MainActor
private final class StubMapVectorSourceProvider: MapVectorSourceLoading {
    let result: MapVectorSourceLoadResult
    private(set) var requests: [MapVectorSourceLoadRequest] = []

    init(result: MapVectorSourceLoadResult) { self.result = result }

    func load(_ request: MapVectorSourceLoadRequest) async throws -> MapVectorSourceLoadResult {
        requests.append(request)
        return result
    }
}

private struct LoaderFixture {
    let folder: URL
    let sourceURL: URL
    let dbfURL: URL
    let sourceRevision: String
    let family: MapSourceFamilyCapture
    let map: MapTreeMapIdentity
    let node: CatalogTreeNodeLocator
    let mapCapture: MapSourceMapCapture
    let result: MapVectorSourceLoadResult

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("map-shapefile-vector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let projectURL = root.appendingPathComponent("project.ras")
        let visualizationURL = root.appendingPathComponent("project.vis")
        let shapefileURL = root.appendingPathComponent("roads.shp")
        let shxURL = root.appendingPathComponent("roads.shx")
        let attributesURL = root.appendingPathComponent("roads.dbf")
        let prjURL = root.appendingPathComponent("roads.prj")
        try Data("project bytes".utf8).write(to: projectURL)
        try Data("visualization bytes".utf8).write(to: visualizationURL)
        try Data("shape bytes".utf8).write(to: shapefileURL)
        try Data("index bytes".utf8).write(to: shxURL)
        try Data("attributes bytes".utf8).write(to: attributesURL)
        // The projection sidecar is optional in the retained Shapefile family.

        let canonicalSource = SourceFilePaths.canonical(shapefileURL)
        let sourceDigest = Self.sha256(try Data(contentsOf: shapefileURL))
        let files = [
            try Self.file(shapefileURL, role: "source", required: true),
            try Self.file(shxURL, role: "shx", required: true),
            try Self.file(attributesURL, role: "dbf", required: true),
            .init(inputPath: prjURL.path, path: SourceFilePaths.canonical(prjURL), role: "prj",
                  required: false, exists: false, revision: nil)
        ].sorted { $0.path < $1.path }
        let unrevisionedFamily = MapSourceFamilyCapture(family: "shapefile", sourcePath: canonicalSource,
            revision: String(repeating: "0", count: 64), files: files)
        let capturedFamily = MapSourceFamilyCapture(family: unrevisionedFamily.family, sourcePath: unrevisionedFamily.sourcePath,
            revision: MapShapefileVectorConverter.familyRevision(unrevisionedFamily), files: files)

        guard let mapID = UUID(uuidString: "47BE45D6-3D7A-4D61-91F7-488ABFA243D9") else {
            throw CocoaError(.coderInvalidValue)
        }
        let projectSHA = String(repeating: "A", count: 64)
        let visualizationRevision = Self.sha256(try Data(contentsOf: visualizationURL))
        let mapIdentity = MapTreeMapIdentity(projectPath: SourceFilePaths.canonical(projectURL), projectXml: "<Project />",
            projectXmlSHA: projectSHA, mapID: mapID.uuidString, mapIndex: 0,
            mapName: "Project Map", mapType: "Project", expectedVisualizationRevision: visualizationRevision)
        let locator = CatalogTreeNodeLocator(rootName: "Map Layers", nodeType: "MapLayer", nodeName: "Road lines",
            assetID: canonicalSource, mapType: "PolylinesVector", filename: shapefileURL.lastPathComponent)
        let capturedMap = MapSourceMapCapture(projectPath: SourceFilePaths.canonical(projectURL),
            projectRevision: Self.sha256(try Data(contentsOf: projectURL)), projectXmlSHA: projectSHA,
            visualizationPath: SourceFilePaths.canonical(visualizationURL),
            visualizationRevision: visualizationRevision, mapID: mapID.uuidString, mapIndex: 0,
            mapName: "Project Map", mapType: "Project", isPersisted: true)
        let sourceResult = MapVectorSourceLoadResult(source: .init(map: capturedMap, locator: locator, family: capturedFamily),
                       data: Self.sampleData())

        folder = root
        sourceURL = shapefileURL
        dbfURL = attributesURL
        sourceRevision = sourceDigest
        family = capturedFamily
        map = mapIdentity
        node = locator
        mapCapture = capturedMap
        result = sourceResult
    }

    private static func file(_ url: URL, role: String, required: Bool) throws -> MapSourceFileRevision {
        let data = try Data(contentsOf: url)
        return .init(inputPath: url.path, path: SourceFilePaths.canonical(url), role: role,
                     required: required, exists: true, revision: sha256(data))
    }

    private static func sampleData() -> MapVectorSourceData {
        let vertices = [
            MapVectorSourceVertex(x: 10, y: 20, sourceX: 10, sourceY: 20, z: 5, m: 9),
            MapVectorSourceVertex(x: 11, y: 21, sourceX: 11, sourceY: 21, z: 6, m: 10)
        ]
        let feature = MapVectorSourceFeature(sourceOrdinal: 0, sourceID: "retained-source-feature-id",
            shapeType: "Polyline", parts: [.init(partOrdinal: 0, vertices: vertices)], attributes: [])
        return .init(shapeType: "Polyline", shapeTypeCode: 3, count: 1, sourceExtent: nil,
                     extent: nil, projectionStatus: "localProjectSourceCoordinates", sourceProjectionWKT: nil,
                     targetProjectionWKT: nil,
                     features: [feature])
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }
}

private extension Collection {
    var only: Element? {
        guard count == 1 else { return nil }
        return first
    }
}
