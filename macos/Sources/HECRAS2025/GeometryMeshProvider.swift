import Foundation
import RASWorkspaceCore

struct GeometryMeshModelRequest: Codable, Hashable, Sendable {
    let assetPath: String
    let kind: String
    let projectPath: String?
    let projectXml: String?
    var coreLayerContext: CoreLayerRequestContext? = nil
}

struct GeometryMeshOperationControl: Encodable, Sendable {
    let type: String
    static let cancel = Self(type: "cancel")
}

struct GeometryMeshPropertyTablesRequest: Encodable, Sendable {
    let model: GeometryMeshModelRequest
    let revision: String
    let draftState: String
    let topologyDraftState: String?
    let selectedRegionIDs: [Int]
}

struct GeometryMeshPropertyTablesResult: Decodable, Sendable {
    let succeeded: Bool
    let cancelled: Bool
    let messages: [String]
    let snapshot: GeometryMeshSnapshot
}

struct GeometryMeshGenerateRequest: Encodable, Sendable {
    let model: GeometryMeshModelRequest
    let revision: String
    let draftState: String
    let topologyDraftState: String?
    let selectedRegionIDs: [Int]
    let operationID: String
}

struct GeometryMeshGenerateResult: Decodable, Sendable {
    let operationID: String
    let revision: String
    let cancelled: Bool
    let snapshot: GeometryMeshSnapshot
}

struct GeometryMeshMutation: Codable, Sendable {
    let operation: String
    var flowAreaIDs: [String]? = nil
    var expectedFlowAreaNames: [String]? = nil
    var featureIDs: [Int]? = nil
    var fieldID: String? = nil
    var value: String? = nil
    var axis: String? = nil
    var expectedMeshFingerprint: String? = nil
    var generatedMeshPayload: String? = nil
    var generatedReport: GeometryMeshGenerationReport? = nil
    var operationID: String? = nil
}

struct GeometryMeshExtent: Codable, Hashable, Sendable {
    let minX: Double
    let minY: Double
    let maxX: Double
    let maxY: Double
}

struct GeometryMeshMetadataItem: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let value: String
}

struct GeometryMeshFlowAreaRow: Codable, Identifiable, Sendable {
    let id: String
    let rowIndex: Int
    let name: String
    let targetedCellSpacing: Double?
    let hasMesh: Bool
    let cellCount: Int
    let faceCount: Int
    let nodeCount: Int
    let extent: GeometryMeshExtent?
    let hasMeshErrors: Bool
    let hasPropertyTables: Bool
    let propertyTablesQueuedForParentSave: Bool
    let propertyTablesPinned: Bool
    let metadata: [GeometryMeshMetadataItem]
}

struct GeometryMeshDegreeIssue: Codable, Identifiable, Sendable {
    let id: String
    let flowAreaID: String
    let flowAreaName: String
    let meshIndex: Int
    let nodeIndex: Int
    let faceCount: Int
    let x: Double?
    let y: Double?
    let cellsExtent: GeometryMeshExtent?
    var cells: [GeometryMeshDegreeCell]? = nil
}

struct GeometryMeshDegreeCell: Codable, Sendable {
    let cellIndex: Int
    let coordinates: [GeometryTopologyCoordinate]
}

struct GeometryMeshDegreeScan: Codable, Sendable {
    let maxFacesPerNode: Int
    let issues: [GeometryMeshDegreeIssue]
}

struct GeometryMeshPatchDimension: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let arcCount: Int
    let sizeFunction: String?
    let sizeFunctionHasMismatch: Bool
    let liveValue: Double?
    let liveValueHasMismatch: Bool
    let canResize: Bool
    let canApply: Bool
    let canChangeMode: Bool
    var sideArcSelection: GeometryMeshPatchArcSelection? = nil
    var sideArcIssues: [GeometryMeshPatchSideArcIssue]? = nil
}

/// Source arc membership for one Quad side. The polyline coordinates remain
/// in the same mesh snapshot's topology map, so a response never copies all
/// arc vertices into every dimension or uses a rendered/inferred outline.
struct GeometryMeshPatchArcSelection: Codable, Equatable, Sendable {
    let sourceRevision: String
    let topologyFingerprint: String
    let selectedRegionIDs: [Int]
    let axis: String
    let arcFeatureIDs: [Int]
}

struct GeometryMeshPatchSideArcIssue: Codable, Hashable, Identifiable, Sendable {
    let regionFID: Int
    let axis: String
    let code: String
    let message: String

    var id: String { "\(regionFID):\(axis):\(code):\(message)" }
}

struct GeometryMeshPatchSizing: Codable, Sendable {
    let state: String
    let kind: String?
    let message: String
    let selectedRegionIDs: [Int]
    let dimensions: [GeometryMeshPatchDimension]
}

struct GeometryMeshGenerationReport: Codable, Sendable {
    let succeeded: Bool
    let partial: Bool
    let meshWasReplaced: Bool
    let cellCount: Int?
    let messages: [String]
}

/// Transient source OperationResult from one explicit BuildConceptualMesh
/// call. Kept separate from GeometryMeshGenerationReport, which is the current
/// mesh preview summary and may be replayed from the draft ledger.
struct GeometryMeshDiagnosticHistoryEvent: Codable, Sendable {
    let operationID: String
    let result: Bool
    let messages: [GeometryMeshDiagnosticMessage]
    let topology: GeometryTopologyMapData
}

struct GeometryMeshDiagnosticMessage: Codable, Identifiable, Sendable {
    let id: String
    let code: String
    let severity: String
    let evaluatedMessage: String
    let values: [GeometryMeshDiagnosticValue]
}

struct GeometryMeshDiagnosticValue: Codable, Identifiable, Sendable {
    let id: String
    let key: String
    let value: String
    let selectionIDs: [String]
    let targetFeatureID: String?
    let coordinate: GeometryTopologyCoordinate?
}

struct GeometryMeshPrepareSummary: Codable, Sendable {
    let succeeded: Bool?
    let failureReason: String?
    let softwareVersion: String?
    let startTime: String?
    let totalDurationSeconds: Double?
    let prepareLog: String?
    var endTime: String? = nil
    var propertyTableDurationSeconds: Double? = nil
}

/// A bounded map preview of source flow-area cells and the current conceptual
/// topology. CellIndex is the original mesh-local ordinal, not an HDF FID.
struct GeometryMeshMapCell: Codable, Identifiable, Sendable {
    let id: String
    let flowAreaID: String
    let flowAreaName: String
    let meshIndex: Int
    let cellIndex: Int
    let coordinates: [GeometryTopologyCoordinate]
}

struct GeometryMeshMapData: Codable, Sendable {
    let extent: GeometryTopologyExtent?
    let topology: GeometryTopologyMapData
    let cells: [GeometryMeshMapCell]
    let totalCellCount: Int
    let renderedCellCount: Int
    let omittedCellCount: Int
    let invalidCandidateCount: Int
    let cellLimit: Int
    let vertexLimit: Int
}

struct GeometryMeshSnapshot: Codable, Sendable {
    let revision: String
    let draftState: String
    let topologyFingerprint: String
    let canEdit: Bool
    let isDirty: Bool
    let flowAreas: [GeometryMeshFlowAreaRow]
    let regions: GeometryTopologyFeatureTable
    let selectedRegionIDs: [Int]
    let patchSizing: GeometryMeshPatchSizing?
    let generationReport: GeometryMeshGenerationReport?
    let prepareSummary: GeometryMeshPrepareSummary?
    var map: GeometryMeshMapData? = nil
    var preparePending = false
    var diagnosticHistoryEvent: GeometryMeshDiagnosticHistoryEvent? = nil
}

@MainActor
protocol GeometryMeshProvider {
    func modelRequest(for asset: ProjectAsset) -> GeometryMeshModelRequest
    func currentTopologyDraftState() -> String?
    func load(_ model: GeometryMeshModelRequest, expectedRevision: String?, draftState: String?,
              topologyDraftState: String?, selectedRegionIDs: [Int]) async throws -> GeometryMeshSnapshot
    func edit(_ model: GeometryMeshModelRequest, revision: String, draftState: String,
              topologyDraftState: String?, mutation: GeometryMeshMutation,
              selectedRegionIDs: [Int]) async throws -> GeometryMeshSnapshot
    func scanDegreeErrors(_ model: GeometryMeshModelRequest, revision: String, draftState: String,
                          topologyDraftState: String?, maxFacesPerNode: Int) async throws -> GeometryMeshDegreeScan
    func scanDegreeErrorsForMapOverlay(_ model: GeometryMeshModelRequest, revision: String, draftState: String,
                                       topologyDraftState: String?, maxFacesPerNode: Int) async throws -> GeometryMeshDegreeScan
    func startComputePropertyTables(_ request: GeometryMeshPropertyTablesRequest) throws
        -> BackendDuplexOperation<GeometryMeshOperationControl, BackendProgressUpdate,
            GeometryMeshPropertyTablesResult>
    func startGenerateMesh(_ request: GeometryMeshGenerateRequest) throws
        -> BackendDuplexOperation<GeometryMeshOperationControl, BackendProgressUpdate,
            GeometryMeshGenerateResult>
}

extension GeometryMeshProvider {
    func scanDegreeErrorsForMapOverlay(_ model: GeometryMeshModelRequest, revision: String,
                                       draftState: String, topologyDraftState: String?,
                                       maxFacesPerNode: Int) async throws -> GeometryMeshDegreeScan {
        try await scanDegreeErrors(model, revision: revision, draftState: draftState,
            topologyDraftState: topologyDraftState, maxFacesPerNode: maxFacesPerNode)
    }
}

@MainActor
extension GeometryMeshProvider {
    func startComputePropertyTables(_ request: GeometryMeshPropertyTablesRequest) throws
        -> BackendDuplexOperation<GeometryMeshOperationControl, BackendProgressUpdate,
            GeometryMeshPropertyTablesResult> {
        throw CocoaError(.featureUnsupported)
    }

    func startGenerateMesh(_ request: GeometryMeshGenerateRequest) throws
        -> BackendDuplexOperation<GeometryMeshOperationControl, BackendProgressUpdate,
            GeometryMeshGenerateResult> {
        throw CocoaError(.featureUnsupported)
    }
}

@MainActor
final class BackendGeometryMeshProvider: GeometryMeshProvider {
    private let client: BackendProcessClient
    private let currentProject: @MainActor () -> ProjectDocument?
    private let currentCoreLayerContext: @MainActor () -> CoreLayerRequestContext?
    private let topologyDraft: @MainActor () -> String?

    init(client: BackendProcessClient? = nil,
         currentProject: @escaping @MainActor () -> ProjectDocument? = { nil },
         currentCoreLayerContext: @escaping @MainActor () -> CoreLayerRequestContext? = { nil },
         currentTopologyDraftState: @escaping @MainActor () -> String? = { nil }) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
        self.currentProject = currentProject
        self.currentCoreLayerContext = currentCoreLayerContext
        topologyDraft = currentTopologyDraftState
    }

    func modelRequest(for asset: ProjectAsset) -> GeometryMeshModelRequest {
        let project = currentProject()
        return GeometryMeshModelRequest(assetPath: asset.url.path, kind: "Geometry",
            projectPath: project?.url?.path, projectXml: project?.editorXML,
            coreLayerContext: currentCoreLayerContext())
    }

    func currentTopologyDraftState() -> String? { topologyDraft() }

    func load(_ model: GeometryMeshModelRequest, expectedRevision: String?, draftState: String?,
              topologyDraftState: String?, selectedRegionIDs: [Int]) async throws -> GeometryMeshSnapshot {
        struct Request: Encodable, Sendable {
            let model: GeometryMeshModelRequest
            let revision: String?
            let draftState: String?
            let topologyDraftState: String?
            let selectedRegionIDs: [Int]
        }
        return try await client.request("geometry.mesh.load", parameters: Request(model: model,
            revision: expectedRevision, draftState: draftState, topologyDraftState: topologyDraftState,
            selectedRegionIDs: selectedRegionIDs), as: GeometryMeshSnapshot.self)
    }

    func edit(_ model: GeometryMeshModelRequest, revision: String, draftState: String,
              topologyDraftState: String?, mutation: GeometryMeshMutation,
              selectedRegionIDs: [Int]) async throws -> GeometryMeshSnapshot {
        struct Request: Encodable, Sendable {
            let model: GeometryMeshModelRequest
            let revision: String
            let draftState: String
            let topologyDraftState: String?
            let selectedRegionIDs: [Int]
            let mutation: GeometryMeshMutation
        }
        return try await client.request("geometry.mesh.edit", parameters: Request(model: model,
            revision: revision, draftState: draftState, topologyDraftState: topologyDraftState,
            selectedRegionIDs: selectedRegionIDs, mutation: mutation), as: GeometryMeshSnapshot.self)
    }

    func scanDegreeErrors(_ model: GeometryMeshModelRequest, revision: String, draftState: String,
                          topologyDraftState: String?, maxFacesPerNode: Int) async throws -> GeometryMeshDegreeScan {
        struct Request: Encodable, Sendable {
            let model: GeometryMeshModelRequest
            let revision: String
            let draftState: String
            let topologyDraftState: String?
            let maxFacesPerNode: Int
        }
        return try await client.request("geometry.mesh.degreeErrors", parameters: Request(model: model,
            revision: revision, draftState: draftState, topologyDraftState: topologyDraftState,
            maxFacesPerNode: maxFacesPerNode), as: GeometryMeshDegreeScan.self)
    }

    func scanDegreeErrorsForMapOverlay(_ model: GeometryMeshModelRequest, revision: String,
                                       draftState: String, topologyDraftState: String?,
                                       maxFacesPerNode: Int) async throws -> GeometryMeshDegreeScan {
        struct Request: Encodable, Sendable {
            let model: GeometryMeshModelRequest
            let revision: String
            let draftState: String
            let topologyDraftState: String?
            let maxFacesPerNode: Int
            let includeIncidentCells: Bool
        }
        return try await client.request("geometry.mesh.degreeErrors", parameters: Request(model: model,
            revision: revision, draftState: draftState, topologyDraftState: topologyDraftState,
            maxFacesPerNode: maxFacesPerNode, includeIncidentCells: true), as: GeometryMeshDegreeScan.self)
    }

    func startComputePropertyTables(_ request: GeometryMeshPropertyTablesRequest) throws
        -> BackendDuplexOperation<GeometryMeshOperationControl, BackendProgressUpdate,
            GeometryMeshPropertyTablesResult> {
        try client.startDuplex("geometry.mesh.computePropertyTables", parameters: request,
            control: GeometryMeshOperationControl.self, event: BackendProgressUpdate.self,
            as: GeometryMeshPropertyTablesResult.self)
    }

    func startGenerateMesh(_ request: GeometryMeshGenerateRequest) throws
        -> BackendDuplexOperation<GeometryMeshOperationControl, BackendProgressUpdate,
            GeometryMeshGenerateResult> {
        try client.startDuplex("geometry.mesh.generate", parameters: request,
            control: GeometryMeshOperationControl.self, event: BackendProgressUpdate.self,
            as: GeometryMeshGenerateResult.self)
    }
}
