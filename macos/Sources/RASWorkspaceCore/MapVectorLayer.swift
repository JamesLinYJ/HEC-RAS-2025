import CryptoKit
import CoreFoundation
import Foundation

public struct MapPoint: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// A source vertex kept alongside its XY drawing coordinate. Shapefile readers
/// may expose Z/M ordinates that do not participate in the native 2D map
/// projection; retaining them here prevents a renderer adapter from silently
/// discarding source data.
public struct MapSourceCoordinate: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let z: Double?
    public let m: Double?

    public init(x: Double, y: Double, z: Double? = nil, m: Double? = nil) {
        self.x = x; self.y = y; self.z = z; self.m = m
    }

    public var mapPoint: MapPoint { MapPoint(x: x, y: y) }
}

/// Typed source attributes from formats such as a Shapefile DBF table. Numeric
/// values keep their source lexeme so downstream inspection can preserve
/// precision even though conditional map styling may parse them numerically.
public enum MapSourceAttributeValue: Hashable, Sendable {
    case null
    case string(String)
    case integer(String)
    case number(String)
    case boolean(Bool)
    case date(String)
    case binary(Data)
}

/// One field in the original source table. The ordinal is retained because
/// DBF schemas may contain duplicate column names; a dictionary keyed by name
/// cannot faithfully represent those tables.
public struct MapSourceAttributeColumn: Hashable, Sendable {
    public let ordinal: Int
    public let name: String
    public let value: MapSourceAttributeValue
    /// Optional source-format provenance for formats whose table semantics
    /// distinguish an unset cell from an explicit NULL or preserve a declared
    /// type/lexeme that cannot be represented by the legacy display value.
    public let sourceMetadata: MapSourceAttributeMetadata?

    public init(ordinal: Int, name: String, value: MapSourceAttributeValue,
                sourceMetadata: MapSourceAttributeMetadata? = nil) {
        self.ordinal = ordinal
        self.name = name
        self.value = value
        self.sourceMetadata = sourceMetadata
    }
}

/// Exact source-column state retained alongside the display-compatible value.
/// `rawLexeme` is intentionally a String so Integer64 and other source numbers
/// do not lose precision through a native Double conversion.
public struct MapSourceAttributeMetadata: Hashable, Sendable {
    public let sourceType: String
    public let rawLexeme: String?
    public let booleanValue: Bool?
    public let isSet: Bool
    public let isNull: Bool
    public let timeZoneFlag: Int?

    public init(sourceType: String, rawLexeme: String? = nil, booleanValue: Bool? = nil,
                isSet: Bool, isNull: Bool, timeZoneFlag: Int? = nil) {
        self.sourceType = sourceType
        self.rawLexeme = rawLexeme
        self.booleanValue = booleanValue
        self.isSet = isSet
        self.isNull = isNull
        self.timeZoneFlag = timeZoneFlag
    }
}

public struct MapFeature: Identifiable, Sendable {
    public enum Kind: String, CaseIterable, Equatable, Hashable, Sendable {
        case point = "point"
        case line = "line"
        case polygon = "polygon"
    }
    public let id: Int
    public let kind: Kind
    public let paths: [[MapPoint]]
    public let attributes: [String: String]
    /// Stable source identity. Unlike `id`, this does not depend on feature order.
    public let stableIdentity: String
    /// Each independent geometry component gets its own identity. In particular,
    /// MultiLineString paths stay separate and can be selected independently.
    public let pathStableIdentities: [String]
    /// False when source identities collide and therefore cannot safely route edits.
    public let hasUniqueStableIdentity: Bool
    /// Source feature ordinal is a navigation hint only; stable IDs never use it.
    public let sourceFeatureIndex: Int?
    /// Geometry path inside the source feature, such as `geometry.geometries[0]`.
    public let geometryPath: String?
    /// Optional source coordinates aligned one-to-one with `paths` and each
    /// path's vertices. The renderer uses `paths`; this value preserves the
    /// original coordinate dimensions and Z/M ordinates.
    public let sourceCoordinatePaths: [[MapSourceCoordinate]]?
    /// Optional typed DBF/source attributes. The legacy `attributes` property
    /// remains the display-compatible string projection.
    public let sourceAttributes: [String: MapSourceAttributeValue]?
    /// Ordered source fields, including duplicate names and null-valued cells.
    public let sourceAttributeColumns: [MapSourceAttributeColumn]?

    public init(id: Int, kind: Kind, paths: [[MapPoint]], attributes: [String: String],
                stableIdentity: String? = nil, pathStableIdentities: [String] = [],
                hasUniqueStableIdentity: Bool = true, sourceFeatureIndex: Int? = nil,
                geometryPath: String? = nil,
                sourceCoordinatePaths: [[MapSourceCoordinate]]? = nil,
                sourceAttributes: [String: MapSourceAttributeValue]? = nil,
                sourceAttributeColumns: [MapSourceAttributeColumn]? = nil) {
        self.id = id; self.kind = kind; self.paths = paths; self.attributes = attributes
        self.stableIdentity = stableIdentity ?? "legacy-feature:\(id)"
        self.pathStableIdentities = pathStableIdentities.isEmpty
            ? paths.indices.map { "legacy-feature:\(id):path:\($0)" } : pathStableIdentities
        self.hasUniqueStableIdentity = hasUniqueStableIdentity
        self.sourceFeatureIndex = sourceFeatureIndex; self.geometryPath = geometryPath
        self.sourceCoordinatePaths = sourceCoordinatePaths; self.sourceAttributes = sourceAttributes
        self.sourceAttributeColumns = sourceAttributeColumns
    }
}

public struct MapVectorLayer: Identifiable, Sendable {
    public let url: URL
    public let features: [MapFeature]
    public let sourceMapID: UUID?
    public let sourceRevision: String?
    public let visualIdentity: String?
    public let visualName: String?
    public let isSourceVisible: Bool
    public let sourceProjectionWKT: String?
    public let targetProjectionWKT: String?
    public var id: String { visualIdentity ?? url.standardizedFileURL.path }
    public var name: String { visualName ?? url.deletingPathExtension().lastPathComponent }
    public var points: [MapPoint] { features.flatMap { $0.paths.flatMap { $0 } } }

    /// Construct source-backed layers with the file SHA and map association.
    public init(url: URL, features: [MapFeature], sourceMapID: UUID? = nil, sourceRevision: String? = nil,
                visualIdentity: String? = nil, visualName: String? = nil, isSourceVisible: Bool = true,
                sourceProjectionWKT: String? = nil, targetProjectionWKT: String? = nil) {
        self.url = url; self.features = features; self.sourceMapID = sourceMapID; self.sourceRevision = sourceRevision
        self.visualIdentity = visualIdentity; self.visualName = visualName; self.isSourceVisible = isSourceVisible
        self.sourceProjectionWKT = sourceProjectionWKT; self.targetProjectionWKT = targetProjectionWKT
    }

    /// Creates the display instance for one persisted map node while keeping
    /// the original source URL, revision and per-feature source identities.
    /// The canonical-path precondition prevents a stale or misrouted binding
    /// from silently displaying the contents of a different file.
    public func instanced(binding: MapVectorInstanceBinding, sourceMapID: UUID) -> MapVectorLayer {
        precondition(SourceFilePaths.canonical(url) == binding.sourcePath,
                     "A vector instance must bind to the physical source file it references.")
        return MapVectorLayer(
            url: url,
            features: features.filter { $0.kind == binding.kind },
            sourceMapID: sourceMapID,
            sourceRevision: sourceRevision,
            visualIdentity: binding.id,
            visualName: binding.name,
            isSourceVisible: binding.isVisible,
            sourceProjectionWKT: sourceProjectionWKT, targetProjectionWKT: targetProjectionWKT
        )
    }

    public init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url), sourceURL: url)
    }

    public init(data: Data, sourceURL url: URL) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProjectFileError.invalid("The map layer is not a GeoJSON object.")
        }
        var result: [MapFeature] = []
        var identityCounts: [String: Int] = [:]

        func digest(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
        }
        func jsonIdentity(_ object: [String: Any]) -> String {
            if let value = object["id"] {
                if let string = value as? String { return "geojson-id:string:" + digest(Data(string.utf8)) }
                if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                    return "geojson-id:number:" + digest(Data(number.stringValue.utf8))
                }
            }
            let bytes = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])) ?? Data()
            return "geojson-content:" + digest(bytes)
        }
        func coordinate(_ value: Any) throws -> MapPoint {
            guard let array = value as? [NSNumber], array.count >= 2,
                  array[0].doubleValue.isFinite, array[1].doubleValue.isFinite else {
                throw ProjectFileError.invalid("The map layer contains an invalid coordinate.")
            }
            return MapPoint(x: array[0].doubleValue, y: array[1].doubleValue)
        }
        func line(_ value: Any) throws -> [MapPoint] {
            guard let array = value as? [Any] else { throw ProjectFileError.invalid("The map layer contains an invalid coordinate list.") }
            return try array.map(coordinate)
        }
        func polygon(_ value: Any) throws -> [[MapPoint]] {
            guard let array = value as? [Any] else { throw ProjectFileError.invalid("The map layer contains invalid polygon rings.") }
            return try array.map { value in
                let ring = try line(value)
                guard ring.count >= 4, ring.first == ring.last else { throw ProjectFileError.invalid("GeoJSON polygon rings must have at least four coordinates and be closed.") }
                return ring
            }
        }
        func add(kind: MapFeature.Kind, paths: [[MapPoint]], attributes: [String: String], identity: String,
                 pathIdentities: [String], sourceFeatureIndex: Int?, geometryPath: String) {
            result.append(MapFeature(id: result.count, kind: kind, paths: paths, attributes: attributes,
                stableIdentity: identity, pathStableIdentities: pathIdentities,
                sourceFeatureIndex: sourceFeatureIndex, geometryPath: geometryPath))
            identityCounts[identity, default: 0] += 1
        }
        func geometry(_ object: [String: Any], attributes: [String: String], featureIdentity: String,
                      sourceFeatureIndex: Int?, geometryPath: String) throws {
            let coordinates = object["coordinates"] ?? []
            let identity = featureIdentity + "|" + geometryPath
            switch object["type"] as? String {
            case "Point":
                add(kind: .point, paths: [[try coordinate(coordinates)]], attributes: attributes, identity: identity, pathIdentities: [identity + ":coordinates[0]"], sourceFeatureIndex: sourceFeatureIndex, geometryPath: geometryPath)
            case "MultiPoint":
                let points = try line(coordinates)
                for (index, point) in points.enumerated() {
                    let pathID = identity + ":coordinates[\(index)]"
                    add(kind: .point, paths: [[point]], attributes: attributes, identity: pathID, pathIdentities: [pathID], sourceFeatureIndex: sourceFeatureIndex, geometryPath: geometryPath + ".coordinates[\(index)]")
                }
            case "LineString":
                add(kind: .line, paths: [try line(coordinates)], attributes: attributes, identity: identity, pathIdentities: [identity + ":coordinates[0]"], sourceFeatureIndex: sourceFeatureIndex, geometryPath: geometryPath)
            case "MultiLineString":
                guard let lines = coordinates as? [Any] else { throw ProjectFileError.invalid("Invalid MultiLineString.") }
                let paths = try lines.map(line)
                let pathIDs = paths.indices.map { identity + ":coordinates[\($0)]" }
                add(kind: .line, paths: paths, attributes: attributes, identity: identity, pathIdentities: pathIDs, sourceFeatureIndex: sourceFeatureIndex, geometryPath: geometryPath)
            case "Polygon":
                let paths = try polygon(coordinates)
                let pathIDs = paths.indices.map { identity + ":coordinates[\($0)]" }
                add(kind: .polygon, paths: paths, attributes: attributes, identity: identity, pathIdentities: pathIDs, sourceFeatureIndex: sourceFeatureIndex, geometryPath: geometryPath)
            case "MultiPolygon":
                guard let polygons = coordinates as? [Any] else { throw ProjectFileError.invalid("Invalid MultiPolygon.") }
                for (index, value) in polygons.enumerated() {
                    let paths = try polygon(value)
                    let polygonIdentity = identity + ":coordinates[\(index)]"
                    let pathIDs = paths.indices.map { polygonIdentity + ":ring[\($0)]" }
                    add(kind: .polygon, paths: paths, attributes: attributes, identity: polygonIdentity, pathIdentities: pathIDs, sourceFeatureIndex: sourceFeatureIndex, geometryPath: geometryPath + ".coordinates[\(index)]")
                }
            case "GeometryCollection":
                guard let items = object["geometries"] as? [[String: Any]] else { throw ProjectFileError.invalid("Invalid GeometryCollection.") }
                for (index, item) in items.enumerated() {
                    try geometry(item, attributes: attributes, featureIdentity: featureIdentity, sourceFeatureIndex: sourceFeatureIndex,
                        geometryPath: geometryPath + ".geometries[\(index)]")
                }
            default: throw ProjectFileError.invalid("The GeoJSON geometry type is unsupported or missing.")
            }
        }
        func feature(_ object: [String: Any], sourceFeatureIndex: Int?) throws {
            guard let value = object["geometry"], !(value is NSNull) else { return }
            guard let shape = value as? [String: Any] else { throw ProjectFileError.invalid("Invalid feature geometry.") }
            let attributes = (object["properties"] as? [String: Any] ?? [:]).mapValues { value in
                if value is NSNull { return "" }
                if let string = value as? String { return string }
                return String(describing: value)
            }
            try geometry(shape, attributes: attributes, featureIdentity: jsonIdentity(object), sourceFeatureIndex: sourceFeatureIndex, geometryPath: "geometry")
        }
        switch root["type"] as? String {
        case "FeatureCollection":
            guard let items = root["features"] as? [[String: Any]] else { throw ProjectFileError.invalid("Invalid FeatureCollection.") }
            for (index, item) in items.enumerated() { try feature(item, sourceFeatureIndex: index) }
        case "Feature": try feature(root, sourceFeatureIndex: 0)
        default:
            let identity = "geojson-content:" + digest((try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .fragmentsAllowed])) ?? Data())
            try geometry(root, attributes: [:], featureIdentity: identity, sourceFeatureIndex: nil, geometryPath: "geometry")
        }
        for index in result.indices {
            let feature = result[index]
            result[index] = MapFeature(id: feature.id, kind: feature.kind, paths: feature.paths,
                attributes: feature.attributes, stableIdentity: feature.stableIdentity,
                pathStableIdentities: feature.pathStableIdentities,
                hasUniqueStableIdentity: identityCounts[feature.stableIdentity, default: 0] == 1,
                sourceFeatureIndex: feature.sourceFeatureIndex, geometryPath: feature.geometryPath,
                sourceCoordinatePaths: feature.sourceCoordinatePaths,
                sourceAttributes: feature.sourceAttributes,
                sourceAttributeColumns: feature.sourceAttributeColumns)
        }
        self.init(url: url, features: result, sourceRevision: digest(data))
    }
}
