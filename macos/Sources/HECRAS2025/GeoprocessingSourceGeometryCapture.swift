import CryptoKit
import Foundation
import RASWorkspaceCore

/// Re-reads the exact source geometry paths used by the active vector loader
/// before a polygon operation.  This keeps GeoJSON Z/M ordinates that the map
/// renderer intentionally projects away, while Shapefile XY remains in the
/// map's target projection and its retained source Z/M is copied from the
/// checked source snapshot.
enum GeoprocessingSourceGeometryCapture {
    private struct Ring: Sendable {
        let coordinates: [[Double]]
        let zValues: [String]?
        let mValues: [String]?
    }

    static func polygons(from layer: MapVectorLayer,
                         selectedFeatureIdentities: Set<String>? = nil) throws -> [GeoprocessingSourcePolygon] {
        guard let expectedRevision = layer.sourceRevision,
              isSHA256(expectedRevision),
              layer.url.isFileURL,
              layer.url.path.hasPrefix("/") else {
            throw CaptureError.invalidSource
        }
        let canonicalURL = URL(fileURLWithPath: SourceFilePaths.canonical(layer.url))
        let before = try Data(contentsOf: canonicalURL, options: [.mappedIfSafe])
        guard sha256(before).caseInsensitiveCompare(expectedRevision) == .orderedSame else {
            throw CaptureError.sourceChanged
        }

        let isShapefile = layer.url.pathExtension.caseInsensitiveCompare("shp") == .orderedSame
        let root: Any? = isShapefile ? nil : try JSONSerialization.jsonObject(with: before, options: [.fragmentsAllowed])
        var result: [GeoprocessingSourcePolygon] = []

        for feature in layer.features where feature.kind == .polygon {
            guard feature.hasUniqueStableIdentity,
                  selectedFeatureIdentities.map({ $0.contains(feature.stableIdentity) }) ?? true,
                  !feature.paths.isEmpty,
                  feature.paths.allSatisfy({ $0.count >= 4 && $0.first == $0.last }) else {
                if selectedFeatureIdentities?.contains(feature.stableIdentity) == true {
                    throw CaptureError.invalidGeometry
                }
                continue
            }

            let rings: [Ring]
            if isShapefile {
                guard let sourcePaths = feature.sourceCoordinatePaths,
                      sourcePaths.count == feature.paths.count else {
                    throw CaptureError.invalidGeometry
                }
                rings = try feature.paths.indices.map { index in
                    let mapPath = feature.paths[index]
                    let sourcePath = sourcePaths[index]
                    guard mapPath.count == sourcePath.count else { throw CaptureError.invalidGeometry }
                    return Ring(coordinates: mapPath.map { [$0.x, $0.y] },
                                zValues: try ordinates(sourcePath, dimension: \.z),
                                mValues: try ordinates(sourcePath, dimension: \.m))
                }
            } else {
                guard let root, let geometryPath = feature.geometryPath else { throw CaptureError.invalidGeometry }
                let sourceFeatureIndex = feature.sourceFeatureIndex ?? 0
                let sourceRings = try geoJSONRings(root: root, featureIndex: sourceFeatureIndex,
                                                   geometryPath: geometryPath)
                guard sourceRings.count == feature.paths.count else { throw CaptureError.invalidGeometry }
                rings = try sourceRings.enumerated().map { index, positions in
                    let mapped = feature.paths[index]
                    guard positions.count == mapped.count,
                          zip(positions, mapped).allSatisfy({ pair in
                              pair.0[0] == pair.1.x && pair.0[1] == pair.1.y
                          }) else { throw CaptureError.geometryChanged }
                    let z = try optionalOrdinate(positions, index: 2)
                    let m = try optionalOrdinate(positions, index: 3)
                    return Ring(coordinates: positions.map { [$0[0], $0[1]] }, zValues: z, mValues: m)
                }
            }

            let components = try polygonComponents(rings)
            for component in components {
                let pathIdentity = feature.pathStableIdentities.indices.contains(component.outerIndex)
                    ? feature.pathStableIdentities[component.outerIndex]
                    : "\(feature.stableIdentity)|ring:\(component.outerIndex)"
                let outer = rings[component.outerIndex]
                let holes = component.holeIndices.map { rings[$0] }
                result.append(GeoprocessingSourcePolygon(
                    featureIdentity: feature.stableIdentity,
                    pathIdentity: pathIdentity,
                    sourceFeatureIndex: feature.sourceFeatureIndex ?? feature.id,
                    pathIndex: component.outerIndex,
                    coordinates: outer.coordinates,
                    zValues: outer.zValues,
                    mValues: outer.mValues,
                    holes: holes.map(\.coordinates),
                    holeZValues: holes.map(\.zValues),
                    holeMValues: holes.map(\.mValues)))
            }
        }

        let identities = result.map(\.pathIdentity)
        guard Set(identities).count == identities.count else { throw CaptureError.invalidGeometry }
        let after = try Data(contentsOf: canonicalURL, options: [.mappedIfSafe])
        guard sha256(after).caseInsensitiveCompare(expectedRevision) == .orderedSame,
              sha256(after) == sha256(before) else { throw CaptureError.sourceChanged }
        return result
    }

    private struct Component {
        let outerIndex: Int
        let holeIndices: [Int]
    }

    /// Shapefile polygon records may contain several outer rings.  Assign
    /// each ring to its smallest containing parent, then emit even-depth rings
    /// as separate polygons with only their direct odd-depth children as
    /// holes.  This preserves islands nested inside holes as separate solids.
    private static func polygonComponents(_ rings: [Ring]) throws -> [Component] {
        guard !rings.isEmpty else { throw CaptureError.invalidGeometry }
        let areas = rings.map { abs(signedArea($0.coordinates)) }
        guard areas.allSatisfy({ $0.isFinite && $0 > 0 }) else { throw CaptureError.invalidGeometry }
        var parent = Array<Int?>(repeating: nil, count: rings.count)
        for child in rings.indices {
            let probe = rings[child].coordinates[0]
            let candidates = rings.indices.filter { candidate in
                candidate != child && areas[candidate] > areas[child]
                    && contains(probe, ring: rings[candidate].coordinates)
            }
            parent[child] = candidates.min { areas[$0] < areas[$1] }
        }

        func depth(of index: Int, visiting: Set<Int> = []) throws -> Int {
            guard !visiting.contains(index) else { throw CaptureError.invalidGeometry }
            guard let next = parent[index] else { return 0 }
            return try 1 + depth(of: next, visiting: visiting.union([index]))
        }

        let depths = try rings.indices.map { try depth(of: $0) }
        return rings.indices.filter { depths[$0].isMultiple(of: 2) }.map { outer in
            let holes = rings.indices.filter { parent[$0] == outer && depths[$0] == depths[outer] + 1 }
            return Component(outerIndex: outer, holeIndices: holes)
        }
    }

    private static func geoJSONRings(root: Any, featureIndex: Int, geometryPath: String) throws -> [[[Double]]] {
        let featureObject: [String: Any]?
        if let document = root as? [String: Any], document["type"] as? String == "FeatureCollection" {
            guard let features = document["features"] as? [[String: Any]],
                  features.indices.contains(featureIndex) else { throw CaptureError.invalidGeometry }
            featureObject = features[featureIndex]
        } else if let document = root as? [String: Any], document["type"] as? String == "Feature" {
            guard featureIndex == 0 else { throw CaptureError.invalidGeometry }
            featureObject = document
        } else {
            guard featureIndex == 0 else { throw CaptureError.invalidGeometry }
            featureObject = nil
        }

        var node: Any
        if let featureObject {
            guard let geometry = featureObject["geometry"], !(geometry is NSNull) else {
                throw CaptureError.invalidGeometry
            }
            node = geometry
        } else {
            node = root
        }

        guard geometryPath == "geometry" || geometryPath.hasPrefix("geometry.") else {
            throw CaptureError.invalidGeometry
        }
        let suffix = geometryPath == "geometry" ? "" : String(geometryPath.dropFirst("geometry".count))
        for token in try pathTokens(suffix) {
            switch token {
            case .key(let key):
                guard let object = node as? [String: Any], let next = object[key] else {
                    throw CaptureError.invalidGeometry
                }
                node = next
            case .index(let index):
                guard let array = node as? [Any], array.indices.contains(index) else {
                    throw CaptureError.invalidGeometry
                }
                node = array[index]
            }
        }
        if let object = node as? [String: Any] {
            guard let coordinates = object["coordinates"] else { throw CaptureError.invalidGeometry }
            node = coordinates
        }
        guard let rawRings = node as? [Any] else { throw CaptureError.invalidGeometry }
        return try rawRings.map { rawRing in
            guard let positions = rawRing as? [Any] else { throw CaptureError.invalidGeometry }
            let parsed = try positions.map(parsePosition)
            guard parsed.count >= 4, parsed.first?[0] == parsed.last?[0], parsed.first?[1] == parsed.last?[1] else {
                throw CaptureError.invalidGeometry
            }
            return parsed
        }
    }

    private enum PathToken { case key(String), index(Int) }

    private static func pathTokens(_ path: String) throws -> [PathToken] {
        let chars = Array(path)
        var index = 0
        var tokens: [PathToken] = []
        while index < chars.count {
            if chars[index] == "." {
                index += 1
                let start = index
                while index < chars.count && chars[index] != "." && chars[index] != "[" { index += 1 }
                guard start < index else { throw CaptureError.invalidGeometry }
                tokens.append(.key(String(chars[start..<index])))
            } else if chars[index] == "[" {
                index += 1
                let start = index
                while index < chars.count && chars[index].isNumber { index += 1 }
                guard start < index, index < chars.count, chars[index] == "]",
                      let value = Int(String(chars[start..<index])) else { throw CaptureError.invalidGeometry }
                index += 1
                tokens.append(.index(value))
            } else {
                throw CaptureError.invalidGeometry
            }
        }
        return tokens
    }

    private static func parsePosition(_ value: Any) throws -> [Double] {
        guard let array = value as? [NSNumber], array.count >= 2, array.count <= 4 else {
            throw CaptureError.invalidGeometry
        }
        let coordinates = array.map(\.doubleValue)
        guard coordinates.allSatisfy(\.isFinite) else { throw CaptureError.invalidGeometry }
        return coordinates
    }

    private static func optionalOrdinate(_ positions: [[Double]], index: Int) throws -> [String]? {
        let present = positions.map { $0.count > index }
        guard present.contains(true) else { return nil }
        guard present.allSatisfy({ $0 }) else { throw CaptureError.mixedDimensions }
        return positions.map { String($0[index]) }
    }

    private static func ordinates(_ points: [MapSourceCoordinate],
                                  dimension: KeyPath<MapSourceCoordinate, Double?>) throws -> [String]? {
        let values = points.map { $0[keyPath: dimension] }
        guard values.contains(where: { $0 != nil }) else { return nil }
        guard values.allSatisfy({ $0?.isFinite == true }) else { throw CaptureError.mixedDimensions }
        return values.compactMap { $0 }.map { String($0) }
    }

    private static func signedArea(_ ring: [[Double]]) -> Double {
        guard ring.count >= 4 else { return 0 }
        var total = 0.0
        for index in 0..<(ring.count - 1) {
            total += ring[index][0] * ring[index + 1][1] - ring[index + 1][0] * ring[index][1]
        }
        return total / 2
    }

    private static func contains(_ point: [Double], ring: [[Double]]) -> Bool {
        var inside = false
        for index in 0..<(ring.count - 1) {
            let a = ring[index], b = ring[index + 1]
            let cross = (point[0] - a[0]) * (b[1] - a[1]) - (point[1] - a[1]) * (b[0] - a[0])
            if abs(cross) <= 1e-12,
               point[0] >= min(a[0], b[0]), point[0] <= max(a[0], b[0]),
               point[1] >= min(a[1], b[1]), point[1] <= max(a[1], b[1]) { return false }
            if (a[1] > point[1]) != (b[1] > point[1]),
               point[0] < (b[0] - a[0]) * (point[1] - a[1]) / (b[1] - a[1]) + a[0] {
                inside.toggle()
            }
        }
        return inside
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }

    private enum CaptureError: LocalizedError {
        case invalidSource, sourceChanged, invalidGeometry, geometryChanged, mixedDimensions

        var errorDescription: String? {
            switch self {
            case .invalidSource: "The polygon source does not have a verified identity."
            case .sourceChanged: "The polygon source changed while its original coordinates were captured."
            case .invalidGeometry: "The polygon source has invalid ring identities or coordinates."
            case .geometryChanged: "The map polygon no longer matches its original source geometry path."
            case .mixedDimensions: "Polygon rings with inconsistent Z or M dimensions cannot be processed safely."
            }
        }
    }
}
