import CryptoKit
import Foundation
import RASWorkspaceCore

struct MapShapefileSourceReadResult: Sendable {
    let layer: MapVectorLayer
    let family: MapSourceFamilyCapture
}

/// Loads one exact persisted Shapefile map node through the retained backend
/// reader. The local conversion only adapts its typed response for drawing; it
/// never opens a Shapefile as GeoJSON or substitutes another source reader.
enum MapShapefileSourceLoader {
    @MainActor
    static func load(map: MapTreeMapIdentity,
                     node: CatalogTreeNodeLocator,
                     expectedSourcePath: String,
                     expectedSourceRevision: String,
                     provider: any MapVectorSourceLoading) async throws -> MapShapefileSourceReadResult {
        let sourceURL = URL(fileURLWithPath: expectedSourcePath)
        let canonicalSourcePath = SourceFilePaths.canonical(sourceURL)
        guard let mapType = node.mapType else { throw MapSourceLayerError.staleContext }
        guard sourceURL.path.hasPrefix("/"),
              sourceURL.pathExtension.lowercased() == "shp",
              MapShapefileVectorConverter.isSHA256(expectedSourceRevision),
              node.nodeType == "MapLayer",
              ["PointsVector", "PolylinesVector", "PolygonsVector"].contains(mapType),
              node.assetID.map({ SourceFilePaths.canonical(URL(fileURLWithPath: $0)) }) == canonicalSourcePath,
              FileManager.default.fileExists(atPath: canonicalSourcePath) else {
            throw MapSourceLayerError.staleContext
        }

        let response = try await provider.load(.init(map: map, node: node, expectedFamily: nil))
        try Task.checkCancellation()

        let capturedDiskRevisions = try await Self.diskRevisions(for: map)
        try Task.checkCancellation()
        guard BackendFeatureQueryProvider.matches(response.source.map, map: map,
                                                  projectRevision: capturedDiskRevisions.project),
              Self.sameVisualizationPath(response.source.map.visualizationPath, projectPath: map.projectPath),
              response.source.map.visualizationRevision?.caseInsensitiveCompare(capturedDiskRevisions.visualization) == .orderedSame,
              response.source.locator == node else {
            throw MapSourceLayerError.mismatchedReply
        }

        let family = try MapShapefileVectorConverter.validateFamily(
            response.source.family, sourcePath: canonicalSourcePath,
            sourceRevision: expectedSourceRevision)
        try await Self.verifyFamilyOnDisk(family)

        guard MapShapefileVectorConverter.hasValidProjectionContract(response.data) else {
            throw MapSourceLayerError.invalidVectorSnapshot
        }

        let mapUUID: UUID
        guard let parsedMapID = UUID(uuidString: map.mapID) else {
            throw MapSourceLayerError.mismatchedReply
        }
        mapUUID = parsedMapID

        let converted = try await Self.performDetached(priority: .userInitiated) {
            try MapShapefileVectorConverter.makeLayer(
                data: response.data, mapType: mapType, sourceURL: sourceURL,
                sourceMapID: mapUUID, sourceRevision: expectedSourceRevision)
        }

        try Task.checkCancellation()
        try await Self.verifyFamilyOnDisk(family)
        let finalDiskRevisions = try await Self.diskRevisions(for: map)
        guard finalDiskRevisions.project.caseInsensitiveCompare(capturedDiskRevisions.project) == .orderedSame,
              finalDiskRevisions.visualization.caseInsensitiveCompare(capturedDiskRevisions.visualization) == .orderedSame else {
            throw MapSourceLayerError.staleContext
        }
        return .init(layer: converted, family: family)
    }

    private static func sameVisualizationPath(_ responsePath: String, projectPath: String) -> Bool {
        guard responsePath.hasPrefix("/"), projectPath.hasPrefix("/") else { return false }
        let expected = URL(fileURLWithPath: projectPath).deletingPathExtension()
            .appendingPathExtension("vis")
        return SourceFilePaths.canonical(URL(fileURLWithPath: responsePath)) == SourceFilePaths.canonical(expected)
    }

    private static func diskRevisions(for map: MapTreeMapIdentity) async throws -> (project: String, visualization: String) {
        try await performDetached(priority: .utility) {
            try Task.checkCancellation()
            let projectURL = URL(fileURLWithPath: map.projectPath)
            let visualizationURL = projectURL.deletingPathExtension().appendingPathExtension("vis")
            let projectBytes = try Data(contentsOf: projectURL, options: [.mappedIfSafe])
            try Task.checkCancellation()
            let visualizationBytes = try Data(contentsOf: visualizationURL, options: [.mappedIfSafe])
            try Task.checkCancellation()
            return (Self.sha256(projectBytes), Self.sha256(visualizationBytes))
        }
    }

    private static func verifyFamilyOnDisk(_ family: MapSourceFamilyCapture) async throws {
        try await performDetached(priority: .utility) {
            try Task.checkCancellation()
            for file in family.files {
                try Task.checkCancellation()
                let inputURL = URL(fileURLWithPath: file.inputPath)
                let canonicalURL = URL(fileURLWithPath: file.path)
                guard inputURL.path.hasPrefix("/"), canonicalURL.path.hasPrefix("/"),
                      SourceFilePaths.canonical(inputURL) == SourceFilePaths.canonical(canonicalURL),
                      file.exists == (file.revision != nil) else {
                    throw MapSourceLayerError.sourceChanged
                }
                if let expectedRevision = file.revision {
                    guard MapShapefileVectorConverter.isSHA256(expectedRevision),
                          FileManager.default.fileExists(atPath: canonicalURL.path) else {
                        throw MapSourceLayerError.sourceChanged
                    }
                    let actualRevision = Self.sha256(try Data(contentsOf: canonicalURL, options: [.mappedIfSafe]))
                    guard actualRevision.caseInsensitiveCompare(expectedRevision) == .orderedSame else {
                        throw MapSourceLayerError.sourceChanged
                    }
                } else if FileManager.default.fileExists(atPath: canonicalURL.path) {
                    throw MapSourceLayerError.sourceChanged
                }
            }
        }
    }

    private static func performDetached<Value: Sendable>(
        priority: TaskPriority,
        operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        let worker = Task.detached(priority: priority) { try operation() }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }
}

enum MapShapefileVectorConverter {
    private struct ShapeDefinition {
        let kind: MapFeature.Kind
        let name: String
        let codes: Set<Int32>
    }

    private static let definitions: [String: ShapeDefinition] = [
        "PointsVector": .init(kind: .point, name: "Point", codes: [1, 11, 21]),
        "PolylinesVector": .init(kind: .line, name: "Polyline", codes: [3, 13, 23]),
        "PolygonsVector": .init(kind: .polygon, name: "Polygon", codes: [5, 15, 25])
    ]

    static func makeLayer(data: MapVectorSourceData, mapType: String, sourceURL: URL,
                          sourceMapID: UUID, sourceRevision: String) throws -> MapVectorLayer {
        guard let definition = definitions[mapType],
              data.shapeType.caseInsensitiveCompare(definition.name) == .orderedSame,
              definition.codes.contains(data.shapeTypeCode),
              data.count == data.features.count,
              hasValidProjectionContract(data),
              isSHA256(sourceRevision),
              data.extent.map(\.isFiniteAndOrdered) ?? true,
              data.sourceExtent.map(\.isFiniteAndOrdered) ?? true else {
            throw MapSourceLayerError.invalidVectorSnapshot
        }

        var seenOrdinals = Set<Int>()
        var identityCounts: [String: Int] = [:]
        var pending: [(feature: MapFeature, identity: String)] = []
        pending.reserveCapacity(data.features.count)

        for sourceFeature in data.features {
            try Task.checkCancellation()
            guard sourceFeature.sourceOrdinal >= 0,
                  seenOrdinals.insert(sourceFeature.sourceOrdinal).inserted,
                  sourceFeature.shapeType.caseInsensitiveCompare(definition.name) == .orderedSame,
                  sourceFeature.parts.allSatisfy({ $0.partOrdinal >= 0 }) else {
                throw MapSourceLayerError.invalidVectorSnapshot
            }

            let identity: String
            if let sourceID = sourceFeature.sourceID {
                guard !sourceID.isEmpty else { throw MapSourceLayerError.invalidVectorSnapshot }
                identity = sourceID
            } else {
                identity = "shapefile-record:\(sourceFeature.sourceOrdinal):sha256:\(sourceRevision.uppercased())"
            }
            identityCounts[identity, default: 0] += 1

            var partOrdinals = Set<Int>()
            var paths: [[MapPoint]] = []
            var sourcePaths: [[MapSourceCoordinate]] = []
            var pathIdentities: [String] = []
            for part in sourceFeature.parts {
                guard part.partOrdinal >= 0,
                      partOrdinals.insert(part.partOrdinal).inserted,
                      !part.vertices.isEmpty,
                      (definition.kind != .line || part.vertices.count >= 2),
                      (definition.kind != .polygon || part.vertices.count >= 3) else {
                    throw MapSourceLayerError.invalidVectorSnapshot
                }

                var projected: [MapPoint] = []
                var original: [MapSourceCoordinate] = []
                projected.reserveCapacity(part.vertices.count)
                original.reserveCapacity(part.vertices.count)
                for vertex in part.vertices {
                    guard vertex.x.isFinite, vertex.y.isFinite,
                          vertex.sourceX.isFinite, vertex.sourceY.isFinite,
                          vertex.z.map(\.isFinite) ?? true,
                          vertex.m.map(\.isFinite) ?? true else {
                        throw MapSourceLayerError.invalidVectorSnapshot
                    }
                    projected.append(.init(x: vertex.x, y: vertex.y))
                    original.append(.init(x: vertex.sourceX, y: vertex.sourceY,
                                          z: vertex.z, m: vertex.m))
                }
                if definition.kind == .point && (sourceFeature.parts.count != 1 || part.vertices.count != 1) {
                    throw MapSourceLayerError.invalidVectorSnapshot
                }
                paths.append(projected)
                sourcePaths.append(original)
                pathIdentities.append("\(identity)|part:\(part.partOrdinal)")
            }

            let attributes = try sourceFeature.attributes.sorted { $0.columnOrdinal < $1.columnOrdinal }
                .enumerated().map { index, attribute -> MapSourceAttributeColumn in
                    guard attribute.columnOrdinal == index else {
                        throw MapSourceLayerError.invalidVectorSnapshot
                    }
                    return .init(ordinal: attribute.columnOrdinal, name: attribute.columnName,
                                 value: try attribute.typedValue())
                }
            var displayAttributes: [String: String] = [:]
            for attribute in attributes {
                displayAttributes[attribute.name] = Self.displayString(attribute.value)
            }
            let feature = MapFeature(
                id: pending.count, kind: definition.kind, paths: paths, attributes: displayAttributes,
                stableIdentity: identity, pathStableIdentities: pathIdentities,
                hasUniqueStableIdentity: true, sourceFeatureIndex: sourceFeature.sourceOrdinal,
                geometryPath: "shape.parts", sourceCoordinatePaths: sourcePaths,
                sourceAttributes: Dictionary(attributes.map { ($0.name, $0.value) }, uniquingKeysWith: { _, last in last }),
                sourceAttributeColumns: attributes)
            pending.append((feature, identity))
        }

        let features = pending.map { item in
            let feature = item.feature
            return MapFeature(id: feature.id, kind: feature.kind, paths: feature.paths,
                attributes: feature.attributes, stableIdentity: feature.stableIdentity,
                pathStableIdentities: feature.pathStableIdentities,
                hasUniqueStableIdentity: identityCounts[item.identity] == 1,
                sourceFeatureIndex: feature.sourceFeatureIndex, geometryPath: feature.geometryPath,
                sourceCoordinatePaths: feature.sourceCoordinatePaths,
                sourceAttributes: feature.sourceAttributes,
                sourceAttributeColumns: feature.sourceAttributeColumns)
        }

        return MapVectorLayer(url: sourceURL, features: features, sourceMapID: sourceMapID,
                              sourceRevision: sourceRevision.uppercased(),
                              sourceProjectionWKT: data.sourceProjectionWKT,
                              targetProjectionWKT: data.targetProjectionWKT)
    }

    static func hasValidProjectionContract(_ data: MapVectorSourceData) -> Bool {
        func hasWKT(_ value: String?) -> Bool {
            value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        switch data.projectionStatus {
        case "projected":
            return hasWKT(data.sourceProjectionWKT) && hasWKT(data.targetProjectionWKT)
        case "localProjectSourceCoordinates":
            guard !hasWKT(data.targetProjectionWKT) else { return false }
            return data.features.allSatisfy { feature in
                feature.parts.allSatisfy { part in
                    part.vertices.allSatisfy { $0.x == $0.sourceX && $0.y == $0.sourceY }
                }
            }
        default:
            return false
        }
    }

    static func validateFamily(_ family: MapSourceFamilyCapture,
                               sourcePath: String,
                               sourceRevision: String) throws -> MapSourceFamilyCapture {
        let canonicalPath = SourceFilePaths.canonical(URL(fileURLWithPath: sourcePath))
        let sourceURL = URL(fileURLWithPath: canonicalPath)
        let baseURL = sourceURL.deletingPathExtension()
        let expectedFiles: [String: (URL, Bool)] = [
            "source": (sourceURL, true),
            "shx": (baseURL.appendingPathExtension("shx"), true),
            "dbf": (baseURL.appendingPathExtension("dbf"), true),
            "prj": (baseURL.appendingPathExtension("prj"), false)
        ]
        guard family.family == "shapefile",
              isSHA256(family.revision),
              SourceFilePaths.canonical(URL(fileURLWithPath: family.sourcePath)) == canonicalPath,
              family.files.count == 4,
              Set(family.files.map(\.role)) == Set(["source", "shx", "dbf", "prj"]),
              let sources = family.files.filter({ $0.role == "source" }).only,
              sources.required, sources.exists,
              sources.revision?.caseInsensitiveCompare(sourceRevision) == .orderedSame,
              SourceFilePaths.canonical(URL(fileURLWithPath: sources.path)) == canonicalPath,
              family.files.allSatisfy({ file in
                  guard let expected = expectedFiles[file.role] else { return false }
                  return !file.role.isEmpty && file.inputPath.hasPrefix("/") && file.path.hasPrefix("/")
                      && file.required == expected.1
                      && file.exists == (file.revision != nil)
                      && (!file.required || file.exists)
                      && (file.revision.map(Self.isSHA256) ?? true)
                      && SourceFilePaths.canonical(URL(fileURLWithPath: file.inputPath))
                          == SourceFilePaths.canonical(expected.0)
                      && SourceFilePaths.canonical(URL(fileURLWithPath: file.inputPath))
                          == SourceFilePaths.canonical(URL(fileURLWithPath: file.path))
              }),
              Set(family.files.map(\.role)) == Set(expectedFiles.keys),
              familyRevision(family).caseInsensitiveCompare(family.revision) == .orderedSame else {
            throw MapSourceLayerError.sourceChanged
        }
        return family
    }

    static func familyRevision(_ family: MapSourceFamilyCapture) -> String {
        var bytes = Data()
        append(family.family, to: &bytes)
        append(family.sourcePath, to: &bytes)
        for file in family.files {
            append(file.inputPath, to: &bytes)
            append(file.path, to: &bytes)
            append(file.role, to: &bytes)
            append(file.required ? "1" : "0", to: &bytes)
            append(file.exists ? "1" : "0", to: &bytes)
            append(file.revision ?? "", to: &bytes)
        }
        return SHA256.hash(data: bytes).map { String(format: "%02X", $0) }.joined()
    }

    private static func append(_ value: String, to bytes: inout Data) {
        let encoded = Data(value.utf8)
        var length = UInt32(encoded.count).bigEndian
        withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
        bytes.append(encoded)
    }

    static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }

    private static func displayString(_ value: MapSourceAttributeValue) -> String {
        switch value {
        case .null: ""
        case .string(let value), .integer(let value), .number(let value), .date(let value): value
        case .boolean(let value): String(value)
        case .binary(let value): value.base64EncodedString()
        }
    }
}

private extension Collection {
    var only: Element? {
        guard count == 1 else { return nil }
        return first
    }
}
