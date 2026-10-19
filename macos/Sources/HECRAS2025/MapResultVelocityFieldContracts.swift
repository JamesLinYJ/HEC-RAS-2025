import Foundation
import RASWorkspaceCore

enum MapVelocityFieldSourceKind: String, Sendable {
    case result
    case wind
    case liveResult
}

struct MapVelocityParticleProfile: Decodable, Equatable, Identifiable, Sendable {
    let index: Int
    let time: String
    var id: Int { index }
}

struct MapWindVelocityMapRequest: Encodable, Equatable, Sendable {
    let projectPath: String
    let projectXml: String
    let projectXmlSHA: String
    let mapID: String
    let mapIndex: Int
    let mapName: String
    let mapType: String
    let expectedVisualizationRevision: String
    let resultSelectionOverrides: [MapTreeResultSelectionOverride]
}

struct MapWindVelocityParticleSource: Equatable, Sendable {
    let projectSessionID: UUID
    let mapWorkflowIdentity: String
    let map: MapWindVelocityMapRequest
    let contextToken: String
    let selectionIdentity: String
    let boundaryNode: CatalogTreeNodeLocator
    let windNode: CatalogTreeNodeLocator
    let boundaryPath: String
    let boundaryRevision: String
    let profileIndex: Int
    let profileTime: String?
}

struct MapWindVelocityFieldRequest: Encodable, Sendable {
    let map: MapWindVelocityMapRequest
    let boundaryNode: CatalogTreeNodeLocator
    let windNode: CatalogTreeNodeLocator
    let expectedBoundaryPath: String
    let expectedBoundaryRevision: String
    let contextToken: String
    let requestID: String
    let profileIndex: Int
    let expectedProfileTime: String?
    let viewport: RasterMapViewExtent
}

struct MapWindVelocityFieldResponse: Decodable, Sendable {
    let requestID: String
    let contextToken: String
    let sourceID: String
    let sourceMapID: String
    let boundaryNode: CatalogTreeNodeLocator
    let windNode: CatalogTreeNodeLocator
    let boundaryPath: String
    let boundaryRevision: String
    let spatialDataType: String
    let profileIndex: Int
    let profileName: String
    let time: String
    let profiles: [MapVelocityParticleProfile]
    let width: Int
    let height: Int
    let cellSize: Double
    let minX: Double
    let minY: Double
    let maxX: Double
    let maxY: Double
    let noDataValue: Float?
    let interleavedVelocity: Data

    func makeGrid(expected: MapWindVelocityFieldExpectation) throws -> MapResultVelocityGrid {
        guard let bounds = MapVelocityRasterGeometry.normalizedBounds(expected.viewport, maximumSide: 384) else {
            throw BackendServiceError(code: "sourceChanged",
                message: "The Wind velocity reply no longer matches the selected map viewport.")
        }
        let canonicalPath = SourceFilePaths.canonical(URL(fileURLWithPath: boundaryPath))
        let expectedPath = SourceFilePaths.canonical(URL(fileURLWithPath: expected.boundaryPath))
        guard requestID == expected.requestID,
              contextToken == expected.contextToken,
              sourceID == expected.sourceID,
              UUID(uuidString: sourceMapID) == UUID(uuidString: expected.mapID),
              boundaryNode == expected.boundaryNode,
              windNode == expected.windNode,
              canonicalPath == expectedPath,
              boundaryRevision.caseInsensitiveCompare(expected.boundaryRevision) == .orderedSame,
              expected.profileIndex == profileIndex, profileIndex >= 0,
              ["Constant", "Gridded"].contains(spatialDataType),
              expected.spatialDataType.map({ spatialDataType == $0 }) ?? true,
              !profileName.isEmpty, !time.isEmpty,
              expected.profileTime.map({ $0 == time }) ?? true,
              profiles.indices.allSatisfy({ profiles[$0].index == $0 }),
              profileIndex < profiles.count,
              profiles[profileIndex].time == time,
              width == bounds.width,
              height == bounds.height,
              MapVelocityRasterGeometry.approximately(minX, bounds.minX),
              MapVelocityRasterGeometry.approximately(minY, bounds.minY),
              MapVelocityRasterGeometry.approximately(maxX, bounds.maxX),
              MapVelocityRasterGeometry.approximately(maxY, bounds.maxY),
              MapVelocityRasterGeometry.approximately(cellSize, bounds.cellSize),
              [minX, minY, maxX, maxY].allSatisfy(\.isFinite),
              minX < maxX, minY < maxY,
              noDataValue.map(\.isFinite) ?? true else {
            throw BackendServiceError(code: "sourceChanged",
                message: "The Wind velocity reply no longer matches the selected map, source, profile, or viewport.")
        }
        let (cellCount, overflowCells) = width.multipliedReportingOverflow(by: height)
        let (valueCount, overflowValues) = cellCount.multipliedReportingOverflow(by: 3)
        let (byteCount, overflowBytes) = valueCount.multipliedReportingOverflow(by: MemoryLayout<Float>.size)
        guard !overflowCells, !overflowValues, !overflowBytes,
              width > 0, height > 0, !interleavedVelocity.isEmpty,
              interleavedVelocity.count == byteCount else {
            throw BackendServiceError(code: "protocolFailure",
                message: "The Wind velocity reply has invalid sample dimensions.")
        }
        var velocityX: [Float] = []; velocityX.reserveCapacity(cellCount)
        var velocityY: [Float] = []; velocityY.reserveCapacity(cellCount)
        var magnitude: [Float] = []; magnitude.reserveCapacity(cellCount)
        for index in 0..<cellCount {
            let offset = index * 12
            velocityX.append(Self.readFloat(interleavedVelocity, at: offset))
            velocityY.append(Self.readFloat(interleavedVelocity, at: offset + 4))
            magnitude.append(Self.readFloat(interleavedVelocity, at: offset + 8))
        }
        return MapResultVelocityGrid(width: width, height: height, cellSize: cellSize,
            minX: minX, minY: minY, maxX: maxX, maxY: maxY,
            noDataValue: noDataValue, velocityX: velocityX, velocityY: velocityY,
            magnitude: magnitude, resultPath: nil, revision: nil,
            terrainPath: nil, terrainRevision: nil, sourceID: sourceID,
            profileIndex: profileIndex, profileName: profileName, time: time,
            sourceKind: .wind, runID: nil, spatialDataType: spatialDataType,
            profileOptions: profiles)
    }

    private static func readFloat(_ data: Data, at offset: Int) -> Float {
        let bits = UInt32(data[offset]) | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
        return Float(bitPattern: bits)
    }

}

struct MapWindVelocityFieldExpectation: Sendable {
    let requestID: String
    let contextToken: String
    let sourceID: String
    let mapID: String
    let boundaryNode: CatalogTreeNodeLocator
    let windNode: CatalogTreeNodeLocator
    let boundaryPath: String
    let boundaryRevision: String
    let profileIndex: Int
    let profileTime: String?
    let spatialDataType: String?
    let viewport: RasterMapViewExtent
}

struct MapResultVelocityFieldRequest: Encodable, Sendable {
    let map: MapResultChartMapRequest
    let selectionOverrides: [MapResultSelectionOverride]
    let contextToken: String
    let node: CatalogTreeNodeLocator
    let requestID: String
    let expectedResultPath: String
    let expectedResultRevision: String
    let profileIndex: Int
    let viewport: RasterMapViewExtent
}

struct MapResultVelocityFieldResponse: Decodable, Sendable {
    let requestID: String
    let contextToken: String
    let sourceID: String
    let sourceMapID: String
    let node: CatalogTreeNodeLocator
    let resultPath: String
    let revision: String
    let resultName: String
    let terrainPath: String
    let terrainRevision: String
    let mapType: String
    let selectionIndex: Int
    let profileIndex: Int
    let profileName: String
    let time: String
    let width: Int
    let height: Int
    let cellSize: Double
    let minX: Double
    let minY: Double
    let maxX: Double
    let maxY: Double
    let noDataValue: Float
    let interleavedVelocity: Data

    func makeGrid(expected: MapResultVelocityFieldExpectation) throws -> MapResultVelocityGrid {
        guard let expectedRaster = MapVelocityRasterGeometry.normalizedBounds(expected.viewport, maximumSide: 384) else {
            throw BackendServiceError(code: "sourceChanged",
                message: "The velocity field reply no longer matches the selected Result map, profile, or viewport.")
        }
        guard requestID == expected.requestID,
              contextToken == expected.contextToken,
              sourceID == expected.sourceID,
              sourceMapID.caseInsensitiveCompare(expected.mapID) == .orderedSame,
              node == expected.node,
              Self.canonical(resultPath) == Self.canonical(expected.resultPath),
              revision.caseInsensitiveCompare(expected.resultRevision) == .orderedSame,
              mapType == "Velocity", selectionIndex == 0,
              profileIndex == expected.profileIndex,
              profileName == expected.profileName, time == expected.time,
              width == expectedRaster.width,
              height == expectedRaster.height,
              MapVelocityRasterGeometry.approximately(minX, expectedRaster.minX),
              MapVelocityRasterGeometry.approximately(minY, expectedRaster.minY),
              MapVelocityRasterGeometry.approximately(maxX, expectedRaster.maxX),
              MapVelocityRasterGeometry.approximately(maxY, expectedRaster.maxY),
              MapVelocityRasterGeometry.approximately(cellSize, expectedRaster.cellSize),
              [minX, minY, maxX, maxY].allSatisfy(\.isFinite),
              minX < maxX, minY < maxY,
              noDataValue.isFinite else {
            throw BackendServiceError(code: "sourceChanged",
                message: "The velocity field reply no longer matches the selected Result map, profile, or viewport.")
        }
        guard Self.isSHA256(terrainRevision) else {
            throw BackendServiceError(code: "protocolFailure",
                message: "The velocity field reply has an invalid terrain revision.")
        }
        let (cellCount, overflowCells) = width.multipliedReportingOverflow(by: height)
        let (valueCount, overflowValues) = cellCount.multipliedReportingOverflow(by: 3)
        let (byteCount, overflowBytes) = valueCount.multipliedReportingOverflow(by: MemoryLayout<Float>.size)
        guard !overflowCells, !overflowValues, !overflowBytes,
              width > 0, height > 0, interleavedVelocity.count == byteCount else {
            throw BackendServiceError(code: "protocolFailure",
                message: "The velocity field reply has invalid sample dimensions.")
        }

        var velocityX: [Float] = []; velocityX.reserveCapacity(cellCount)
        var velocityY: [Float] = []; velocityY.reserveCapacity(cellCount)
        var magnitude: [Float] = []; magnitude.reserveCapacity(cellCount)
        for index in 0..<cellCount {
            let offset = index * 12
            velocityX.append(Self.readFloat(interleavedVelocity, at: offset))
            velocityY.append(Self.readFloat(interleavedVelocity, at: offset + 4))
            magnitude.append(Self.readFloat(interleavedVelocity, at: offset + 8))
        }
        return MapResultVelocityGrid(width: width, height: height, cellSize: cellSize,
            minX: minX, minY: minY, maxX: maxX, maxY: maxY,
            noDataValue: noDataValue, velocityX: velocityX,
            velocityY: velocityY, magnitude: magnitude,
            resultPath: resultPath, revision: revision,
            terrainPath: terrainPath, terrainRevision: terrainRevision,
            sourceID: sourceID, profileIndex: profileIndex, profileName: profileName, time: time,
            sourceKind: .result, runID: nil)
    }

    private static func readFloat(_ data: Data, at offset: Int) -> Float {
        let bits = UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
        return Float(bitPattern: bits)
    }

    private static func canonical(_ path: String) -> String {
        SourceFilePaths.canonical(URL(fileURLWithPath: path))
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }
}

struct MapResultVelocityFieldExpectation: Sendable {
    let requestID: String
    let contextToken: String
    let sourceID: String
    let mapID: String
    let node: CatalogTreeNodeLocator
    let resultPath: String
    let resultRevision: String
    let profileIndex: Int
    let profileName: String
    let time: String
    let viewport: RasterMapViewExtent
}

struct MapResultVelocityGrid: Sendable {
    let width: Int
    let height: Int
    let cellSize: Double
    let minX: Double
    let minY: Double
    let maxX: Double
    let maxY: Double
    let noDataValue: Float?
    let velocityX: [Float]
    let velocityY: [Float]
    let magnitude: [Float]
    let resultPath: String?
    let revision: String?
    let terrainPath: String?
    let terrainRevision: String?
    let sourceID: String
    let profileIndex: Int
    let profileName: String
    let time: String
    let sourceKind: MapVelocityFieldSourceKind
    let runID: String?
    let spatialDataType: String?
    let profileOptions: [MapVelocityParticleProfile]

    init(width: Int, height: Int, cellSize: Double, minX: Double, minY: Double,
         maxX: Double, maxY: Double, noDataValue: Float?, velocityX: [Float],
         velocityY: [Float], magnitude: [Float], resultPath: String?, revision: String?,
         terrainPath: String?, terrainRevision: String?, sourceID: String,
         profileIndex: Int, profileName: String, time: String,
         sourceKind: MapVelocityFieldSourceKind = .result, runID: String? = nil,
         spatialDataType: String? = nil, profileOptions: [MapVelocityParticleProfile] = []) {
        self.width = width; self.height = height; self.cellSize = cellSize
        self.minX = minX; self.minY = minY; self.maxX = maxX; self.maxY = maxY
        self.noDataValue = noDataValue; self.velocityX = velocityX; self.velocityY = velocityY
        self.magnitude = magnitude; self.resultPath = resultPath; self.revision = revision
        self.terrainPath = terrainPath; self.terrainRevision = terrainRevision
        self.sourceID = sourceID; self.profileIndex = profileIndex
        self.profileName = profileName; self.time = time; self.sourceKind = sourceKind
        self.runID = runID; self.spatialDataType = spatialDataType
        self.profileOptions = profileOptions
    }
}
