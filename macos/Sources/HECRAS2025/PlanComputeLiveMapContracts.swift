import Foundation
import RASWorkspaceCore

struct PlanComputeLiveMapTarget: Encodable, Sendable, Equatable {
    let targetID: String
    let projectSessionID: String
    let operationOwnerToken: String
    let operationContextID: String
    let runID: String
    let projectPath: String
    let projectRevision: String
    let projectXmlFingerprint: String
    let planPath: String
    let planRevision: String
    let map: MapResultChartMapRequest
    let contextToken: String
    let nodeID: String
    let node: CatalogTreeNodeLocator
    let selectionIndex: Int
    let selectionMode: String
    let selectedResultPath: String?
    let profileIndex: Int
    let profileTime: String?
    let outputBlockName: String
    let selectedMapType: String
    let viewport: RasterMapViewExtent
    var captureVelocityParticles = false
    var profileName: String? = nil
}

enum PlanComputeLiveMapTargetUpdate: Sendable, Equatable {
    case replace([PlanComputeLiveMapTarget])
    case cancel
}

struct PlanComputeLiveMapControl: Encodable, Sendable {
    let type: String
    let targets: [PlanComputeLiveMapTarget]?

    static func replaceTargets(_ targets: [PlanComputeLiveMapTarget]) -> Self {
        .init(type: "targets", targets: targets)
    }
    static let cancel = Self(type: "cancel", targets: nil)
}

struct PlanComputeLiveMapFrame: Decodable, Sendable {
    let targetID: String
    let projectSessionID: String
    let operationOwnerToken: String
    let operationContextID: String
    let runID: String
    let resultPath: String
    let outputBlockName: String
    let contextToken: String
    let mapID: String
    let nodeID: String
    let selectionIndex: Int
    let targetSequence: UInt64
    let profileIndex: Int
    let profileName: String
    let time: String
    let mapType: String
    let terrainPath: String
    let terrainRevision: String
    let units: String
    let width: Int
    let height: Int
    let rgba: Data
    let minX: Double
    let minY: Double
    let maxX: Double
    let maxY: Double
    let noDataValue: Float
    let legendStops: [MapResultRenderLegendStop]

    func makeLayer(expectedMapID: UUID) throws -> MapRasterLayer {
        guard UUID(uuidString: mapID) == expectedMapID else {
            throw BackendServiceError(code: "sourceChanged", message: "The live result frame belongs to a different map.")
        }
        return try MapRasterLayer(id: "live|\(targetID)|\(runID)|\(selectionIndex)|\(profileIndex)|\(targetSequence)",
            name: profileName + " · " + mapType, width: width, height: height, rgba: rgba,
            lowerLeft: MapPoint(x: minX, y: minY), upperRight: MapPoint(x: maxX, y: maxY),
            sourceMapID: expectedMapID)
    }

    var legend: MapLegend {
        let count = legendStops.count
        return MapLegend(id: "live|\(targetID)|\(runID)|\(selectionIndex)|\(profileIndex)|\(targetSequence)",
            title: profileName + " · " + mapType, units: units,
            stops: legendStops.enumerated().map { index, stop in
                MapLegend.Stop(id: "live|\(targetID)|\(runID)|\(selectionIndex)|\(profileIndex)|\(index)",
                    position: count <= 1 ? 1 : Double(index) / Double(count - 1),
                    color: stop.color,
                    label: stop.value.formatted(.number.precision(.significantDigits(1...4))))
            })
    }
}

struct PlanComputeLiveVelocityFrame: Decodable, Sendable {
    let targetID: String
    let projectSessionID: String
    let operationOwnerToken: String
    let operationContextID: String
    let runID: String
    let resultPath: String
    let outputBlockName: String
    let contextToken: String
    let mapID: String
    let nodeID: String
    let selectionIndex: Int
    let targetSequence: UInt64
    let profileIndex: Int
    let profileName: String
    let time: String
    let mapType: String
    let width: Int
    let height: Int
    let cellSize: Double
    let minX: Double
    let minY: Double
    let maxX: Double
    let maxY: Double
    let noDataValue: Float
    let interleavedVelocity: Data

    func makeGrid(expected: MapResultVelocityParticleTargetIdentity,
                  expectedResultPath: String, expectedOutputBlockName: String) throws -> MapResultVelocityGrid {
        guard let bounds = MapVelocityRasterGeometry.normalizedBounds(expected.viewport,
                maximumSide: 384) else {
            throw BackendServiceError(code: "sourceChanged",
                message: "The live velocity frame no longer matches the active map viewport.")
        }
        let actualPath = SourceFilePaths.canonical(URL(fileURLWithPath: resultPath))
        let stablePath = SourceFilePaths.canonical(URL(fileURLWithPath: expectedResultPath))
        guard expected.sourceKind == .liveResult,
              expected.targetID == targetID,
              UUID(uuidString: expected.projectSessionID.uuidString) == UUID(uuidString: projectSessionID),
              expected.runID == runID,
              expected.contextToken == contextToken,
              UUID(uuidString: expected.mapID.uuidString) == UUID(uuidString: mapID),
              expected.nodeID == nodeID, selectionIndex == 0,
              expected.profileIndex == profileIndex,
              expected.profileName.isEmpty || expected.profileName == profileName,
              expected.time.isEmpty || expected.time == time,
              actualPath == stablePath,
              outputBlockName == expectedOutputBlockName,
              mapType == "Velocity",
              noDataValue.isFinite,
              width == bounds.width, height == bounds.height,
              [minX, minY, maxX, maxY, cellSize].allSatisfy(\.isFinite),
              minX < maxX, minY < maxY,
              MapVelocityRasterGeometry.approximately(minX, bounds.minX),
              MapVelocityRasterGeometry.approximately(minY, bounds.minY),
              MapVelocityRasterGeometry.approximately(maxX, bounds.maxX),
              MapVelocityRasterGeometry.approximately(maxY, bounds.maxY),
              MapVelocityRasterGeometry.approximately(cellSize, bounds.cellSize) else {
            throw BackendServiceError(code: "sourceChanged",
                message: "The live velocity frame no longer matches the active Result, profile, or viewport.")
        }
        let (cellCount, cellOverflow) = width.multipliedReportingOverflow(by: height)
        let (valueCount, valueOverflow) = cellCount.multipliedReportingOverflow(by: 3)
        let (byteCount, byteOverflow) = valueCount.multipliedReportingOverflow(by: MemoryLayout<Float>.size)
        guard !cellOverflow, !valueOverflow, !byteOverflow,
              width > 0, height > 0, interleavedVelocity.count == byteCount else {
            throw BackendServiceError(code: "protocolFailure",
                message: "The live velocity frame has invalid raster dimensions.")
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
            terrainPath: nil, terrainRevision: nil, sourceID: nodeID,
            profileIndex: profileIndex, profileName: profileName, time: time,
            sourceKind: .liveResult, runID: runID)
    }

    private static func readFloat(_ data: Data, at offset: Int) -> Float {
        let bits = UInt32(data[offset]) | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
        return Float(bitPattern: bits)
    }
}

struct PlanComputeLiveVelocityUnavailable: Decodable, Sendable {
    let targetID: String
    let projectSessionID: String
    let operationOwnerToken: String
    let operationContextID: String
    let runID: String
    let resultPath: String
    let outputBlockName: String
    let contextToken: String
    let mapID: String
    let nodeID: String
    let selectionIndex: Int
    let targetSequence: UInt64
    let message: String
}

struct PlanComputeDuplexEvent: Decodable, Sendable {
    let fraction: Double?
    let message: String?
    let taskName: String?
    let values: [String: String]?
    let resultCompute: BackendResultComputeUpdate?
    let resultProfiles: BackendResultProfilesUpdate?
    let liveMapFrame: PlanComputeLiveMapFrame?
    let liveVelocityFrame: PlanComputeLiveVelocityFrame?
    let liveVelocityUnavailable: PlanComputeLiveVelocityUnavailable?

    var progress: BackendProgressUpdate {
        BackendProgressUpdate(fraction: fraction, message: message, taskName: taskName,
            values: values, resultCompute: resultCompute, resultProfiles: resultProfiles)
    }
}

struct PlanComputeDuplexUpdate: Sendable {
    let progress: BackendProgressUpdate
    let liveMapFrame: PlanComputeLiveMapFrame?
    var liveVelocityFrame: PlanComputeLiveVelocityFrame? = nil
    var liveVelocityUnavailable: PlanComputeLiveVelocityUnavailable? = nil
}

enum MapVelocityRasterGeometry {
    static func boundedViewport(_ viewport: RasterMapViewExtent, maximumSide: Int = 384)
        -> RasterMapViewExtent? {
        guard let bounds = normalizedBounds(viewport, maximumSide: maximumSide) else { return nil }
        return RasterMapViewExtent(minX: viewport.minX, minY: viewport.minY,
            maxX: viewport.maxX, maxY: viewport.maxY,
            pixelWidth: bounds.width, pixelHeight: bounds.height)
    }

    static func normalizedBounds(_ viewport: RasterMapViewExtent, maximumSide: Int? = nil)
        -> (cellSize: Double, minX: Double, minY: Double, maxX: Double, maxY: Double, width: Int, height: Int)? {
        guard [viewport.minX, viewport.minY, viewport.maxX, viewport.maxY].allSatisfy(\.isFinite),
              viewport.minX < viewport.maxX, viewport.minY < viewport.maxY,
              viewport.pixelWidth > 0, viewport.pixelHeight > 0 else { return nil }
        let width: Int
        let height: Int
        if let maximumSide {
            let scale = min(1, Double(maximumSide) / Double(max(viewport.pixelWidth, viewport.pixelHeight)))
            width = max(1, Int(floor(Double(viewport.pixelWidth) * scale)))
            height = max(1, Int(floor(Double(viewport.pixelHeight) * scale)))
        } else {
            width = viewport.pixelWidth
            height = viewport.pixelHeight
        }
        let cellSize = max((viewport.maxX - viewport.minX) / Double(width),
                           (viewport.maxY - viewport.minY) / Double(height))
        let maxX = viewport.minX + Double(width) * cellSize
        let minY = viewport.maxY - Double(height) * cellSize
        guard cellSize.isFinite, cellSize > 0, maxX.isFinite, minY.isFinite else { return nil }
        return (cellSize, viewport.minX, minY, maxX, viewport.maxY, width, height)
    }

    static func approximately(_ actual: Double, _ expected: Double) -> Bool {
        actual.isFinite && expected.isFinite
            && abs(actual - expected) <= max(1e-9, abs(expected) * 1e-12)
    }
}
