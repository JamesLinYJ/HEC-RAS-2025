import CoreGraphics
import Foundation
import RASWorkspaceCore

enum RasterRGBExportRegion: String, CaseIterable, Hashable, Identifiable, Sendable {
    case currentView = "CurrentView"
    case fullLayer = "FullLayer"

    var id: String { rawValue }

    @MainActor
    var title: String {
        switch self {
        case .currentView: L10n.text("Current View")
        case .fullLayer: L10n.text("Full Layer Extent")
        }
    }
}

struct RasterRGBExportPlotOptionChoice: Decodable, Equatable, Sendable, Identifiable {
    let value: String
    let label: String
    var id: String { value }
}

struct RasterRGBExportPlotOption: Decodable, Equatable, Sendable, Identifiable {
    let propertyName: String
    let name: String
    let label: String
    let description: String
    let kind: String
    let value: String
    let enumValues: [RasterRGBExportPlotOptionChoice]
    let isEnabled: Bool
    let enabledIf: String?
    var id: String { propertyName }
    var isBoolean: Bool { kind == "bool" }
}

struct RasterRGBExportInspection: Decodable, Sendable {
    let sourceID: String
    let sourceName: String
    let sourceRevision: String
    let visualizationRevision: String
    let fullMinX: Double
    let fullMinY: Double
    let fullMaxX: Double
    let fullMaxY: Double
    let currentView: RasterMapViewExtent?
    let suggestedCellSize: Double?
    let plotOptions: [RasterRGBExportPlotOption]
}

struct RasterRGBExportRasterPayload: Decodable, Sendable {
    let id: String
    let sourceMapID: String?
    let name: String
    let width: Int
    let height: Int
    let rgba: Data
    let minX: Double
    let minY: Double
    let maxX: Double
    let maxY: Double

    var image: CGImage? {
        let (count, overflow) = width.multipliedReportingOverflow(by: height)
        let (bytes, byteOverflow) = count.multipliedReportingOverflow(by: 4)
        let (rowBytes, rowOverflow) = width.multipliedReportingOverflow(by: 4)
        guard width > 0, height > 0, !overflow, !byteOverflow, !rowOverflow,
              rgba.count == bytes,
              let provider = CGDataProvider(data: rgba as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: rowBytes, space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

struct RasterRGBExportPreview: Decodable, Sendable {
    let sourceID: String
    let sourceRevision: String
    let visualizationRevision: String
    let cellSize: Double
    let minX: Double
    let minY: Double
    let maxX: Double
    let maxY: Double
    let outputWidth: Int
    let outputHeight: Int
    let estimatedFileSizeBytes: Int64
    let raster: RasterRGBExportRasterPayload
}

struct ExportArtifactReceipt: Decodable, Equatable, Sendable, Identifiable {
    let path: String
    let sizeBytes: Int64
    let sha256: String
    var id: String { path }
}

struct RasterRGBExportExecutionResult: Decodable, Sendable {
    let state: String
    let outputPath: String?
    let sourceID: String
    let sourceRevision: String
    let visualizationRevision: String
    let cellSize: Double
    let width: Int
    let height: Int
    let minX: Double
    let minY: Double
    let maxX: Double
    let maxY: Double
    let artifacts: [ExportArtifactReceipt]
}

struct DepthShapefileExportProfile: Decodable, Equatable, Sendable, Identifiable {
    let index: Int
    let name: String
    let time: String
    var id: Int { index }
}

struct DepthShapefileExportOwner: Decodable, Equatable, Sendable, Identifiable {
    let node: CatalogTreeNodeLocator
    let nodeKind: String
    let name: String
    let selectionIndex: Int
    let resultPath: String
    let resultRevision: String
    let resultName: String
    let currentProfileIndex: Int?
    let profiles: [DepthShapefileExportProfile]

    var id: String {
        [MapResultSelectionOverride(node: node, mode: .latest).nodeIdentity,
         Self.canonical(resultPath), resultRevision.uppercased(), String(selectionIndex)]
            .joined(separator: "|")
    }

    var canExport: Bool {
        selectionIndex == 0 && (nodeKind == "Result" || nodeKind == "MultiResult")
            && (node.nodeType == "Result" || node.nodeType == "MultiResult")
            && !resultPath.isEmpty && !resultRevision.isEmpty && !profiles.isEmpty
    }

    private static func canonical(_ path: String) -> String {
        SourceFilePaths.canonical(URL(fileURLWithPath: path))
    }
}

struct DepthShapefileExportInspection: Decodable, Sendable {
    let mapID: String
    let contextToken: String
    let defaultCellSize: Double
    let defaultSimplifyDistance: Double
    let owners: [DepthShapefileExportOwner]
}

struct DepthShapefileExportPreview: Decodable, Sendable {
    let mapID: String
    let contextToken: String
    let resultNode: CatalogTreeNodeLocator
    let selectionIndex: Int
    let resultPath: String
    let resultRevision: String
    let profileIndex: Int
    let profileName: String
    let profileTime: String
    let viewport: RasterMapViewExtent
    let cellSize: Double
    let simplifyDistance: Double
    let resultRaster: MapResultRenderLayerPayload?
    let polygons: [[GeometryTopologyCoordinate]]
    let polylines: [[GeometryTopologyCoordinate]]
}

struct DepthShapefileExportExecutionResult: Decodable, Sendable {
    let state: String
    let outputPath: String?
    let mapID: String
    let contextToken: String
    let resultNode: CatalogTreeNodeLocator
    let selectionIndex: Int
    let resultPath: String
    let resultRevision: String
    let profileIndex: Int
    let profileName: String
    let profileTime: String
    let cellSize: Double
    let simplifyDistance: Double
    let polygonCount: Int
    let artifacts: [ExportArtifactReceipt]
}

/// `MapTreeRequest` intentionally differs from the Result chart map request:
/// the depth writer needs the exact map-tree ResultSelection and compute lease
/// used by source Geometry/Boundary reads.
struct ResultExportMapTreeRequest: Encodable, Equatable, Sendable {
    let projectPath: String
    let projectXml: String
    let projectXmlSHA: String
    let mapID: String
    let mapIndex: Int
    let mapName: String
    let mapType: String
    let expectedVisualizationRevision: String
    let resultSelectionOverrides: [MapTreeResultSelectionOverride]
    let computeReadLease: MapResultComputeReadLease?

    init(map: MapResultChartMapRequest, treeContext: LayerTreeContext) {
        projectPath = map.projectPath
        projectXml = map.projectXml
        projectXmlSHA = map.projectXmlSHA
        mapID = map.mapID
        mapIndex = map.mapIndex
        mapName = map.mapName
        mapType = map.mapType
        expectedVisualizationRevision = map.expectedVisualizationRevision
        resultSelectionOverrides = treeContext.resultSelectionOverrides
        computeReadLease = map.computeReadLease
    }
}

struct RasterRGBExportCapture: Equatable, Sendable {
    let projectSessionID: UUID
    let mapID: UUID
    let mapWorkflowIdentity: String
    let source: RasterMapSourceDescriptor
    let projectXml: String
    let currentView: RasterMapViewExtent?
}

struct DepthShapefileExportCapture: Equatable, Sendable {
    let projectSessionID: UUID
    let mapID: UUID
    let mapWorkflowIdentity: String
    let map: MapResultChartMapRequest
    let mapTree: ResultExportMapTreeRequest
    let resultSnapshot: MapResultSourcesSnapshot
    let selectionOverrides: [MapResultSelectionOverride]
    let contextToken: String
    let viewport: RasterMapViewExtent?
}

struct DepthShapefileExportSelection: Equatable, Sendable {
    private(set) var ownerID: String?
    private(set) var profileIndex: Int?

    init(ownerID: String? = nil, profileIndex: Int? = nil) {
        self.ownerID = ownerID
        self.profileIndex = profileIndex
    }

    mutating func selectOwner(_ owner: DepthShapefileExportOwner?) {
        guard let owner, owner.canExport else {
            ownerID = nil
            profileIndex = nil
            return
        }
        ownerID = owner.id
        profileIndex = owner.profiles.contains(where: { $0.index == owner.currentProfileIndex })
            ? owner.currentProfileIndex : nil
    }

    mutating func selectProfile(_ index: Int?, for owners: [DepthShapefileExportOwner]) {
        guard let ownerID,
              let owner = owners.first(where: { $0.id == ownerID }),
              let index, owner.profiles.contains(where: { $0.index == index }) else {
            profileIndex = nil
            return
        }
        profileIndex = index
    }

    mutating func retainExactOwner(in owners: [DepthShapefileExportOwner]) {
        guard let ownerID, let owner = owners.first(where: { $0.id == ownerID && $0.canExport }) else {
            self.ownerID = nil
            profileIndex = nil
            return
        }
        if let profileIndex, owner.profiles.contains(where: { $0.index == profileIndex }) { return }
        profileIndex = owner.profiles.contains(where: { $0.index == owner.currentProfileIndex })
            ? owner.currentProfileIndex : nil
    }
}

enum ResultExportReplyValidation {
    static func rasterInspection(_ reply: RasterRGBExportInspection,
                                 source: RasterMapSourceDescriptor) throws {
        guard reply.sourceID == source.id,
              reply.visualizationRevision.caseInsensitiveCompare(source.visualizationRevision) == .orderedSame,
              source.sourceRevision.map({ reply.sourceRevision.caseInsensitiveCompare($0) == .orderedSame }) ?? true,
              finiteExtent(reply.fullMinX, reply.fullMinY, reply.fullMaxX, reply.fullMaxY),
              reply.plotOptions.allSatisfy({ option in
                  !option.propertyName.isEmpty && !option.name.isEmpty
                      && (option.kind == "bool" || option.kind == "enum")
                      && (option.isBoolean || option.enumValues.contains(where: { $0.value == option.value }))
              }), Set(reply.plotOptions.map(\.propertyName)).count == reply.plotOptions.count else {
            throw protocolFailure("The RGB export inspection does not match the selected raster.")
        }
        if let suggested = reply.suggestedCellSize,
           !suggested.isFinite || suggested <= 0 {
            throw protocolFailure("The RGB export returned an invalid cell size.")
        }
    }

    static func rasterPreview(_ reply: RasterRGBExportPreview,
                              capture: RasterRGBExportCapture,
                              inspection: RasterRGBExportInspection,
                              region: RasterRGBExportRegion,
                              cellSize: Double) throws {
        let source = capture.source
        let expectedMapID = source.sourceMapID
        guard let expectedBounds = expectedExportBounds(inspection: inspection,
            currentView: capture.currentView, region: region) else {
            throw protocolFailure("The RGB preview region does not overlap the selected raster.")
        }
        let (pixelCount, pixelOverflow) = reply.raster.width.multipliedReportingOverflow(by: reply.raster.height)
        let (byteCount, byteOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        guard reply.sourceID == source.id,
              reply.sourceRevision.caseInsensitiveCompare(inspection.sourceRevision) == .orderedSame,
              reply.visualizationRevision.caseInsensitiveCompare(inspection.visualizationRevision) == .orderedSame,
              reply.cellSize == cellSize,
              finiteExtent(reply.minX, reply.minY, reply.maxX, reply.maxY),
              sameExtent(reply.minX, reply.minY, reply.maxX, reply.maxY, expectedBounds),
              reply.outputWidth > 0, reply.outputHeight > 0,
              reply.estimatedFileSizeBytes > 0,
              reply.raster.id == source.id,
              (expectedMapID == nil
                  ? reply.raster.sourceMapID == nil
                  : UUID(uuidString: reply.raster.sourceMapID ?? "") == expectedMapID),
              reply.raster.width > 0, reply.raster.height > 0,
              !pixelOverflow, !byteOverflow, reply.raster.rgba.count == byteCount,
              finiteExtent(reply.raster.minX, reply.raster.minY,
                           reply.raster.maxX, reply.raster.maxY),
              sameExtent(reply.raster.minX, reply.raster.minY,
                         reply.raster.maxX, reply.raster.maxY, expectedBounds),
              (region != .currentView || capture.currentView != nil) else {
            throw protocolFailure("The RGB preview no longer matches the selected raster and export region.")
        }
    }

    static func rasterExecution(_ reply: RasterRGBExportExecutionResult,
                                capture: RasterRGBExportCapture,
                                inspection: RasterRGBExportInspection,
                                outputPath: String, cellSize: Double) throws {
        guard reply.sourceID == capture.source.id,
              reply.sourceRevision.caseInsensitiveCompare(inspection.sourceRevision) == .orderedSame,
              reply.visualizationRevision.caseInsensitiveCompare(inspection.visualizationRevision) == .orderedSame,
              reply.cellSize == cellSize else {
            throw protocolFailure("The RGB export receipt does not match its captured raster.")
        }
        if reply.state == "cancelled" {
            guard reply.outputPath == nil, reply.artifacts.isEmpty else {
                throw protocolFailure("The cancelled RGB export unexpectedly returned output files.")
            }
            return
        }
        guard reply.state == "completed", let returnedPath = reply.outputPath,
              samePath(returnedPath, outputPath), reply.width > 0, reply.height > 0,
              finiteExtent(reply.minX, reply.minY, reply.maxX, reply.maxY),
              reply.artifacts.count == 1,
              let artifact = reply.artifacts.first,
              samePath(artifact.path, outputPath), artifact.sizeBytes > 0,
              isSHA256(artifact.sha256) else {
            throw protocolFailure("The RGB export completed without a matching TIFF receipt.")
        }
    }

    static func depthInspection(_ reply: DepthShapefileExportInspection,
                                capture: DepthShapefileExportCapture) throws {
        guard reply.mapID.caseInsensitiveCompare(capture.map.mapID) == .orderedSame,
              reply.contextToken == capture.contextToken,
              reply.defaultCellSize.isFinite, reply.defaultCellSize > 0,
              reply.defaultSimplifyDistance.isFinite, reply.defaultSimplifyDistance >= 0,
              reply.owners.allSatisfy({ owner in
                  owner.canExport && owner.profiles.map(\.index) == owner.profiles.map(\.index).sorted()
                      && Set(owner.profiles.map(\.index)).count == owner.profiles.count
                      && owner.profiles.allSatisfy({ $0.index >= 0 && !$0.time.isEmpty })
                      && (owner.currentProfileIndex.map { index in
                          owner.profiles.contains(where: { $0.index == index })
                      } ?? true)
              }), Set(reply.owners.map(\.id)).count == reply.owners.count else {
            throw protocolFailure("The depth export owners do not match the active Result context.")
        }
    }

    static func depthPreview(_ reply: DepthShapefileExportPreview,
                             capture: DepthShapefileExportCapture,
                             owner: DepthShapefileExportOwner,
                             profile: DepthShapefileExportProfile,
                             cellSize: Double, simplifyDistance: Double) throws {
        guard reply.mapID.caseInsensitiveCompare(capture.map.mapID) == .orderedSame,
              reply.contextToken == capture.contextToken,
              reply.resultNode == owner.node, reply.selectionIndex == 0,
              samePath(reply.resultPath, owner.resultPath),
              reply.resultRevision.caseInsensitiveCompare(owner.resultRevision) == .orderedSame,
              reply.profileIndex == profile.index,
              reply.profileName == profile.name, reply.profileTime == profile.time,
              reply.viewport == capture.viewport,
              reply.cellSize == cellSize, reply.simplifyDistance == simplifyDistance,
              reply.polygons.allSatisfy({ $0.count >= 3 && $0.allSatisfy(isFinite) }),
              reply.polylines.allSatisfy({ $0.count >= 2 && $0.allSatisfy(isFinite) }) else {
            throw protocolFailure("The depth contour preview belongs to a different map, Result, profile, or viewport.")
        }
        if let raster = reply.resultRaster {
            let (count, overflow) = raster.width.multipliedReportingOverflow(by: raster.height)
            let (bytes, byteOverflow) = count.multipliedReportingOverflow(by: 4)
            guard raster.sourceMapID.caseInsensitiveCompare(capture.map.mapID) == .orderedSame,
                  samePath(raster.resultPath, owner.resultPath),
                  raster.revision.caseInsensitiveCompare(owner.resultRevision) == .orderedSame,
                  raster.profileIndex == profile.index, raster.mapType == "Depth",
                  raster.width > 0, raster.height > 0, !overflow, !byteOverflow,
                  raster.rgba.count == bytes,
                  finiteExtent(raster.minX, raster.minY, raster.maxX, raster.maxY) else {
                throw protocolFailure("The depth map preview raster does not match the selected Result profile.")
            }
        }
    }

    static func depthExecution(_ reply: DepthShapefileExportExecutionResult,
                               capture: DepthShapefileExportCapture,
                               owner: DepthShapefileExportOwner,
                               profile: DepthShapefileExportProfile,
                               outputPath: String, cellSize: Double,
                               simplifyDistance: Double) throws {
        guard reply.mapID.caseInsensitiveCompare(capture.map.mapID) == .orderedSame,
              reply.contextToken == capture.contextToken,
              reply.resultNode == owner.node, reply.selectionIndex == 0,
              samePath(reply.resultPath, owner.resultPath),
              reply.resultRevision.caseInsensitiveCompare(owner.resultRevision) == .orderedSame,
              reply.profileIndex == profile.index,
              reply.profileName == profile.name, reply.profileTime == profile.time,
              reply.cellSize == cellSize, reply.simplifyDistance == simplifyDistance else {
            throw protocolFailure("The depth export receipt does not match its captured Result profile.")
        }
        if reply.state == "cancelled" {
            guard reply.outputPath == nil, reply.artifacts.isEmpty else {
                throw protocolFailure("The cancelled depth export unexpectedly returned output files.")
            }
            return
        }
        let expectedExtensions: Set<String> = ["shp", "shx", "dbf"]
        let artifactExtensions = Set(reply.artifacts.map {
            URL(fileURLWithPath: $0.path).pathExtension.lowercased()
        })
        guard reply.state == "completed", let returnedPath = reply.outputPath,
              samePath(returnedPath, outputPath), reply.polygonCount >= 0,
              expectedExtensions.isSubset(of: artifactExtensions),
              reply.artifacts.count == artifactExtensions.count,
              reply.artifacts.allSatisfy({ artifact in
                  let url = URL(fileURLWithPath: artifact.path)
                  return url.deletingPathExtension().standardizedFileURL
                      == URL(fileURLWithPath: outputPath).deletingPathExtension().standardizedFileURL
                      && artifact.sizeBytes > 0 && isSHA256(artifact.sha256)
              }) else {
            throw protocolFailure("The depth export completed without a complete Shapefile family receipt.")
        }
    }

    private static func finiteExtent(_ minX: Double, _ minY: Double,
                                     _ maxX: Double, _ maxY: Double) -> Bool {
        [minX, minY, maxX, maxY].allSatisfy(\.isFinite) && maxX > minX && maxY > minY
    }

    private static func expectedExportBounds(inspection: RasterRGBExportInspection,
                                             currentView: RasterMapViewExtent?,
                                             region: RasterRGBExportRegion) -> (Double, Double, Double, Double)? {
        guard finiteExtent(inspection.fullMinX, inspection.fullMinY,
                           inspection.fullMaxX, inspection.fullMaxY) else { return nil }
        guard region == .currentView else {
            return (inspection.fullMinX, inspection.fullMinY,
                    inspection.fullMaxX, inspection.fullMaxY)
        }
        guard let currentView else { return nil }
        let minX = max(inspection.fullMinX, currentView.minX)
        let minY = max(inspection.fullMinY, currentView.minY)
        let maxX = min(inspection.fullMaxX, currentView.maxX)
        let maxY = min(inspection.fullMaxY, currentView.maxY)
        guard finiteExtent(minX, minY, maxX, maxY) else { return nil }
        return (minX, minY, maxX, maxY)
    }

    private static func sameExtent(_ minX: Double, _ minY: Double,
                                   _ maxX: Double, _ maxY: Double,
                                   _ expected: (Double, Double, Double, Double)) -> Bool {
        abs(minX - expected.0) <= tolerance(expected.0)
            && abs(minY - expected.1) <= tolerance(expected.1)
            && abs(maxX - expected.2) <= tolerance(expected.2)
            && abs(maxY - expected.3) <= tolerance(expected.3)
    }

    private static func isFinite(_ coordinate: GeometryTopologyCoordinate) -> Bool {
        coordinate.x.isFinite && coordinate.y.isFinite
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }
    }

    private static func tolerance(_ value: Double) -> Double { max(1, abs(value)) * 1e-10 }

    private static func samePath(_ first: String, _ second: String) -> Bool {
        SourceFilePaths.canonical(URL(fileURLWithPath: first))
            == SourceFilePaths.canonical(URL(fileURLWithPath: second))
    }

    private static func protocolFailure(_ message: String) -> BackendServiceError {
        BackendServiceError(code: "protocolFailure", message: message)
    }
}

enum ExportMapViewport {
    static func make(_ extent: ViewportRequest?, width: Int = 1_024) -> RasterMapViewExtent? {
        guard let extent, extent.isFiniteAndOrdered,
              extent.upperRight.x > extent.lowerLeft.x,
              extent.upperRight.y > extent.lowerLeft.y else { return nil }
        let aspect = (extent.upperRight.y - extent.lowerLeft.y)
            / (extent.upperRight.x - extent.lowerLeft.x)
        guard aspect.isFinite, aspect > 0 else { return nil }
        let pixelWidth = max(1, min(width, 4_096))
        let rawHeight = Double(pixelWidth) * aspect
        guard rawHeight.isFinite else { return nil }
        let height = Int(min(4_096, max(1, rawHeight.rounded())))
        return RasterMapViewExtent(minX: extent.lowerLeft.x, minY: extent.lowerLeft.y,
            maxX: extent.upperRight.x, maxY: extent.upperRight.y,
            pixelWidth: pixelWidth, pixelHeight: height)
    }
}
