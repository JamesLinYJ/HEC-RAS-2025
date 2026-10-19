import Foundation
import RASWorkspaceCore

enum GdbMapSourceConverter {
    private struct GeometryComponent {
        let path: String
        let paths: [[GdbMapSourceVertex]]
        let pathSuffixes: [String]
    }

    private struct PendingFeature {
        let feature: MapFeature
        let identity: String
    }


    static func makeLayer(response: GdbMapSourceLoadResponse,
                          expectedMap: MapTreeMapIdentity,
                          expectedNode: CatalogTreeNodeLocator,
                          expectedNodeID: String,
                          expectedSource: GdbMapSourceIdentity,
                          expectedLayerName: String,
                          expectedLayer: GdbMapLayerDescriptor,
                          mapID: UUID) throws -> MapVectorLayer {
        let sourceURL = URL(fileURLWithPath: expectedSource.sourcePath).standardizedFileURL.resolvingSymlinksInPath()
        try expectedSource.validate(expectedPath: sourceURL)
        try expectedLayer.validate()
        guard response.node == expectedNode,
              response.layer == expectedLayer,
              response.source == expectedSource,
              response.map.isPersisted,
              response.map.projectPath.mapCanonicalPath == expectedMap.projectPath.mapCanonicalPath,
              response.map.projectXmlSHA?.caseInsensitiveCompare(expectedMap.projectXmlSHA) == .orderedSame,
              response.map.visualizationRevision?.caseInsensitiveCompare(expectedMap.expectedVisualizationRevision) == .orderedSame,
              response.map.mapID?.caseInsensitiveCompare(expectedMap.mapID) == .orderedSame,
              response.map.mapIndex == expectedMap.mapIndex,
              response.map.mapName == expectedMap.mapName,
              response.map.mapType == expectedMap.mapType,
              expectedNode.nodeType == "GdbVectorLayer",
              expectedNode.mapType == "GdbVectorLayer",
              !expectedNodeID.isEmpty,
              expectedNode.nodePath?.isEmpty == false,
              expectedLayerName == expectedLayer.name,
              expectedLayer.featureKind != nil else {
            throw GdbMapSourceError.mismatchedReply
        }

        let data = response.data
        // The payload names the normalized vector family; the descriptor also
        // carries the distinct raw OGR name and code, including Z/M dimensions.
        guard data.geometryType == expectedLayer.vectorType,
              data.geometryTypeCode == expectedLayer.geometryTypeCode,
              data.count >= 0, data.count == data.features.count,
              Int64(data.count) == expectedLayer.featureCount,
              data.extent.map(\.isFiniteAndOrdered) ?? true,
              data.sourceExtent.map(\.isFiniteAndOrdered) ?? true,
              validProjectionContract(data),
              let kind = expectedLayer.featureKind else {
            throw GdbMapSourceError.invalidGeometry
        }

        var sourceOrdinals = Set<Int>()
        var identityCounts: [String: Int] = [:]
        var pending: [PendingFeature] = []
        for sourceFeature in data.features {
            try Task.checkCancellation()
            guard sourceFeature.sourceOrdinal >= 0,
                  sourceOrdinals.insert(sourceFeature.sourceOrdinal).inserted,
                  sourceFeature.sourceID?.isEmpty != true else {
                throw GdbMapSourceError.invalidGeometry
            }
            let components = try geometryComponents(sourceFeature.geometry, kind: kind, path: "geometry")
            guard !components.isEmpty else { throw GdbMapSourceError.invalidGeometry }
            let attributes = try typedAttributes(sourceFeature.attributes)
            var displayAttributes: [String: String] = [:]
            for column in attributes.columns { displayAttributes[column.name] = Self.displayString(column.value) }

            let sourceToken: String
            if let sourceID = sourceFeature.sourceID {
                sourceToken = "source-id:\(sourceID.utf8.count):\(sourceID)"
            } else {
                sourceToken = "content:\(GdbMapSourceRevision.digest(identityBytes(for: sourceFeature)))"
            }
            let baseIdentity = "gdb-feature:\(GdbMapSourceRevision.digest(Data((SourceFilePaths.canonical(sourceURL) + "\u{1f}" + expectedLayer.name + "\u{1f}" + sourceToken).utf8)))"
            identityCounts[baseIdentity, default: 0] += 1
            for component in components {
                var projectedPaths: [[MapPoint]] = []
                var sourcePaths: [[MapSourceCoordinate]] = []
                projectedPaths.reserveCapacity(component.paths.count)
                sourcePaths.reserveCapacity(component.paths.count)
                for vertices in component.paths {
                    guard !vertices.isEmpty else { throw GdbMapSourceError.invalidGeometry }
                    projectedPaths.append(try vertices.map { vertex in
                        guard vertex.x.isFinite, vertex.y.isFinite,
                              vertex.sourceX.isFinite, vertex.sourceY.isFinite,
                              vertex.z.map(\.isFinite) ?? true,
                              vertex.m.map(\.isFinite) ?? true else { throw GdbMapSourceError.invalidGeometry }
                        return MapPoint(x: vertex.x, y: vertex.y)
                    })
                    sourcePaths.append(vertices.map { .init(x: $0.sourceX, y: $0.sourceY, z: $0.z, m: $0.m) })
                }
                guard projectedPaths.count == sourcePaths.count,
                      projectedPaths.count == component.pathSuffixes.count else {
                    throw GdbMapSourceError.invalidGeometry
                }
                let identity = baseIdentity + "|" + component.path
                let pathIDs = component.pathSuffixes.map { identity + "|" + $0 }
                pending.append(.init(feature: MapFeature(
                    id: pending.count, kind: kind, paths: projectedPaths, attributes: displayAttributes,
                    stableIdentity: identity, pathStableIdentities: pathIDs,
                    hasUniqueStableIdentity: true, sourceFeatureIndex: sourceFeature.sourceOrdinal,
                    geometryPath: component.path, sourceCoordinatePaths: sourcePaths,
                    sourceAttributes: attributes.dictionary, sourceAttributeColumns: attributes.columns),
                    identity: baseIdentity))
            }
        }

        let features = pending.map { item in
            let feature = item.feature
            return MapFeature(id: feature.id, kind: feature.kind, paths: feature.paths,
                attributes: feature.attributes, stableIdentity: feature.stableIdentity,
                pathStableIdentities: feature.pathStableIdentities,
                hasUniqueStableIdentity: identityCounts[item.identity] == 1,
                sourceFeatureIndex: feature.sourceFeatureIndex, geometryPath: feature.geometryPath,
                sourceCoordinatePaths: feature.sourceCoordinatePaths,
                sourceAttributes: feature.sourceAttributes, sourceAttributeColumns: feature.sourceAttributeColumns)
        }
        let nodeIdentity = "source-vector/\(mapID.uuidString)/\(expectedNodeID)"
        return MapVectorLayer(url: sourceURL, features: features, sourceMapID: mapID,
            sourceRevision: expectedSource.revision.uppercased(), visualIdentity: nodeIdentity,
            visualName: expectedLayer.name, sourceProjectionWKT: data.sourceProjectionWKT,
            targetProjectionWKT: data.targetProjectionWKT)
    }

    private static func geometryComponents(_ geometry: GdbMapSourceGeometry,
                                           kind: MapFeature.Kind,
                                           path: String) throws -> [GeometryComponent] {
        let type = geometry.geometryType.uppercased().filter { $0.isLetter }
        if isPointType(type) {
            guard kind == .point, geometry.vertices.count == 1,
                  geometry.rings.isEmpty, geometry.children.isEmpty else { throw GdbMapSourceError.invalidGeometry }
            return [.init(path: path, paths: [geometry.vertices], pathSuffixes: [path])]
        }
        if isLineType(type) {
            guard kind == .line, geometry.vertices.count >= 2,
                  geometry.rings.isEmpty, geometry.children.isEmpty else { throw GdbMapSourceError.invalidGeometry }
            return [.init(path: path, paths: [geometry.vertices], pathSuffixes: [path])]
        }
        if isPolygonType(type) {
            guard kind == .polygon, geometry.vertices.isEmpty, geometry.children.isEmpty,
                  !geometry.rings.isEmpty else { throw GdbMapSourceError.invalidGeometry }
            let exteriors = geometry.rings.filter { $0.role == "exterior" }
            guard exteriors.count == 1,
                  geometry.rings.allSatisfy({ $0.role == "exterior" || $0.role == "interior" }) else {
                throw GdbMapSourceError.invalidGeometry
            }
            for ring in geometry.rings {
                guard ring.vertices.count >= 4,
                      ring.vertices.first?.x == ring.vertices.last?.x,
                      ring.vertices.first?.y == ring.vertices.last?.y else { throw GdbMapSourceError.invalidGeometry }
            }
            let paths = geometry.rings.map(\.vertices)
            let suffixes = geometry.rings.enumerated().map { "\((path))/ring:\($0.element.role):\($0.offset)" }
            return [.init(path: path, paths: paths, pathSuffixes: suffixes)]
        }
        guard isCollectionType(type), geometry.vertices.isEmpty, geometry.rings.isEmpty,
              !geometry.children.isEmpty else { throw GdbMapSourceError.invalidGeometry }
        var components: [GeometryComponent] = []
        var aggregatePaths: [[GdbMapSourceVertex]] = []
        var aggregateSuffixes: [String] = []
        for (index, child) in geometry.children.enumerated() {
            let childPath = "\(path)/children[\(index)]"
            let values = try geometryComponents(child, kind: kind, path: childPath)
            if kind == .polygon {
                // Keep each exterior and its interior rings in an independent
                // even-odd path. Combining overlapping polygons would cancel
                // filled areas and lose source component identity.
                components.append(contentsOf: values)
            } else {
                for value in values {
                    aggregatePaths.append(contentsOf: value.paths)
                    aggregateSuffixes.append(contentsOf: value.pathSuffixes)
                }
            }
        }
        if kind != .polygon, !aggregatePaths.isEmpty {
            components.append(.init(path: path, paths: aggregatePaths, pathSuffixes: aggregateSuffixes))
        }
        guard !components.isEmpty else { throw GdbMapSourceError.invalidGeometry }
        return components
    }

    private static func isPointType(_ value: String) -> Bool { value == "POINT" }
    private static func isLineType(_ value: String) -> Bool { value == "LINESTRING" || value == "LINE" }
    private static func isPolygonType(_ value: String) -> Bool { value == "POLYGON" }
    private static func isCollectionType(_ value: String) -> Bool {
        ["POINTCOLLECTION", "LINECOLLECTION", "POLYGONCOLLECTION",
         "MULTIPOINT", "MULTILINESTRING", "MULTIPOLYGON", "GEOMETRYCOLLECTION",
         "MULTICURVE", "MULTISURFACE", "COMPOUNDCURVE", "CURVEPOLYGON"].contains(value)
    }

    private static func validProjectionContract(_ data: GdbMapSourceData) -> Bool {
        func hasWKT(_ value: String?) -> Bool { value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
        switch data.projectionStatus {
        case "projected": return hasWKT(data.sourceProjectionWKT) && hasWKT(data.targetProjectionWKT)
        case "localProjectSourceCoordinates":
            guard !hasWKT(data.targetProjectionWKT) else { return false }
            return data.features.allSatisfy { feature in
                allVertices(feature.geometry).allSatisfy { $0.x == $0.sourceX && $0.y == $0.sourceY }
            }
        default: return false
        }
    }

    private static func allVertices(_ geometry: GdbMapSourceGeometry) -> [GdbMapSourceVertex] {
        geometry.vertices + geometry.rings.flatMap(\.vertices) + geometry.children.flatMap(allVertices)
    }

    private static func identityBytes(for feature: GdbMapSourceFeature) -> Data {
        func field(_ value: String) -> String { "\(value.utf8.count):\(value)" }
        func vertex(_ value: GdbMapSourceVertex) -> String {
            [value.x, value.y, value.sourceX, value.sourceY].map { String($0.bitPattern, radix: 16) }
                .joined(separator: ",") + ":" + (value.z.map { String($0.bitPattern, radix: 16) } ?? "-")
                + ":" + (value.m.map { String($0.bitPattern, radix: 16) } ?? "-")
        }
        func geometry(_ value: GdbMapSourceGeometry) -> String {
            var parts = [field(value.geometryType), String(value.geometryTypeCode)]
            parts.append(contentsOf: value.vertices.map(vertex))
            for ring in value.rings {
                parts.append(field(ring.role))
                parts.append(contentsOf: ring.vertices.map(vertex))
            }
            parts.append(contentsOf: value.children.map(geometry))
            return parts.map(field).joined(separator: "|")
        }
        var parts = [geometry(feature.geometry)]
        parts.append(contentsOf: feature.attributes.sorted { $0.columnOrdinal < $1.columnOrdinal }.map { attribute in
            [String(attribute.columnOrdinal), field(attribute.columnName), field(attribute.type),
             field(attribute.value ?? "<null>"), attribute.booleanValue.map(String.init) ?? "<null>",
             String(attribute.isSet), String(attribute.isNull),
             attribute.timeZoneFlag.map(String.init) ?? "<null>"].joined(separator: "|")
        })
        return Data(parts.map(field).joined(separator: "\u{1e}").utf8)
    }

    private static func typedAttributes(_ source: [GdbMapSourceAttribute]) throws ->
        (columns: [MapSourceAttributeColumn], dictionary: [String: MapSourceAttributeValue]) {
        let ordered = source.sorted { $0.columnOrdinal < $1.columnOrdinal }
        guard ordered.enumerated().allSatisfy({ $0.element.columnOrdinal == $0.offset }) else {
            throw GdbMapSourceError.invalidGeometry
        }
        let columns = try ordered.map { attribute in
            let value = try typedValue(attribute)
            return MapSourceAttributeColumn(ordinal: attribute.columnOrdinal, name: attribute.columnName,
                value: value, sourceMetadata: MapSourceAttributeMetadata(sourceType: attribute.type,
                    rawLexeme: attribute.value, booleanValue: attribute.booleanValue,
                    isSet: attribute.isSet, isNull: attribute.isNull,
                    timeZoneFlag: attribute.timeZoneFlag))
        }
        return (columns, Dictionary(columns.map { ($0.name, $0.value) }, uniquingKeysWith: { _, last in last }))
    }

    private static func typedValue(_ attribute: GdbMapSourceAttribute) throws -> MapSourceAttributeValue {
        guard !attribute.columnName.isEmpty else { throw GdbMapSourceError.invalidGeometry }
        if !attribute.isSet {
            guard !attribute.isNull, attribute.value == nil, attribute.booleanValue == nil else {
                throw GdbMapSourceError.invalidGeometry
            }
            return .null
        }
        if attribute.isNull {
            guard attribute.value == nil, attribute.booleanValue == nil else {
                throw GdbMapSourceError.invalidGeometry
            }
            return .null
        }
        switch attribute.type.lowercased() {
        case "boolean":
            guard let value = attribute.booleanValue, attribute.value == nil else {
                throw GdbMapSourceError.invalidGeometry
            }
            return .boolean(value)
        case "integer", "int", "integer64", "long":
            guard attribute.booleanValue == nil, let value = attribute.value, Int64(value) != nil else {
                throw GdbMapSourceError.invalidGeometry
            }
            return .integer(value)
        case "real", "float", "double":
            guard attribute.booleanValue == nil, let value = attribute.value,
                  let number = Double(value), number.isFinite else { throw GdbMapSourceError.invalidGeometry }
            return .number(value)
        case "date", "time", "datetime":
            guard attribute.booleanValue == nil, let value = attribute.value, !value.isEmpty else {
                throw GdbMapSourceError.invalidGeometry
            }
            return .date(value)
        case "string", "widestring", "integerlist", "integer64list", "reallist", "stringlist", "widestringlist":
            guard attribute.booleanValue == nil, let value = attribute.value else {
                throw GdbMapSourceError.invalidGeometry
            }
            return .string(value)
        case "binary":
            guard attribute.booleanValue == nil, let value = attribute.value,
                  let bytes = Data(base64Encoded: value) else { throw GdbMapSourceError.invalidGeometry }
            return .binary(bytes)
        default:
            throw GdbMapSourceError.invalidGeometry
        }
    }

    private static func displayString(_ value: MapSourceAttributeValue) -> String {
        switch value {
        case .null: ""
        case .string(let text), .integer(let text), .number(let text), .date(let text): text
        case .boolean(let value): String(value)
        case .binary(let data): data.base64EncodedString()
        }
    }
}

private extension String {
    var mapCanonicalPath: String { SourceFilePaths.canonical(URL(fileURLWithPath: self)) }
}
