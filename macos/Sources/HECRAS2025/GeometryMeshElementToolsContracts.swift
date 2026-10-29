import Foundation
import RASWorkspaceCore

enum GeometryMeshElementKind: String, CaseIterable, Identifiable, Sendable {
    case cell = "Cell"
    case face = "Face"
    case node = "Node"

    var id: String { rawValue }
}

enum GeometryMeshShapefileExportKind: String, CaseIterable, Identifiable, Sendable {
    case cellCenters = "CellCenters"
    case perimeterFaces = "PerimeterFaces"

    var id: String { rawValue }
}

struct GeometryMeshToolsProjectContext: Hashable, Sendable {
    let projectSessionID: UUID
    let coreLayerContext: CoreLayerRequestContext?
}

/// Captures the exact parent-owned geometry and topology drafts together with
/// the owning project session and Flow Area row. Tool replies are never
/// installed against a different source or draft.
struct GeometryMeshToolsOwnerCapture: Hashable, Sendable {
    let projectSessionID: UUID
    let assetID: String
    let plotOwner: GeometryMeshPlotOwnerCapture
    let flowAreaID: String
    let flowAreaName: String

    var model: GeometryMeshModelRequest { plotOwner.model }
    var sourceRevision: String { plotOwner.sourceRevision }
    var meshDraftState: String { plotOwner.meshDraftState }
    var topologyDraftState: String? { plotOwner.topologyDraftState }
    var meshDraftSHA256: String { plotOwner.meshDraftSHA256 }
    var topologyDraftSHA256: String { plotOwner.topologyDraftSHA256 }
    var coreLayerContext: CoreLayerRequestContext? { plotOwner.model.coreLayerContext }

    var identity: String {
        [projectSessionID.uuidString.lowercased(), assetID, plotOwner.ownerIdentity,
         coreLayerContext?.identityToken ?? "", flowAreaID, flowAreaName]
            .joined(separator: "|")
    }
}

struct GeometryMeshElementFindRequest: Encodable, Sendable {
    let model: GeometryMeshModelRequest
    let revision: String
    let draftState: String
    let topologyDraftState: String?
    let meshDraftSHA256: String
    let topologyDraftSHA256: String
    let flowAreaID: String
    let expectedFlowAreaName: String
    let elementKind: String
    let index: Int
}

struct GeometryMeshElementFindResult: Decodable, Hashable, Sendable {
    let canonicalAssetPath: String
    let sourceRevision: String
    let flowAreaID: String
    let flowAreaName: String
    let elementKind: String
    let index: Int
    let meshDraftSHA256: String
    let topologyDraftSHA256: String
    let x: Double
    let y: Double
    let viewport: GeometryMeshExtent
    let coordinates: [GeometryTopologyCoordinate]
}

struct GeometryMeshElementFindPresentation: Hashable, Sendable {
    let owner: GeometryMeshToolsOwnerCapture
    let result: GeometryMeshElementFindResult

    var targetID: String {
        "mesh-element-find|\(owner.flowAreaID)|\(result.elementKind)|\(result.index)"
    }

    var identity: String { owner.identity + "|" + targetID }
}

struct GeometryMeshShapefileExportRequest: Encodable, Hashable, Sendable {
    let operationID: String
    let model: GeometryMeshModelRequest
    let revision: String
    let draftState: String
    let topologyDraftState: String?
    let meshDraftSHA256: String
    let topologyDraftSHA256: String
    let flowAreaID: String
    let expectedFlowAreaName: String
    let exportKind: String
    let outputPath: String
}

struct GeometryMeshShapefileExportArtifactReceipt: Decodable, Hashable, Sendable {
    let path: String
    let sizeBytes: Int64
    let sha256: String
}

struct GeometryMeshShapefileExportResult: Decodable, Hashable, Sendable {
    let operationID: String
    let state: String
    let canonicalAssetPath: String
    let sourceRevision: String
    let flowAreaID: String
    let flowAreaName: String
    let exportKind: String
    let meshDraftSHA256: String
    let topologyDraftSHA256: String
    let outputPath: String?
    let featureCount: Int
    let projectionWKT: String?
    let artifacts: [GeometryMeshShapefileExportArtifactReceipt]
}

struct GeometryMeshShapefileExportPresentation: Identifiable, Hashable, Sendable {
    let owner: GeometryMeshToolsOwnerCapture
    let request: GeometryMeshShapefileExportRequest
    let result: GeometryMeshShapefileExportResult

    var id: String { request.operationID }
    var shapefileURL: URL? {
        result.artifacts.first(where: { URL(fileURLWithPath: $0.path).pathExtension.lowercased() == "shp" })
            .map { URL(fileURLWithPath: $0.path) }
    }
}

@MainActor
protocol GeometryMeshElementToolsProviding: AnyObject {
    func findElement(_ request: GeometryMeshElementFindRequest) async throws -> GeometryMeshElementFindResult
    func exportShapefile(_ request: GeometryMeshShapefileExportRequest,
                         progress: @escaping @MainActor (BackendProgressUpdate) -> Void) async throws
        -> GeometryMeshShapefileExportResult
    @discardableResult func cancelExport(operationID: String) -> Bool
}

@MainActor
final class BackendGeometryMeshElementToolsProvider: GeometryMeshElementToolsProviding {
    private typealias ExportOperation = BackendDuplexOperation<GeometryMeshOperationControl,
        BackendProgressUpdate, GeometryMeshShapefileExportResult>

    private let client: BackendProcessClient
    private var activeExports: [String: ExportOperation] = [:]
    private var controlSequences: [String: UInt64] = [:]

    init(client: BackendProcessClient) { self.client = client }

    func findElement(_ request: GeometryMeshElementFindRequest) async throws -> GeometryMeshElementFindResult {
        try await client.request("geometry.mesh.findElement", parameters: request,
                                 as: GeometryMeshElementFindResult.self)
    }

    func exportShapefile(_ request: GeometryMeshShapefileExportRequest,
                         progress: @escaping @MainActor (BackendProgressUpdate) -> Void) async throws
        -> GeometryMeshShapefileExportResult {
        let operation = try client.startDuplex("geometry.mesh.exportShapefile", parameters: request,
            control: GeometryMeshOperationControl.self, event: BackendProgressUpdate.self,
            as: GeometryMeshShapefileExportResult.self)
        activeExports[request.operationID] = operation
        controlSequences[request.operationID] = 0
        defer {
            activeExports[request.operationID] = nil
            controlSequences[request.operationID] = nil
        }

        var progressStreamError: Error?
        do {
            for try await update in operation.events { progress(update) }
        } catch {
            progressStreamError = error
        }

        // The terminal response carries the commit receipt. Always await it,
        // even when progress delivery fails or cancellation was requested.
        let result = try await operation.value()
        if let progressStreamError, result.state != "completed", result.state != "cancelled" {
            throw progressStreamError
        }
        return result
    }

    @discardableResult
    func cancelExport(operationID: String) -> Bool {
        guard let operation = activeExports[operationID] else { return false }
        let nextSequence = (controlSequences[operationID] ?? 0) &+ 1
        controlSequences[operationID] = nextSequence
        do {
            try operation.sendControl(.cancel, sequence: nextSequence)
            return true
        } catch {
            // Keep the result channel alive. The file may already have been
            // committed even if the cancel frame could not be delivered, and
            // the terminal reply is the only source of its durable receipt.
            return false
        }
    }
}

enum GeometryMeshElementToolsValidation {
    static func find(_ result: GeometryMeshElementFindResult,
                     matches request: GeometryMeshElementFindRequest) -> Bool {
        guard canonical(result.canonicalAssetPath) == canonical(request.model.assetPath),
              result.sourceRevision.caseInsensitiveCompare(request.revision) == .orderedSame,
              result.flowAreaID == request.flowAreaID,
              result.flowAreaName == request.expectedFlowAreaName,
              result.elementKind == request.elementKind,
              result.index == request.index,
              result.meshDraftSHA256.caseInsensitiveCompare(request.meshDraftSHA256) == .orderedSame,
              result.topologyDraftSHA256.caseInsensitiveCompare(request.topologyDraftSHA256) == .orderedSame,
              result.x.isFinite, result.y.isFinite,
              valid(result.viewport), !result.coordinates.isEmpty,
              result.coordinates.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
        switch request.elementKind {
        case GeometryMeshElementKind.cell.rawValue: return result.coordinates.count >= 3
        case GeometryMeshElementKind.face.rawValue: return result.coordinates.count >= 2
        case GeometryMeshElementKind.node.rawValue:
            guard result.coordinates.count == 1, let coordinate = result.coordinates.first else { return false }
            return coordinate == GeometryTopologyCoordinate(x: result.x, y: result.y)
        default: return false
        }
    }

    static func export(_ result: GeometryMeshShapefileExportResult,
                       matches request: GeometryMeshShapefileExportRequest) -> Bool {
        guard result.operationID == request.operationID,
              canonical(result.canonicalAssetPath) == canonical(request.model.assetPath),
              result.sourceRevision.caseInsensitiveCompare(request.revision) == .orderedSame,
              result.flowAreaID == request.flowAreaID,
              result.flowAreaName == request.expectedFlowAreaName,
              result.exportKind == request.exportKind,
              result.meshDraftSHA256.caseInsensitiveCompare(request.meshDraftSHA256) == .orderedSame,
              result.topologyDraftSHA256.caseInsensitiveCompare(request.topologyDraftSHA256) == .orderedSame,
              result.featureCount >= 0 else { return false }
        if result.state == "cancelled" {
            return result.outputPath == nil && result.artifacts.isEmpty
        }
        guard result.state == "completed", let outputPath = result.outputPath,
              canonical(outputPath) == canonical(request.outputPath),
              !request.outputPath.isEmpty else {
            return false
        }
        let outputURL = URL(fileURLWithPath: request.outputPath)
        let expectedBase = outputURL.deletingPathExtension().path
        var extensions = Set<String>()
        for artifact in result.artifacts {
            let url = URL(fileURLWithPath: artifact.path)
            let ext = url.pathExtension.lowercased()
            guard ["shp", "shx", "dbf", "prj", "cpg"].contains(ext),
                  canonical(url.deletingPathExtension().path) == canonical(expectedBase),
                  artifact.sizeBytes >= 0,
                  artifact.sha256.count == 64, artifact.sha256.allSatisfy({ $0.isHexDigit }),
                  extensions.insert(ext).inserted else { return false }
        }
        return ["shp", "shx", "dbf"].allSatisfy(extensions.contains)
    }

    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func valid(_ extent: GeometryMeshExtent) -> Bool {
        [extent.minX, extent.minY, extent.maxX, extent.maxY].allSatisfy(\.isFinite)
            && extent.minX < extent.maxX && extent.minY < extent.maxY
    }
}

enum GeometryMeshShapefileDestination {
    static let familyExtensions: Set<String> = ["shp", "shx", "dbf", "prj", "cpg"]

    static func normalized(_ selectedURL: URL) -> URL {
        selectedURL.pathExtension.lowercased() == "shp"
            ? selectedURL : selectedURL.appendingPathExtension("shp")
    }

    static func existingFamily(at outputURL: URL, fileManager: FileManager = .default) -> [URL] {
        let directory = outputURL.deletingLastPathComponent()
        let base = outputURL.deletingPathExtension().lastPathComponent
        guard let children = try? fileManager.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        return children.filter { child in
            child.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(base) == .orderedSame
                && familyExtensions.contains(child.pathExtension.lowercased())
        }
    }
}
