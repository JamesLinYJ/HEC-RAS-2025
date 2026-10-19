import Foundation
import CryptoKit
import RASWorkspaceCore
import SwiftUI

struct GeometryMeshParentSaveCapture: Sendable {
    let operationID: UUID
    let generation: Int
    let assetID: String?
    let draftState: String?
    let sourceRevision: String?
}

/// Exact source owner handed to the map plot renderer. Both draft payloads are
/// captured from the loaded child session and remain ephemeral render inputs.
struct GeometryMeshPlotOwnerCapture: Hashable, Sendable {
    let model: GeometryMeshModelRequest
    let sourceRevision: String
    let meshDraftState: String
    let topologyDraftState: String?
    let meshDraftSHA256: String
    let topologyDraftSHA256: String
    let ownerIdentity: String
}

/// Owns mesh, flow-area and patch-sizing edits until the parent geometry save.
/// Mesh generation is replayed in the parent's staged HDF context; this child
/// never publishes a source file on its own.
@MainActor
final class GeometryMeshSession: ObservableObject {
    private let provider: any GeometryMeshProvider
    var onParentDraftChange: @MainActor (Bool) -> Void = { _ in }
    private var currentAsset: ProjectAsset?
    private var currentModel: GeometryMeshModelRequest?
    private var expectedSourceRevision: String?
    private var loadedTopologyDraftState: String?
    private var didLoad = false
    private var loadGeneration = 0
    private var modelGeneration = 0
    private var activeParentSaveID: UUID?
    private var activePropertyTablesOperationID: UUID?
    private var activePropertyTablesOperation: BackendDuplexOperation<GeometryMeshOperationControl,
        BackendProgressUpdate, GeometryMeshPropertyTablesResult>?
    private var propertyTablesControlSequence: UInt64 = 0
    private var activeMeshGenerationOperationID: UUID?
    private var activeMeshGenerationOperation: BackendDuplexOperation<GeometryMeshOperationControl,
        BackendProgressUpdate, GeometryMeshGenerateResult>?
    private var activeMeshGenerationControlSequence: UInt64 = 0
    private var activeMeshGenerationProjectSessionID: UUID?
    private var activeMeshGenerationTopologyDraftState: String?
    private var diagnosticsPreferencesGeneration = 0
    private var activeDiagnosticsPreferencesSaveID: UUID?
    private var diagnosticsPreferencesBaseline = MeshDiagnosticsVisualSettings()
    private var pendingDiagnosticsPreferencesInstall: (settings: MeshDiagnosticsVisualSettings, scope: GeometryMeshDiagnosticsScope)?
    private(set) var diagnosticsPreferencesScope: GeometryMeshDiagnosticsScope?
    private var meshElementFindGeneration = 0
    private var meshShapefileExportGeneration = 0
    private var activeMeshShapefileExportOperationID: String?
    private var activeMeshShapefileExportProvider: (any GeometryMeshElementToolsProviding)?
    private var activeMeshShapefileExportOwner: GeometryMeshToolsOwnerCapture?
    private var meshShapefileExportOwnerMonitor: Task<Void, Never>?

    @Published private(set) var snapshot: GeometryMeshSnapshot?
    @Published private(set) var selectedRegionIDs: Set<Int> = []
    @Published private(set) var selectedFlowAreaIDs: Set<String> = []
    @Published private(set) var selectedMapTargetID: String?
    @Published private(set) var degreeScan: GeometryMeshDegreeScan?
    @Published private(set) var isLoading = false
    @Published private(set) var isEditing = false
    @Published private(set) var isScanningDegreeErrors = false
    @Published private(set) var isComputingPropertyTables = false
    @Published private(set) var isCancellingPropertyTables = false
    @Published private(set) var propertyTablesProgress: BackendProgressUpdate?
    @Published private(set) var propertyTablesMessages: [String] = []
    @Published private(set) var propertyTablesOutcome: String?
    @Published private(set) var isGeneratingMesh = false
    @Published private(set) var isCancellingMeshGeneration = false
    @Published private(set) var meshGenerationProgress: BackendProgressUpdate?
    @Published private(set) var meshGenerationOutcome: String?
    /// Identifies the last accepted generated-mesh child draft. The map can
    /// project its exact preview after the duplex operation ends and retire it
    /// when the draft is discarded or the saved source catches up.
    @Published private(set) var meshGenerationResultIdentity: String?
    /// Identifies the last Generate Mesh job that reached its source-equivalent
    /// terminal visibility update. Unlike the result identity, this is set for
    /// cancelled and failed jobs too: the retained visual-context behavior
    /// checks its FlowArea tree row after every started job.
    @Published private(set) var meshGenerationTerminalIdentity: String?
    private(set) var meshGenerationSourceRevision: String?
    private(set) var meshGenerationOperationID: UUID?
    @Published private(set) var parentSaveInProgress = false
    @Published private(set) var diagnosticsPreferences = MeshDiagnosticsVisualSettings()
    @Published private(set) var hasUnsavedDiagnosticsPreferences = false
    @Published private(set) var isSavingDiagnosticsPreferences = false
    @Published private(set) var diagnosticsPreferencesScopeMismatch = false
    @Published private(set) var meshElementFind: GeometryMeshElementFindPresentation?
    @Published private(set) var isFindingMeshElement = false
    @Published private(set) var isExportingMeshShapefile = false
    @Published private(set) var isCancellingMeshShapefileExport = false
    @Published private(set) var meshShapefileExportProgress: BackendProgressUpdate?
    @Published private(set) var meshShapefileExportOutcome: String?
    @Published private(set) var meshShapefileExportReceipts: [GeometryMeshShapefileExportPresentation] = []
    @Published private(set) var meshToolsError: String?
    @Published var error: String?
    @Published var diagnosticsPreferencesError: String?

    var onDiagnosticsPreferencesChange: @MainActor (Bool) -> Void = { _ in }

    init(provider: any GeometryMeshProvider,
         onParentDraftChange: @escaping @MainActor (Bool) -> Void = { _ in }) {
        self.provider = provider
        self.onParentDraftChange = onParentDraftChange
    }

    var canEdit: Bool {
        snapshot?.canEdit == true && didLoad && provider.currentTopologyDraftState() == loadedTopologyDraftState
            && !parentSaveInProgress && !isEditing && !isLoading && !isGeneratingMesh
    }
    var canScanDegreeErrors: Bool {
        didLoad && snapshot != nil && provider.currentTopologyDraftState() == loadedTopologyDraftState
            && !parentSaveInProgress && !isEditing && !isLoading && !isSavingDiagnosticsPreferences
    }
    var canBeginDiagnosticsPreferencesSave: Bool {
        hasUnsavedDiagnosticsPreferences && !isSavingDiagnosticsPreferences
            && !parentSaveInProgress && !isEditing && !isLoading
    }
    var isDirty: Bool { snapshot?.isDirty == true }
    var canBeginParentSave: Bool { !isLoading && !isEditing && !isGeneratingMesh && !parentSaveInProgress }
    var geometryMeshStateForParentSave: String? { isDirty ? snapshot?.draftState : nil }
    var assetIdentity: String? { currentAsset?.id }
    /// Retire a queued patch action when its original project/source context changes.
    var patchEditorRequestIdentity: String { String(modelGeneration) + "|" + geometryMeshIdentity }
    var geometryMeshIdentity: String {
        let topologyState = provider.currentTopologyDraftState() ?? ""
        return (currentAsset?.id ?? "") + "|" + (snapshot?.revision ?? expectedSourceRevision ?? "")
            + "|" + Self.hash(topologyState)
    }
    var meshToolsChartSourceIdentity: String {
        let model = currentModel
        let modelPath = model.map { SourceFilePaths.canonical(URL(fileURLWithPath: $0.assetPath)) } ?? ""
        return [modelPath, model?.kind ?? "", model?.projectPath ?? "",
            Self.hash(model?.projectXml ?? ""), model?.coreLayerContext?.identityToken ?? "",
            currentAsset?.id ?? "", snapshot?.revision ?? expectedSourceRevision ?? "",
            Self.hash(provider.currentTopologyDraftState() ?? "")].joined(separator: "|")
    }
    var mapCameraIdentity: String {
        let map = snapshot?.map
        let extentIdentity: String
        if let extent = map?.extent {
            extentIdentity = [extent.minX, extent.minY, extent.maxX, extent.maxY]
                .map { String($0.bitPattern) }.joined(separator: ",")
        } else {
            extentIdentity = "none"
        }
        return [currentAsset?.id ?? "", extentIdentity, String(map?.totalCellCount ?? 0),
                String(map?.topology.features.count ?? 0)].joined(separator: "|")
    }
    var preparePending: Bool { snapshot?.preparePending == true }
    var canRequestPrepare: Bool { canEdit }
    var canComputePropertyTables: Bool {
        canEdit && !isScanningDegreeErrors && !isSavingDiagnosticsPreferences
    }
    var meshGenerationTaskName: String? { meshGenerationProgress?.taskName }
    var meshGenerationMessage: String? { meshGenerationProgress?.message }
    var canCancelMeshGeneration: Bool { isGeneratingMesh && !isCancellingMeshGeneration }

    /// Catalog tree progress is visible only while the operation still belongs
    /// to this exact project session, physical source path, and loaded revision.
    func matchesActiveMeshGeneration(projectSessionID: UUID, sourcePath: String,
                                     sourceRevision: String) -> Bool {
        guard isGeneratingMesh,
              activeMeshGenerationProjectSessionID == projectSessionID,
              activeMeshGenerationOperationID == meshGenerationOperationID,
              meshGenerationSourceRevision == sourceRevision,
              expectedSourceRevision == sourceRevision,
              snapshot?.revision == sourceRevision,
              provider.currentTopologyDraftState() == activeMeshGenerationTopologyDraftState,
              loadedTopologyDraftState == activeMeshGenerationTopologyDraftState,
              let asset = currentAsset,
              SourceFilePaths.canonical(asset.url) == SourceFilePaths.canonical(URL(fileURLWithPath: sourcePath)),
              let model = currentModel,
              SourceFilePaths.canonical(URL(fileURLWithPath: model.assetPath))
                == SourceFilePaths.canonical(URL(fileURLWithPath: sourcePath)) else { return false }
        return true
    }

    /// Returns the accepted revision represented by this Geometry child,
    /// including the clean parent-save acknowledgement while its follow-up
    /// read is in flight. It never lends a revision across assets or topology
    /// draft identities.
    func geometryMapOverlaySourceRevision(for sourcePath: String) -> String? {
        guard let asset = currentAsset, let model = currentModel,
              let current = snapshot, expectedSourceRevision == current.revision,
              SourceFilePaths.canonical(asset.url)
                == SourceFilePaths.canonical(URL(fileURLWithPath: sourcePath)),
              SourceFilePaths.canonical(URL(fileURLWithPath: model.assetPath))
                == SourceFilePaths.canonical(URL(fileURLWithPath: sourcePath)),
              provider.modelRequest(for: asset) == model,
              provider.currentTopologyDraftState() == loadedTopologyDraftState else { return nil }
        return current.revision
    }

    /// Captures the current map-render owner only when its saved source SHA and
    /// both parent-owned draft contexts still match the loaded Geometry child.
    func plotRenderingOwnerCapture(for sourcePath: String,
                                  expectedRevision: String) -> GeometryMeshPlotOwnerCapture? {
        guard !isLoading, !isEditing, !isGeneratingMesh, !isComputingPropertyTables,
              !isScanningDegreeErrors, !isSavingDiagnosticsPreferences,
              !parentSaveInProgress,
              let asset = currentAsset, let model = currentModel, let current = snapshot,
              expectedSourceRevision == expectedRevision,
              current.revision == expectedRevision,
              SourceFilePaths.canonical(asset.url)
                == SourceFilePaths.canonical(URL(fileURLWithPath: sourcePath)),
              SourceFilePaths.canonical(URL(fileURLWithPath: model.assetPath))
                == SourceFilePaths.canonical(URL(fileURLWithPath: sourcePath)),
              provider.modelRequest(for: asset) == model else { return nil }
        let topologyState = provider.currentTopologyDraftState()
        guard topologyState == loadedTopologyDraftState,
              !current.draftState.isEmpty else { return nil }
        let meshDraftSHA256 = Self.hash(current.draftState)
        let topologyDraftSHA256 = Self.hash(topologyState ?? "")
        let ownerIdentity = [SourceFilePaths.canonical(asset.url), model.kind,
            model.projectPath ?? "", Self.hash(model.projectXml ?? ""), current.revision,
            meshDraftSHA256, topologyDraftSHA256].joined(separator: "|")
        return GeometryMeshPlotOwnerCapture(model: model, sourceRevision: current.revision,
            meshDraftState: current.draftState, topologyDraftState: topologyState,
            meshDraftSHA256: meshDraftSHA256, topologyDraftSHA256: topologyDraftSHA256,
            ownerIdentity: ownerIdentity)
    }

    func meshToolsOwnerCapture(flowAreaID: String,
                               projectContext: GeometryMeshToolsProjectContext) -> GeometryMeshToolsOwnerCapture? {
        guard let asset = currentAsset, let model = currentModel, let current = snapshot,
              selectedFlowAreaID == flowAreaID,
              model.coreLayerContext == projectContext.coreLayerContext,
              let row = flowAreas.first(where: { $0.id == flowAreaID && $0.hasMesh }),
              expectedSourceRevision == current.revision,
              let plotOwner = plotRenderingOwnerCapture(for: asset.url.path,
                  expectedRevision: current.revision) else { return nil }
        return GeometryMeshToolsOwnerCapture(projectSessionID: projectContext.projectSessionID,
            assetID: asset.id, plotOwner: plotOwner, flowAreaID: row.id, flowAreaName: row.name)
    }

    func isMeshToolsOwnerCurrent(_ capture: GeometryMeshToolsOwnerCapture,
                                 projectContext: GeometryMeshToolsProjectContext?) -> Bool {
        guard let projectContext,
              projectContext.projectSessionID == capture.projectSessionID,
              projectContext.coreLayerContext == capture.coreLayerContext,
              let current = meshToolsOwnerCapture(flowAreaID: capture.flowAreaID,
                  projectContext: projectContext) else { return false }
        return current == capture
    }

    /// Verifies the stable source identity of a chart request across an
    /// in-child property-table computation. The mesh draft SHA is expected to
    /// advance after a successful compute; model, revision, topology, Flow Area
    /// and project context must remain identical before the caller captures a
    /// fresh element owner.
    func isMeshToolsChartSourceCurrent(_ capture: GeometryMeshToolsOwnerCapture,
                                       projectContext: GeometryMeshToolsProjectContext?) -> Bool {
        guard let projectContext,
              projectContext.projectSessionID == capture.projectSessionID,
              projectContext.coreLayerContext == capture.coreLayerContext,
              let current = meshToolsOwnerCapture(flowAreaID: capture.flowAreaID,
                  projectContext: projectContext) else { return false }
        return Self.sameMeshToolsChartSource(capture, current)
    }

    static func sameMeshToolsChartSource(_ lhs: GeometryMeshToolsOwnerCapture,
                                         _ rhs: GeometryMeshToolsOwnerCapture) -> Bool {
        lhs.projectSessionID == rhs.projectSessionID
            && lhs.assetID == rhs.assetID
            && lhs.plotOwner.model == rhs.plotOwner.model
            && lhs.sourceRevision.caseInsensitiveCompare(rhs.sourceRevision) == .orderedSame
            && lhs.plotOwner.topologyDraftState == rhs.plotOwner.topologyDraftState
            && lhs.topologyDraftSHA256.caseInsensitiveCompare(rhs.topologyDraftSHA256) == .orderedSame
            && lhs.flowAreaID == rhs.flowAreaID
            && lhs.flowAreaName == rhs.flowAreaName
            && lhs.coreLayerContext == rhs.coreLayerContext
    }

    func clearMeshElementFindTargetIfOwnerChanged(projectContext: GeometryMeshToolsProjectContext?) {
        guard let meshElementFind,
              !isMeshToolsOwnerCurrent(meshElementFind.owner, projectContext: projectContext) else { return }
        clearMeshElementFindTarget()
    }

    @discardableResult
    func findElement(flowAreaID: String, elementKind: GeometryMeshElementKind, index: Int,
                     currentProjectContext: @MainActor () -> GeometryMeshToolsProjectContext?,
                     provider toolsProvider: any GeometryMeshElementToolsProviding) async -> Bool {
        guard !isFindingMeshElement, !isExportingMeshShapefile, index >= 0,
              let projectContext = currentProjectContext(),
              let capture = meshToolsOwnerCapture(flowAreaID: flowAreaID,
                  projectContext: projectContext) else {
            meshToolsError = L10n.text("The Flow Area, geometry source, or project context changed. Reload the mesh and try again.")
            return false
        }

        meshElementFindGeneration &+= 1
        let generation = meshElementFindGeneration
        removeMeshElementFindTarget()
        isFindingMeshElement = true
        meshToolsError = nil
        defer {
            if meshElementFindGeneration == generation { isFindingMeshElement = false }
        }

        let request = GeometryMeshElementFindRequest(model: capture.model,
            revision: capture.sourceRevision, draftState: capture.meshDraftState,
            topologyDraftState: capture.topologyDraftState,
            meshDraftSHA256: capture.meshDraftSHA256,
            topologyDraftSHA256: capture.topologyDraftSHA256,
            flowAreaID: capture.flowAreaID, expectedFlowAreaName: capture.flowAreaName,
            elementKind: elementKind.rawValue, index: index)
        do {
            let result = try await toolsProvider.findElement(request)
            guard meshElementFindGeneration == generation,
                  isMeshToolsOwnerCurrent(capture, projectContext: currentProjectContext()) else { return false }
            guard GeometryMeshElementToolsValidation.find(result, matches: request) else {
                throw BackendServiceError(code: "protocolFailure",
                    message: L10n.text("The mesh service returned a result for a different Flow Area, index, or geometry draft."))
            }
            let presentation = GeometryMeshElementFindPresentation(owner: capture, result: result)
            meshElementFind = presentation
            selectedMapTargetID = presentation.targetID
            selectedFlowAreaIDs = [capture.flowAreaID]
            return true
        } catch {
            guard meshElementFindGeneration == generation,
                  isMeshToolsOwnerCurrent(capture, projectContext: currentProjectContext()) else { return false }
            meshToolsError = localizedError(error)
            return false
        }
    }

    func clearMeshElementFindTarget() {
        meshElementFindGeneration &+= 1
        isFindingMeshElement = false
        removeMeshElementFindTarget()
    }

    func reportMeshToolsError(_ message: String?) {
        meshToolsError = message.map(L10n.text)
    }

    func exportShapefile(flowAreaID: String, exportKind: GeometryMeshShapefileExportKind,
                         outputURL: URL,
                         currentProjectContext: @escaping @MainActor () -> GeometryMeshToolsProjectContext?,
                         provider toolsProvider: any GeometryMeshElementToolsProviding) async {
        guard !isExportingMeshShapefile, !isFindingMeshElement,
              outputURL.pathExtension.lowercased() == "shp",
              GeometryMeshShapefileDestination.existingFamily(at: outputURL).isEmpty,
              let projectContext = currentProjectContext(),
              let capture = meshToolsOwnerCapture(flowAreaID: flowAreaID,
                  projectContext: projectContext) else {
            meshToolsError = L10n.text("The Flow Area, geometry source, project context, or output destination changed. Choose a new destination and try again.")
            return
        }

        meshShapefileExportGeneration &+= 1
        let generation = meshShapefileExportGeneration
        let operationID = UUID().uuidString.lowercased()
        let request = GeometryMeshShapefileExportRequest(operationID: operationID,
            model: capture.model, revision: capture.sourceRevision,
            draftState: capture.meshDraftState, topologyDraftState: capture.topologyDraftState,
            meshDraftSHA256: capture.meshDraftSHA256,
            topologyDraftSHA256: capture.topologyDraftSHA256,
            flowAreaID: capture.flowAreaID, expectedFlowAreaName: capture.flowAreaName,
            exportKind: exportKind.rawValue,
            outputPath: outputURL.standardizedFileURL.path)

        isExportingMeshShapefile = true
        isCancellingMeshShapefileExport = false
        meshShapefileExportProgress = nil
        meshShapefileExportOutcome = nil
        meshToolsError = nil
        activeMeshShapefileExportOperationID = operationID
        activeMeshShapefileExportProvider = toolsProvider
        activeMeshShapefileExportOwner = capture
        meshShapefileExportOwnerMonitor?.cancel()
        meshShapefileExportOwnerMonitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self,
                      self.activeMeshShapefileExportOperationID == operationID else { return }
                guard self.isMeshToolsOwnerCurrent(capture,
                    projectContext: currentProjectContext()) else {
                    self.requestMeshShapefileExportCancellation(operationID: operationID)
                    return
                }
            }
        }
        defer {
            meshShapefileExportOwnerMonitor?.cancel()
            meshShapefileExportOwnerMonitor = nil
            if activeMeshShapefileExportOperationID == operationID {
                activeMeshShapefileExportOperationID = nil
                activeMeshShapefileExportProvider = nil
                activeMeshShapefileExportOwner = nil
                isExportingMeshShapefile = false
                isCancellingMeshShapefileExport = false
            }
        }

        do {
            let result = try await toolsProvider.exportShapefile(request) { [weak self] update in
                guard let self,
                      self.activeMeshShapefileExportOperationID == operationID else { return }
                guard self.isMeshToolsOwnerCurrent(capture,
                    projectContext: currentProjectContext()) else {
                    self.requestMeshShapefileExportCancellation(operationID: operationID)
                    return
                }
                if self.meshShapefileExportGeneration == generation {
                    self.meshShapefileExportProgress = update
                }
            }
            guard GeometryMeshElementToolsValidation.export(result, matches: request) else {
                if isMeshToolsOwnerCurrent(capture, projectContext: currentProjectContext()) {
                    meshToolsError = L10n.text("The mesh export returned an incomplete or mismatched Shapefile receipt.")
                }
                return
            }
            guard activeMeshShapefileExportOperationID == operationID,
                  meshShapefileExportGeneration == generation else { return }
            if result.state == "completed" {
                let receipt = GeometryMeshShapefileExportPresentation(owner: capture,
                    request: request, result: result)
                if !meshShapefileExportReceipts.contains(where: { $0.id == operationID }) {
                    meshShapefileExportReceipts.insert(receipt, at: 0)
                }
                meshShapefileExportOutcome = "completed"
            } else {
                meshShapefileExportOutcome = "cancelled"
            }
        } catch {
            if activeMeshShapefileExportOperationID == operationID,
               meshShapefileExportGeneration == generation,
               isMeshToolsOwnerCurrent(capture, projectContext: currentProjectContext()) {
                meshToolsError = localizedError(error)
            }
        }
    }

    func cancelMeshShapefileExport() {
        guard isExportingMeshShapefile, !isCancellingMeshShapefileExport,
              let operationID = activeMeshShapefileExportOperationID else { return }
        requestMeshShapefileExportCancellation(operationID: operationID)
    }

    private func requestMeshShapefileExportCancellation(operationID: String) {
        guard activeMeshShapefileExportOperationID == operationID,
              !isCancellingMeshShapefileExport else { return }
        isCancellingMeshShapefileExport = true
        if activeMeshShapefileExportProvider?.cancelExport(operationID: operationID) == false,
           activeMeshShapefileExportOwner != nil {
            meshToolsError = L10n.text("The export cancellation could not be delivered; waiting for the file writer to finish.")
        }
    }

    private func removeMeshElementFindTarget() {
        if let meshElementFind, selectedMapTargetID == meshElementFind.targetID {
            selectedMapTargetID = nil
        }
        meshElementFind = nil
    }

    var flowAreas: [GeometryMeshFlowAreaRow] { snapshot?.flowAreas ?? [] }
    var regions: GeometryTopologyFeatureTable {
        snapshot?.regions ?? GeometryTopologyFeatureTable(featureKind: "region", columns: [], editableFields: [], rows: [])
    }
    /// A single selected FlowArea can be edited in the property inspector;
    /// multiple source rows remain selected in the table without implying
    /// that one of them owns the inspector values.
    var selectedFlowAreaID: String? {
        guard selectedFlowAreaIDs.count == 1 else { return nil }
        return selectedFlowAreaIDs.first
    }
    var selectedFlowArea: GeometryMeshFlowAreaRow? {
        guard let id = selectedFlowAreaID else { return nil }
        return flowAreas.first { $0.id == id }
    }
    var selectedRegions: [GeometryTopologyFeatureRow] {
        regions.rows.filter { selectedRegionIDs.contains($0.fid) }
    }
    var selectedRegionFIDsInSourceOrder: [Int] { selectedRegions.map(\.fid) }

    /// Parent calls this before changing models or starting a fresh draft.
    /// Generation guards make late reads, edits, and save callbacks harmless.
    func invalidate() {
        guard !hasUnsavedDiagnosticsPreferences, !isSavingDiagnosticsPreferences else {
            diagnosticsPreferencesError = L10n.text("Save or discard mesh diagnostics settings before switching assets.")
            return
        }
        clearMeshElementFindTarget()
        if let activeMeshShapefileExportOperationID {
            requestMeshShapefileExportCancellation(operationID: activeMeshShapefileExportOperationID)
        }
        abandonMeshGenerationOperation()
        abandonPropertyTablesOperation()
        loadGeneration += 1
        modelGeneration += 1
        let hadDraft = isDirty
        currentAsset = nil
        currentModel = nil
        expectedSourceRevision = nil
        loadedTopologyDraftState = nil
        didLoad = false
        activeParentSaveID = nil
        snapshot = nil
        meshGenerationResultIdentity = nil
        meshGenerationTerminalIdentity = nil
        selectedRegionIDs = []
        selectedFlowAreaIDs = []
        selectedMapTargetID = nil
        degreeScan = nil
        isLoading = false
        isEditing = false
        isScanningDegreeErrors = false
        parentSaveInProgress = false
        error = nil
        invalidateDiagnosticsPreferences()
        if hadDraft { onParentDraftChange(false) }
    }

    /// Installs the selected map's persisted FlowAreaLayer visual-context
    /// settings. A dirty scope must be explicitly saved or discarded first;
    /// switching maps never silently transfers settings to another layer.
    @discardableResult
    func installDiagnosticsPreferences(_ settings: MeshDiagnosticsVisualSettings,
                                       scope: GeometryMeshDiagnosticsScope) -> Bool {
        guard currentAsset?.id == scope.assetID else { return false }
        if diagnosticsPreferencesScope == scope {
            diagnosticsPreferencesScopeMismatch = false
            pendingDiagnosticsPreferencesInstall = nil
            if hasUnsavedDiagnosticsPreferences { return diagnosticsPreferences == Self.normalized(settings) }
            let normalizedSettings = Self.normalized(settings)
            let changed = diagnosticsPreferences != normalizedSettings
            diagnosticsPreferencesBaseline = normalizedSettings
            diagnosticsPreferences = diagnosticsPreferencesBaseline
            if changed { refreshDegreeScanForInstalledSettings() }
            return true
        }
        guard !hasUnsavedDiagnosticsPreferences, !isSavingDiagnosticsPreferences else {
            pendingDiagnosticsPreferencesInstall = (Self.normalized(settings), scope)
            diagnosticsPreferencesScopeMismatch = true
            diagnosticsPreferencesError = L10n.text("Save or discard mesh diagnostics settings before switching maps.")
            return false
        }
        diagnosticsPreferencesGeneration += 1
        activeDiagnosticsPreferencesSaveID = nil
        diagnosticsPreferencesScope = scope
        diagnosticsPreferencesBaseline = Self.normalized(settings)
        diagnosticsPreferences = diagnosticsPreferencesBaseline
        isSavingDiagnosticsPreferences = false
        diagnosticsPreferencesScopeMismatch = false
        pendingDiagnosticsPreferencesInstall = nil
        diagnosticsPreferencesError = nil
        updateDiagnosticsPreferencesDirtyState()
        refreshDegreeScanForInstalledSettings()
        return true
    }

    func setCheckMeshErrors(_ enabled: Bool) async {
        guard diagnosticsPreferencesScope?.assetID == currentAsset?.id,
              !diagnosticsPreferencesScopeMismatch, !isSavingDiagnosticsPreferences,
              !parentSaveInProgress, !isLoading, !isEditing else { return }
        guard diagnosticsPreferences.checkMeshErrors != enabled else { return }
        setDiagnosticsPreferences(MeshDiagnosticsVisualSettings(checkMeshErrors: enabled,
            maxFacesPerNode: diagnosticsPreferences.maxFacesPerNode))
        if enabled {
            await scanDegreeErrors()
        } else {
            degreeScan = nil
            clearSelectedDegreeIssue()
        }
    }

    /// The source MaxFacesPerNodeEntry rounds halfway cases away from zero,
    /// then clamps the persisted integer to its supported [3, 64] range.
    func setMaxFacesPerNodeEntry(_ value: Double) async {
        guard let threshold = Self.normalizedMaxFacesPerNodeEntry(value),
              diagnosticsPreferencesScope?.assetID == currentAsset?.id,
              !diagnosticsPreferencesScopeMismatch, !isSavingDiagnosticsPreferences,
              !parentSaveInProgress, !isLoading, !isEditing else { return }
        guard diagnosticsPreferences.maxFacesPerNode != threshold else { return }
        setDiagnosticsPreferences(MeshDiagnosticsVisualSettings(
            checkMeshErrors: diagnosticsPreferences.checkMeshErrors,
            maxFacesPerNode: threshold))
        if diagnosticsPreferences.checkMeshErrors { await scanDegreeErrors() }
    }

    func beginDiagnosticsPreferencesSave() -> GeometryMeshDiagnosticsPreferencesCapture? {
        guard canBeginDiagnosticsPreferencesSave,
              let scope = diagnosticsPreferencesScope else { return nil }
        let operationID = UUID()
        activeDiagnosticsPreferencesSaveID = operationID
        isSavingDiagnosticsPreferences = true
        diagnosticsPreferencesError = nil
        return GeometryMeshDiagnosticsPreferencesCapture(operationID: operationID,
            generation: diagnosticsPreferencesGeneration, scope: scope, settings: diagnosticsPreferences)
    }

    func acceptDiagnosticsPreferencesSave(_ capture: GeometryMeshDiagnosticsPreferencesCapture,
                                           newSourceRevision: String) {
        guard diagnosticsPreferencesCaptureIsCurrent(capture) else { return }
        let pendingInstall = pendingDiagnosticsPreferencesInstall
        diagnosticsPreferencesBaseline = capture.settings
        diagnosticsPreferencesScope = GeometryMeshDiagnosticsScope(
            mapIndex: capture.scope.mapIndex, mapName: capture.scope.mapName,
            mapType: capture.scope.mapType, geometryName: capture.scope.geometryName,
            assetID: capture.scope.assetID, visualizationRevision: newSourceRevision)
        activeDiagnosticsPreferencesSaveID = nil
        isSavingDiagnosticsPreferences = false
        diagnosticsPreferencesError = nil
        updateDiagnosticsPreferencesDirtyState()
        if let pendingInstall {
            applyDiagnosticsPreferencesInstall(pendingInstall.settings, scope: pendingInstall.scope,
                visualizationRevision: newSourceRevision)
        }
    }

    func diagnosticsPreferencesSaveFailed(_ capture: GeometryMeshDiagnosticsPreferencesCapture,
                                          message: String? = nil) {
        guard diagnosticsPreferencesCaptureIsCurrent(capture) else { return }
        activeDiagnosticsPreferencesSaveID = nil
        isSavingDiagnosticsPreferences = false
        diagnosticsPreferencesError = message.map(L10n.text)
    }

    /// Parent calls this only after its save/discard guard has accepted a
    /// context switch. Old asynchronous save callbacks are invalidated.
    func invalidateDiagnosticsPreferences() {
        diagnosticsPreferencesGeneration += 1
        let wasDirty = hasUnsavedDiagnosticsPreferences
        activeDiagnosticsPreferencesSaveID = nil
        diagnosticsPreferencesScope = nil
        diagnosticsPreferencesBaseline = MeshDiagnosticsVisualSettings()
        diagnosticsPreferences = diagnosticsPreferencesBaseline
        hasUnsavedDiagnosticsPreferences = false
        isSavingDiagnosticsPreferences = false
        diagnosticsPreferencesScopeMismatch = false
        pendingDiagnosticsPreferencesInstall = nil
        diagnosticsPreferencesError = nil
        if wasDirty { onDiagnosticsPreferencesChange(false) }
    }

    func discardDiagnosticsPreferences() {
        guard !isSavingDiagnosticsPreferences else { return }
        let wasDirty = hasUnsavedDiagnosticsPreferences
        let pendingInstall = pendingDiagnosticsPreferencesInstall
        diagnosticsPreferences = diagnosticsPreferencesBaseline
        diagnosticsPreferencesError = nil
        if wasDirty {
            hasUnsavedDiagnosticsPreferences = false
            onDiagnosticsPreferencesChange(false)
        }
        if let pendingInstall {
            applyDiagnosticsPreferencesInstall(pendingInstall.settings, scope: pendingInstall.scope,
                visualizationRevision: pendingInstall.scope.visualizationRevision)
            return
        }
        if !diagnosticsPreferences.checkMeshErrors {
            degreeScan = nil
            clearSelectedDegreeIssue()
        } else {
            Task { await scanDegreeErrors() }
        }
    }

    func ensureLoaded(asset: ProjectAsset, sourceRevision: String?, topologyDraftState: String?) async {
        guard !parentSaveInProgress else { return }
        guard asset.section == .geometries else {
            error = L10n.text("Mesh editing requires a geometry asset.")
            return
        }
        let model = provider.modelRequest(for: asset)
        let sameSource = currentAsset?.id == asset.id && currentModel == model
        let sameGeometry = currentAsset?.id == asset.id && currentModel?.assetPath == model.assetPath
            && currentModel?.kind == model.kind && currentModel?.projectPath == model.projectPath
        // Project associations are an independent XML draft. Re-evaluate the
        // same geometry ledger in that new context without retiring mesh or
        // diagnostics drafts. A different geometry/project still requires the
        // normal explicit save/discard workflow.
        if sameGeometry && !sameSource {
            modelGeneration += 1
        } else if currentAsset != nil && !sameSource {
            if isDirty {
                error = L10n.text("The geometry changed while mesh edits are pending. Discard the mesh draft before switching assets.")
                return
            }
            guard !hasUnsavedDiagnosticsPreferences, !isSavingDiagnosticsPreferences else {
                diagnosticsPreferencesError = L10n.text("Save or discard mesh diagnostics settings before switching assets.")
                return
            }
            invalidate()
        }
        if !sameSource || expectedSourceRevision != sourceRevision
            || loadedTopologyDraftState != topologyDraftState {
            clearMeshElementFindTarget()
            if let activeMeshShapefileExportOperationID {
                requestMeshShapefileExportCancellation(operationID: activeMeshShapefileExportOperationID)
            }
        }
        if didLoad, sameSource, expectedSourceRevision == sourceRevision,
           loadedTopologyDraftState == topologyDraftState { return }
        if isDirty && expectedSourceRevision != sourceRevision {
            error = L10n.text("The geometry source changed while mesh edits are pending. Save or discard the mesh draft before reloading.")
            return
        }
        currentAsset = asset
        currentModel = model
        expectedSourceRevision = sourceRevision
        await fetch(model: model, expectedRevision: sourceRevision, asset: asset,
            draftState: snapshot?.isDirty == true ? snapshot?.draftState : nil,
            topologyDraftState: topologyDraftState)
    }

    func reload() async {
        guard let model = currentModel, let asset = currentAsset else { return }
        clearMeshElementFindTarget()
        if let activeMeshShapefileExportOperationID {
            requestMeshShapefileExportCancellation(operationID: activeMeshShapefileExportOperationID)
        }
        meshGenerationResultIdentity = nil
        meshGenerationTerminalIdentity = nil
        await fetch(model: model, expectedRevision: expectedSourceRevision, asset: asset,
            draftState: snapshot?.isDirty == true ? snapshot?.draftState : nil,
            topologyDraftState: provider.currentTopologyDraftState())
    }

    func selectFlowArea(_ id: String?) {
        selectFlowAreas(id.map { Set([$0]) } ?? [])
    }

    /// Mirrors the source SelectedSet used by the FlowArea table. IDs remain
    /// exact feature identities; a selection cannot be carried to another
    /// asset or guessed from row order.
    func selectFlowAreas(_ ids: Set<String>) {
        guard ids.allSatisfy({ id in flowAreas.contains(where: { $0.id == id }) }) else { return }
        if selectedFlowAreaIDs != ids {
            clearMeshElementFindTarget()
            if let activeMeshShapefileExportOwner,
               !ids.contains(activeMeshShapefileExportOwner.flowAreaID),
               let operationID = activeMeshShapefileExportOperationID {
                requestMeshShapefileExportCancellation(operationID: operationID)
            }
        }
        selectedFlowAreaIDs = ids
    }

    func selectMapTarget(_ id: String?) {
        if let findTarget = meshElementFind?.targetID, id != findTarget {
            clearMeshElementFindTarget()
        }
        selectedMapTargetID = id
    }

    func selectDegreeIssue(_ id: String?) {
        guard id == nil || degreeScan?.issues.contains(where: { $0.id == id }) == true else { return }
        selectMapTarget(id)
    }

    func selectRegions(_ ids: Set<Int>) async {
        guard !parentSaveInProgress, !isEditing else { return }
        selectedRegionIDs = ids.intersection(Set(regions.rows.map(\.fid)))
        guard didLoad, let model = currentModel, let asset = currentAsset,
              let current = snapshot else { return }
        await fetch(model: model, expectedRevision: current.revision, asset: asset,
            draftState: isDirty ? current.draftState : nil,
            topologyDraftState: provider.currentTopologyDraftState())
    }

    func setFlowAreaField(_ row: GeometryMeshFlowAreaRow, fieldID: String, value: String) async {
        guard flowAreas.contains(where: { $0.id == row.id && $0.name == row.name }) else { return }
        await submit(GeometryMeshMutation(operation: "setFlowAreaField", flowAreaIDs: [row.id],
            expectedFlowAreaNames: [row.name], fieldID: fieldID, value: value))
    }

    func setPatchField(featureIDs: [Int], fieldID: String, value: String) async {
        guard !featureIDs.isEmpty else { return }
        await submit(GeometryMeshMutation(operation: "setPatchField", featureIDs: featureIDs,
            fieldID: fieldID, value: value))
    }

    func resizePatch(featureIDs: [Int], ratio: Double, axis: String? = nil) async {
        guard ratio == 0.5 || ratio == 2, !featureIDs.isEmpty else { return }
        await submit(GeometryMeshMutation(operation: "resizePatch", featureIDs: featureIDs,
            value: ratio == 0.5 ? "0.5" : "2", axis: axis))
    }

    func setPatchDimensionMode(featureIDs: [Int], axis: String, mode: String) async {
        guard !featureIDs.isEmpty else { return }
        await submit(GeometryMeshMutation(operation: "setPatchDimensionMode", featureIDs: featureIDs,
            value: mode, axis: axis))
    }

    func applyPatchDimension(featureIDs: [Int], axis: String, value: String) async {
        guard !featureIDs.isEmpty else { return }
        await submit(GeometryMeshMutation(operation: "applyPatchDimension", featureIDs: featureIDs,
            value: value, axis: axis))
    }

    func generateMesh(projectSessionID: UUID? = nil) async {
        guard canEdit, let current = snapshot, let model = currentModel,
              let asset = currentAsset else { return }
        let topologyState = provider.currentTopologyDraftState()
        guard topologyState == loadedTopologyDraftState else {
            error = L10n.text("The topology changed after this mesh view loaded. Reload or discard the mesh draft before generating a mesh.")
            return
        }

        clearMeshElementFindTarget()
        if let activeMeshShapefileExportOperationID {
            requestMeshShapefileExportCancellation(operationID: activeMeshShapefileExportOperationID)
        }

        let operationID = UUID()
        let operationText = operationID.uuidString.lowercased()
        let generation = loadGeneration
        let modelGeneration = self.modelGeneration
        let selected = selectedRegionIDs.sorted()
        let request = GeometryMeshGenerateRequest(model: model, revision: current.revision,
            draftState: current.draftState, topologyDraftState: topologyState,
            selectedRegionIDs: selected, operationID: operationText)

        let operation: BackendDuplexOperation<GeometryMeshOperationControl, BackendProgressUpdate,
            GeometryMeshGenerateResult>
        do {
            operation = try provider.startGenerateMesh(request)
        } catch let unsupported as CocoaError where unsupported.code == .featureUnsupported {
            // Test providers and older injected providers keep the existing
            // source-preview API; the bundled backend always uses duplex progress.
            let updated = await submit(GeometryMeshMutation(operation: "generate", operationID: operationText))
            guard generation == loadGeneration, modelGeneration == self.modelGeneration,
                  currentAsset?.id == asset.id, currentModel == model,
                  provider.modelRequest(for: asset) == model, !Task.isCancelled else { return }
            meshGenerationTerminalIdentity = operationText
            if let updated {
                recordMeshGenerationHistory(updated, operationID: operationText)
            }
            return
        } catch {
            self.error = localizedError(error)
            meshGenerationTerminalIdentity = operationText
            return
        }

        activeMeshGenerationOperationID = operationID
        activeMeshGenerationOperation = operation
        activeMeshGenerationControlSequence = 0
        activeMeshGenerationProjectSessionID = projectSessionID
        activeMeshGenerationTopologyDraftState = topologyState
        meshGenerationOperationID = operationID
        meshGenerationSourceRevision = current.revision
        isGeneratingMesh = true
        isCancellingMeshGeneration = false
        isEditing = true
        meshGenerationProgress = nil
        meshGenerationOutcome = nil
        error = nil

        defer {
            if activeMeshGenerationOperationID == operationID {
                activeMeshGenerationOperation = nil
                activeMeshGenerationOperationID = nil
                activeMeshGenerationProjectSessionID = nil
                activeMeshGenerationTopologyDraftState = nil
                meshGenerationOperationID = nil
                meshGenerationSourceRevision = nil
                isGeneratingMesh = false
                isCancellingMeshGeneration = false
                isEditing = false
            }
        }

        do {
            var contextWasInvalidated = false
            for try await event in operation.events {
                guard meshGenerationContextIsCurrent(operationID: operationID, projectSessionID: projectSessionID,
                      generation: generation, modelGeneration: modelGeneration, asset: asset, model: model,
                      source: current, topologyState: topologyState, selectedRegionIDs: selected) else {
                    contextWasInvalidated = true
                    requestMeshGenerationCancellation(operation, operationID: operationID)
                    continue
                }
                meshGenerationProgress = event
            }
            let result = try await operation.value()
            guard !contextWasInvalidated,
                  meshGenerationContextIsCurrent(operationID: operationID, projectSessionID: projectSessionID,
                    generation: generation, modelGeneration: modelGeneration, asset: asset, model: model,
                    source: current, topologyState: topologyState, selectedRegionIDs: selected) else { return }
            meshGenerationTerminalIdentity = operationText
            guard result.operationID == operationText, result.revision == current.revision,
                  result.snapshot.revision == current.revision,
                  result.snapshot.selectedRegionIDs == selected else {
                error = L10n.text("The generated mesh result did not match the current geometry revision and selection. Reload the geometry before continuing.")
                return
            }
            if result.snapshot.draftState != current.draftState {
                guard result.snapshot.isDirty else {
                    error = L10n.text("The generated mesh result did not contain a valid geometry draft. Reload the geometry before continuing.")
                    return
                }
                snapshot = result.snapshot
                if result.snapshot.generationReport?.meshWasReplaced == true {
                    meshGenerationResultIdentity = operationText
                }
                expectedSourceRevision = result.snapshot.revision
                loadedTopologyDraftState = topologyState
                onParentDraftChange(result.snapshot.isDirty)
            }
            meshGenerationOutcome = result.cancelled ? "cancelled" : "completed"
            recordMeshGenerationHistory(result.snapshot, operationID: operationText)
        } catch {
            guard meshGenerationContextIsCurrent(operationID: operationID, projectSessionID: projectSessionID,
                  generation: generation, modelGeneration: modelGeneration, asset: asset, model: model,
                  source: current, topologyState: topologyState, selectedRegionIDs: selected) else { return }
            meshGenerationTerminalIdentity = operationText
            self.error = localizedError(error)
        }
    }

    func cancelMeshGeneration() {
        guard isGeneratingMesh, !isCancellingMeshGeneration,
              let activeMeshGenerationOperation,
              let operationID = activeMeshGenerationOperationID else { return }
        requestMeshGenerationCancellation(activeMeshGenerationOperation, operationID: operationID)
    }

    /// Retains a prepare request in the child ledger. The parent performs the
    /// source operation on its staged model together with every other geometry
    /// draft and publishes one HDF only if the full source Prepare succeeds.
    func requestPrepare() async -> Bool {
        guard canEdit else { return false }
        if preparePending { return true }
        await submit(GeometryMeshMutation(operation: "prepare"))
        return preparePending
    }

    /// Runs the retained source FlowAreaLayer.ComputePropertyTablesAsync
    /// against the exact loaded geometry and child drafts. The successful
    /// result remains in this child draft and is replayed against the parent
    /// staged HDF when the user saves the geometry.
    @discardableResult
    func computePropertyTables() async -> Bool {
        guard canComputePropertyTables, let current = snapshot, let model = currentModel,
              let asset = currentAsset else { return false }
        let topologyState = provider.currentTopologyDraftState()
        guard topologyState == loadedTopologyDraftState else {
            error = L10n.text("The topology changed after this mesh view loaded. Reload or discard the mesh draft before computing property tables.")
            return false
        }

        clearMeshElementFindTarget()
        if let activeMeshShapefileExportOperationID {
            requestMeshShapefileExportCancellation(operationID: activeMeshShapefileExportOperationID)
        }

        let operationID = UUID()
        let generation = loadGeneration
        let modelGeneration = self.modelGeneration
        let selected = selectedRegionIDs.sorted()
        let request = GeometryMeshPropertyTablesRequest(model: model, revision: current.revision,
            draftState: current.draftState, topologyDraftState: topologyState,
            selectedRegionIDs: selected)
        activePropertyTablesOperationID = operationID
        propertyTablesControlSequence = 0
        isComputingPropertyTables = true
        isCancellingPropertyTables = false
        isEditing = true
        propertyTablesProgress = nil
        propertyTablesMessages = []
        propertyTablesOutcome = nil
        error = nil

        defer {
            if activePropertyTablesOperationID == operationID {
                activePropertyTablesOperation = nil
                activePropertyTablesOperationID = nil
                isComputingPropertyTables = false
                isCancellingPropertyTables = false
                isEditing = false
            }
        }

        do {
            let operation = try provider.startComputePropertyTables(request)
            guard propertyTablesContextIsCurrent(operationID: operationID, generation: generation,
                  modelGeneration: modelGeneration, asset: asset, model: model,
                  source: current, topologyState: topologyState, selectedRegionIDs: selected) else {
                operation.cancel()
                return false
            }
            activePropertyTablesOperation = operation
            for try await event in operation.events {
                guard propertyTablesContextIsCurrent(operationID: operationID, generation: generation,
                      modelGeneration: modelGeneration, asset: asset, model: model,
                      source: current, topologyState: topologyState, selectedRegionIDs: selected) else {
                    operation.cancel()
                    return false
                }
                propertyTablesProgress = event
            }
            let result = try await operation.value()
            guard propertyTablesContextIsCurrent(operationID: operationID, generation: generation,
                  modelGeneration: modelGeneration, asset: asset, model: model,
                  source: current, topologyState: topologyState, selectedRegionIDs: selected) else { return false }

            propertyTablesMessages = result.messages
            propertyTablesOutcome = result.succeeded ? "succeeded" : (result.cancelled ? "cancelled" : nil)
            guard result.succeeded else {
                if !result.cancelled {
                    let details = result.messages.filter { !$0.isEmpty }.joined(separator: "\n")
                    error = L10n.text(details.isEmpty
                        ? "The source could not compute property tables for this geometry."
                        : details)
                }
                return false
            }

            guard result.snapshot.revision == current.revision,
                  result.snapshot.selectedRegionIDs == selected,
                  result.snapshot.isDirty,
                  result.snapshot.draftState != current.draftState else {
                error = L10n.text("The property-table result did not match the current geometry draft. Reload the geometry before continuing.")
                return false
            }
            snapshot = result.snapshot
            expectedSourceRevision = result.snapshot.revision
            loadedTopologyDraftState = topologyState
            onParentDraftChange(result.snapshot.isDirty)
            return true
        } catch {
            guard propertyTablesContextIsCurrent(operationID: operationID, generation: generation,
                  modelGeneration: modelGeneration, asset: asset, model: model,
                  source: current, topologyState: topologyState, selectedRegionIDs: selected) else { return false }
            self.error = localizedError(error)
            return false
        }
    }

    func cancelPropertyTables() {
        guard isComputingPropertyTables, !isCancellingPropertyTables,
              let operation = activePropertyTablesOperation else { return }
        propertyTablesControlSequence &+= 1
        do {
            try operation.sendControl(.cancel, sequence: propertyTablesControlSequence)
            isCancellingPropertyTables = true
        } catch {
            self.error = localizedError(error)
        }
    }

    func scanDegreeErrors() async {
        await scanDegreeErrors(maxFacesPerNode: diagnosticsPreferences.maxFacesPerNode)
    }

    func scanDegreeErrors(maxFacesPerNode: Int) async {
        guard canScanDegreeErrors, let current = snapshot, let model = currentModel,
              let asset = currentAsset else { return }
        let generation = loadGeneration
        let modelGeneration = self.modelGeneration
        let revision = current.revision
        let topologyState = provider.currentTopologyDraftState()
        guard topologyState == loadedTopologyDraftState else {
            error = L10n.text("The topology changed after this mesh view loaded. Reload or discard the mesh draft before scanning.")
            return
        }
        isEditing = true
        isScanningDegreeErrors = true
        error = nil
        defer {
            if generation == loadGeneration && modelGeneration == self.modelGeneration {
                isEditing = false
                isScanningDegreeErrors = false
            }
        }
        do {
        let result = try await provider.scanDegreeErrors(model, revision: revision,
                draftState: current.draftState, topologyDraftState: topologyState,
                maxFacesPerNode: min(64, max(3, maxFacesPerNode)))
            guard generation == loadGeneration, modelGeneration == self.modelGeneration,
                  currentAsset?.id == asset.id, currentModel == model,
                  snapshot?.draftState == current.draftState, !Task.isCancelled else { return }
            degreeScan = result
            if let selectedMapTargetID,
               selectedMapTargetID.hasPrefix("flow-area-row:"),
               selectedMapTargetID.contains(":node:"),
               !result.issues.contains(where: { $0.id == selectedMapTargetID }) {
                self.selectedMapTargetID = nil
            }
        } catch {
            guard generation == loadGeneration, modelGeneration == self.modelGeneration,
                  currentAsset?.id == asset.id, currentModel == model, !Task.isCancelled else { return }
            self.error = localizedError(error)
        }
    }

    /// Reads the current generated child draft through the existing
    /// geometry.mesh.degreeErrors service without changing the mesh editor's
    /// independent degreeScan, selected map target, or diagnostics controls.
    /// The opaque draft and generation identity are captured before the request
    /// and revalidated afterward, so a newer mesh can never receive old rows.
    func scanDegreeErrorsForMapOverlay(sourceRevision: String,
                                       draftState: String,
                                       generationResultIdentity: String,
                                       maxFacesPerNode: Int) async throws -> GeometryMeshDegreeScan? {
        guard canScanDegreeErrors, !isGeneratingMesh, !isComputingPropertyTables,
              !isScanningDegreeErrors, let current = snapshot, let model = currentModel,
              let asset = currentAsset, current.revision == sourceRevision,
              current.draftState == draftState, current.isDirty,
              current.generationReport?.meshWasReplaced == true,
              current.map != nil,
              meshGenerationResultIdentity == generationResultIdentity,
              provider.currentTopologyDraftState() == loadedTopologyDraftState else { return nil }

        let loadToken = loadGeneration
        let modelToken = modelGeneration
        let topologyState = provider.currentTopologyDraftState()
        let scan = try await provider.scanDegreeErrorsForMapOverlay(model, revision: sourceRevision,
            draftState: draftState, topologyDraftState: topologyState,
            maxFacesPerNode: min(64, max(3, maxFacesPerNode)))

        guard !Task.isCancelled, loadGeneration == loadToken, modelGeneration == modelToken,
              currentAsset?.id == asset.id, currentModel == model,
              snapshot?.revision == sourceRevision, snapshot?.draftState == draftState,
              snapshot?.generationReport?.meshWasReplaced == true,
              meshGenerationResultIdentity == generationResultIdentity,
              provider.currentTopologyDraftState() == topologyState else { return nil }
        return scan
    }

    func beginParentSave() -> GeometryMeshParentSaveCapture? {
        guard canBeginParentSave else { return nil }
        clearMeshElementFindTarget()
        if let activeMeshShapefileExportOperationID {
            requestMeshShapefileExportCancellation(operationID: activeMeshShapefileExportOperationID)
        }
        let operationID = UUID()
        activeParentSaveID = operationID
        parentSaveInProgress = true
        return GeometryMeshParentSaveCapture(operationID: operationID, generation: modelGeneration,
            assetID: currentAsset?.id, draftState: geometryMeshStateForParentSave,
            sourceRevision: snapshot?.revision ?? expectedSourceRevision)
    }

    /// The parent has atomically committed the source file. Clear the captured
    /// state before reloading so read errors never leave a replayable old ledger.
    func acknowledgeParentSave(_ capture: GeometryMeshParentSaveCapture, newSourceRevision: String?) async {
        guard parentCaptureIsCurrent(capture) else { return }
        guard let asset = currentAsset, let model = currentModel else {
            releaseParentSave(capture)
            return
        }
        guard geometryMeshStateForParentSave == capture.draftState else {
            releaseParentSave(capture)
            return
        }
        let hadCapturedDraft = capture.draftState != nil
        expectedSourceRevision = newSourceRevision
        loadedTopologyDraftState = provider.currentTopologyDraftState()
        didLoad = false
        if let current = snapshot {
            snapshot = GeometryMeshSnapshot(revision: newSourceRevision ?? current.revision,
                draftState: current.draftState, topologyFingerprint: current.topologyFingerprint,
                canEdit: current.canEdit, isDirty: false, flowAreas: current.flowAreas,
                regions: current.regions, selectedRegionIDs: current.selectedRegionIDs,
                patchSizing: current.patchSizing, generationReport: current.generationReport,
                prepareSummary: current.prepareSummary, map: current.map, preparePending: false)
        }
        if hadCapturedDraft { onParentDraftChange(false) }
        await fetch(model: model, expectedRevision: newSourceRevision, asset: asset,
            draftState: nil, topologyDraftState: loadedTopologyDraftState)
        releaseParentSave(capture)
    }

    func parentSaveFailed(_ capture: GeometryMeshParentSaveCapture) {
        guard parentCaptureIsCurrent(capture) else { return }
        releaseParentSave(capture)
    }

    func discardDraft() async {
        guard !parentSaveInProgress else { return }
        clearMeshElementFindTarget()
        if let activeMeshShapefileExportOperationID {
            requestMeshShapefileExportCancellation(operationID: activeMeshShapefileExportOperationID)
        }
        abandonPropertyTablesOperation()
        let hadDraft = isDirty
        loadGeneration += 1
        isEditing = false
        isScanningDegreeErrors = false
        isLoading = false
        didLoad = false
        snapshot = nil
        meshGenerationResultIdentity = nil
        meshGenerationTerminalIdentity = nil
        degreeScan = nil
        selectedRegionIDs = []
        selectedMapTargetID = nil
        expectedSourceRevision = nil
        loadedTopologyDraftState = nil
        error = nil
        if hadDraft { onParentDraftChange(false) }
        await reload(expectedRevision: nil)
    }

    private func fetch(model: GeometryMeshModelRequest, expectedRevision: String?, asset: ProjectAsset,
                       draftState: String?, topologyDraftState: String?) async {
        if isGeneratingMesh { abandonMeshGenerationOperation() }
        if isComputingPropertyTables { abandonPropertyTablesOperation() }
        loadGeneration += 1
        let generation = loadGeneration
        let modelGeneration = self.modelGeneration
        // A new source read supersedes any in-flight degree scan. The stale
        // scan is generation-guarded and must not leave the page permanently busy.
        if isScanningDegreeErrors {
            isScanningDegreeErrors = false
            isEditing = false
        }
        isLoading = true
        error = nil
        defer { if generation == loadGeneration { isLoading = false } }
        do {
            let loaded = try await provider.load(model, expectedRevision: expectedRevision,
                draftState: draftState, topologyDraftState: topologyDraftState,
                selectedRegionIDs: selectedRegionFIDsInSourceOrder)
            guard generation == loadGeneration, modelGeneration == self.modelGeneration,
                  currentAsset?.id == asset.id, currentModel == model,
                  !Task.isCancelled else { return }
            snapshot = loaded
            expectedSourceRevision = loaded.revision
            loadedTopologyDraftState = topologyDraftState
            didLoad = true
            selectedRegionIDs.formIntersection(Set(loaded.regions.rows.map(\.fid)))
            selectedFlowAreaIDs.formIntersection(Set(loaded.flowAreas.map(\.id)))
        } catch {
            guard generation == loadGeneration, modelGeneration == self.modelGeneration,
                  currentAsset?.id == asset.id, currentModel == model,
                  !Task.isCancelled else { return }
            self.error = localizedError(error)
            didLoad = false
        }
    }

    @discardableResult
    private func submit(_ mutation: GeometryMeshMutation) async -> GeometryMeshSnapshot? {
        guard canEdit, let current = snapshot, let model = currentModel,
              let assetID = currentAsset?.id else { return nil }
        let topologyState = provider.currentTopologyDraftState()
        guard topologyState == loadedTopologyDraftState else {
            error = L10n.text("The topology changed after this mesh view loaded. Reload or discard the mesh draft before editing.")
            return nil
        }
        clearMeshElementFindTarget()
        if let activeMeshShapefileExportOperationID {
            requestMeshShapefileExportCancellation(operationID: activeMeshShapefileExportOperationID)
        }
        let generation = loadGeneration
        let modelGeneration = self.modelGeneration
        isEditing = true
        error = nil
        defer { if generation == loadGeneration && modelGeneration == self.modelGeneration { isEditing = false } }
        do {
            let updated = try await provider.edit(model, revision: current.revision,
                draftState: current.draftState, topologyDraftState: topologyState,
                mutation: mutation, selectedRegionIDs: selectedRegionIDs.sorted())
            guard generation == loadGeneration, modelGeneration == self.modelGeneration,
                  currentAsset?.id == assetID, currentModel == model,
                  snapshot?.draftState == current.draftState, !Task.isCancelled else { return nil }
            snapshot = updated
            expectedSourceRevision = updated.revision
            loadedTopologyDraftState = topologyState
            let selectedWasIssue = degreeScan?.issues.contains(where: { $0.id == selectedMapTargetID }) == true
            degreeScan = nil
            if selectedWasIssue { selectedMapTargetID = nil }
            onParentDraftChange(updated.isDirty)
            return updated
        } catch {
            guard generation == loadGeneration, modelGeneration == self.modelGeneration,
                  currentAsset?.id == assetID, currentModel == model, !Task.isCancelled else { return nil }
            self.error = localizedError(error)
            return nil
        }
    }

    private static func normalized(_ settings: MeshDiagnosticsVisualSettings) -> MeshDiagnosticsVisualSettings {
        MeshDiagnosticsVisualSettings(checkMeshErrors: settings.checkMeshErrors,
            maxFacesPerNode: min(64, max(3, settings.maxFacesPerNode)))
    }

    static func normalizedMaxFacesPerNodeEntry(_ value: Double) -> Int? {
        guard value.isFinite else { return nil }
        return Int(min(64, max(3, value)).rounded(.toNearestOrAwayFromZero))
    }

    private func setDiagnosticsPreferences(_ settings: MeshDiagnosticsVisualSettings) {
        diagnosticsPreferences = Self.normalized(settings)
        diagnosticsPreferencesError = nil
        updateDiagnosticsPreferencesDirtyState()
    }

    private func applyDiagnosticsPreferencesInstall(_ settings: MeshDiagnosticsVisualSettings,
                                                     scope: GeometryMeshDiagnosticsScope,
                                                     visualizationRevision: String?) {
        diagnosticsPreferencesGeneration += 1
        activeDiagnosticsPreferencesSaveID = nil
        diagnosticsPreferencesScope = GeometryMeshDiagnosticsScope(
            mapIndex: scope.mapIndex, mapName: scope.mapName, mapType: scope.mapType,
            geometryName: scope.geometryName, assetID: scope.assetID,
            visualizationRevision: visualizationRevision)
        diagnosticsPreferencesBaseline = Self.normalized(settings)
        diagnosticsPreferences = diagnosticsPreferencesBaseline
        isSavingDiagnosticsPreferences = false
        diagnosticsPreferencesScopeMismatch = false
        pendingDiagnosticsPreferencesInstall = nil
        diagnosticsPreferencesError = nil
        updateDiagnosticsPreferencesDirtyState()
        refreshDegreeScanForInstalledSettings()
    }

    private func refreshDegreeScanForInstalledSettings() {
        guard diagnosticsPreferences.checkMeshErrors else {
            degreeScan = nil
            clearSelectedDegreeIssue()
            return
        }
        Task { await scanDegreeErrors() }
    }

    private func updateDiagnosticsPreferencesDirtyState() {
        let dirty = diagnosticsPreferences != diagnosticsPreferencesBaseline
        guard dirty != hasUnsavedDiagnosticsPreferences else { return }
        hasUnsavedDiagnosticsPreferences = dirty
        onDiagnosticsPreferencesChange(dirty)
    }

    private func diagnosticsPreferencesCaptureIsCurrent(_ capture: GeometryMeshDiagnosticsPreferencesCapture) -> Bool {
        activeDiagnosticsPreferencesSaveID == capture.operationID
            && diagnosticsPreferencesGeneration == capture.generation
            && diagnosticsPreferencesScope == capture.scope
    }

    private func clearSelectedDegreeIssue() {
        if let selectedMapTargetID, selectedMapTargetID.contains(":node:") {
            self.selectedMapTargetID = nil
        }
    }

    private func parentCaptureIsCurrent(_ capture: GeometryMeshParentSaveCapture) -> Bool {
        activeParentSaveID == capture.operationID && modelGeneration == capture.generation
            && currentAsset?.id == capture.assetID
    }

    private func propertyTablesContextIsCurrent(operationID: UUID, generation: Int,
        modelGeneration: Int, asset: ProjectAsset, model: GeometryMeshModelRequest,
        source: GeometryMeshSnapshot, topologyState: String?, selectedRegionIDs: [Int]) -> Bool {
        activePropertyTablesOperationID == operationID
            && generation == loadGeneration && modelGeneration == self.modelGeneration
            && currentAsset?.id == asset.id && currentModel == model
            && provider.modelRequest(for: asset) == model
            && expectedSourceRevision == source.revision
            && snapshot?.revision == source.revision && snapshot?.draftState == source.draftState
            && provider.currentTopologyDraftState() == topologyState
            && loadedTopologyDraftState == topologyState
            && self.selectedRegionIDs.sorted() == selectedRegionIDs
            && !Task.isCancelled
    }

    private func meshGenerationContextIsCurrent(operationID: UUID, projectSessionID: UUID?, generation: Int,
        modelGeneration: Int, asset: ProjectAsset, model: GeometryMeshModelRequest,
        source: GeometryMeshSnapshot, topologyState: String?, selectedRegionIDs: [Int]) -> Bool {
        activeMeshGenerationOperationID == operationID
            && activeMeshGenerationProjectSessionID == projectSessionID
            && generation == loadGeneration && modelGeneration == self.modelGeneration
            && currentAsset?.id == asset.id && currentModel == model
            && provider.modelRequest(for: asset) == model
            && expectedSourceRevision == source.revision
            && snapshot?.revision == source.revision && snapshot?.draftState == source.draftState
            && provider.currentTopologyDraftState() == topologyState
            && loadedTopologyDraftState == topologyState
            && self.selectedRegionIDs.sorted() == selectedRegionIDs
            && !Task.isCancelled
    }

    private func requestMeshGenerationCancellation(
        _ operation: BackendDuplexOperation<GeometryMeshOperationControl, BackendProgressUpdate,
            GeometryMeshGenerateResult>, operationID: UUID) {
        guard activeMeshGenerationOperationID == operationID,
              !isCancellingMeshGeneration else { return }
        activeMeshGenerationControlSequence &+= 1
        do {
            try operation.sendControl(.cancel, sequence: activeMeshGenerationControlSequence)
            isCancellingMeshGeneration = true
        } catch {
            self.error = localizedError(error)
            operation.cancel()
        }
    }

    private func abandonMeshGenerationOperation() {
        guard let operation = activeMeshGenerationOperation,
              let operationID = activeMeshGenerationOperationID else { return }
        requestMeshGenerationCancellation(operation, operationID: operationID)
        activeMeshGenerationOperation = nil
        activeMeshGenerationOperationID = nil
        activeMeshGenerationProjectSessionID = nil
        activeMeshGenerationTopologyDraftState = nil
        meshGenerationOperationID = nil
        meshGenerationSourceRevision = nil
        isGeneratingMesh = false
        isCancellingMeshGeneration = false
        isEditing = false
        meshGenerationProgress = nil
        meshGenerationOutcome = nil
    }

    private func recordMeshGenerationHistory(_ updated: GeometryMeshSnapshot, operationID: String) {
        guard let event = updated.diagnosticHistoryEvent,
              event.operationID == operationID,
              let assetID = currentAsset?.id else { return }
        GeometryMeshDiagnosticsHistory.shared.record(event, assetID: assetID,
            geometryName: diagnosticsPreferencesScope?.geometryName ?? currentAsset?.name
                ?? URL(fileURLWithPath: currentModel?.assetPath ?? "").deletingPathExtension().lastPathComponent)
    }

    private func abandonPropertyTablesOperation() {
        activePropertyTablesOperation?.cancel()
        activePropertyTablesOperation = nil
        activePropertyTablesOperationID = nil
        isComputingPropertyTables = false
        isCancellingPropertyTables = false
        isEditing = false
        propertyTablesProgress = nil
        propertyTablesMessages = []
        propertyTablesOutcome = nil
    }

    private func releaseParentSave(_ capture: GeometryMeshParentSaveCapture) {
        guard parentCaptureIsCurrent(capture) else { return }
        activeParentSaveID = nil
        parentSaveInProgress = false
    }

    private func reload(expectedRevision: String?) async {
        guard let model = currentModel, let asset = currentAsset else { return }
        await fetch(model: model, expectedRevision: expectedRevision, asset: asset,
            draftState: nil, topologyDraftState: provider.currentTopologyDraftState())
    }

    private func localizedError(_ error: Error) -> String {
        let message = error.localizedDescription
        let prepareFailurePrefix = "Geometry preparation failed."
        guard message.hasPrefix(prepareFailurePrefix) else { return L10n.text(message) }

        var localized = L10n.text(prepareFailurePrefix) + String(message.dropFirst(prepareFailurePrefix.count))
        let logLabel = "Prepare log:"
        if let range = localized.range(of: logLabel) {
            localized.replaceSubrange(range, with: L10n.text(logLabel))
        }
        return localized
    }

    private static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
