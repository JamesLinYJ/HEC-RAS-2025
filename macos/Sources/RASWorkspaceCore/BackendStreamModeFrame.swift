import Foundation

/// Re-playable owner reference for the exact source Tin stream record.
public struct BackendStreamModeTinAsset: Decodable, Equatable, Hashable, Sendable {
    public let sessionID: UUID
    public let sequence: Int64
    public let assetID: UUID
    public let sha256: String

    public init(sessionID: UUID, sequence: Int64, assetID: UUID, sha256: String) {
        self.sessionID = sessionID
        self.sequence = sequence
        self.assetID = assetID
        self.sha256 = sha256
    }
}

/// Coordinates copied from one retained Geospatial.Core streamable object.
public struct BackendStreamModeCoordinate: Decodable, Equatable, Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let z: Double?
    public let m: Double?

    public init(x: Double, y: Double, z: Double? = nil, m: Double? = nil) {
        self.x = x
        self.y = y
        self.z = z
        self.m = m
    }
}

/// One source object translated to native map paths and TIN triangles.
public struct BackendStreamModeFrame: Decodable, Equatable, Sendable {
    public let sequence: Int64
    public let objectType: String
    public let coordinateCount: Int
    public let coordinates: [BackendStreamModeCoordinate]
    public let paths: [[Int]]
    public let triangles: [[Int]]
    public let isClosed: Bool
    public let hasZ: Bool
    public let hasM: Bool
    public let zFillValue: Double?
    public let mFillValue: Double?
    public let tinAsset: BackendStreamModeTinAsset?

    public var id: Int64 { sequence }

    public init(sequence: Int64, objectType: String, coordinateCount: Int,
                coordinates: [BackendStreamModeCoordinate], paths: [[Int]],
                triangles: [[Int]], isClosed: Bool, hasZ: Bool = false, hasM: Bool = false,
                zFillValue: Double? = nil, mFillValue: Double? = nil,
                tinAsset: BackendStreamModeTinAsset? = nil) {
        self.sequence = sequence
        self.objectType = objectType
        self.coordinateCount = coordinateCount
        self.coordinates = coordinates
        self.paths = paths
        self.triangles = triangles
        self.isClosed = isClosed
        self.hasZ = hasZ
        self.hasM = hasM
        self.zFillValue = zFillValue
        self.mFillValue = mFillValue
        self.tinAsset = tinAsset
    }
}
