import Foundation
import RASWorkspaceCore

private final class SpatialGridImportCancelSender: @unchecked Sendable {
    private let lock = NSLock()
    private let operation: BackendDuplexOperation<DssGridImportControl,
        BackendProgressUpdate, DssGridImportDuplexResult>
    private var sent = false
    private var sequence: UInt64 = 0

    init(operation: BackendDuplexOperation<DssGridImportControl,
         BackendProgressUpdate, DssGridImportDuplexResult>) {
        self.operation = operation
    }

    func cancel() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !sent else { return true }
        sequence &+= 1
        do {
            try operation.sendControl(.cancel, sequence: sequence)
            sent = true
            return true
        } catch {
            // Never terminate the child as a cancellation fallback. It may
            // already have committed the model and still need to return it.
            return false
        }
    }
}

@MainActor
final class BackendModelProvider: ModelEditorProvider, PlanPrecomputeProvider {
    let client: BackendProcessClient
    private(set) var project: ProjectDocument?
    private var coreLayerContextProvider: @MainActor () -> CoreLayerRequestContext? = { nil }
    init(client: BackendProcessClient? = nil) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
    }
    func setProject(_ document: ProjectDocument?) { project = document }
    func setCoreLayerContextProvider(_ provider: @escaping @MainActor () -> CoreLayerRequestContext?) {
        coreLayerContextProvider = provider
    }
    func captureCoreLayerContext() -> CoreLayerRequestContext? { coreLayerContextProvider() }
    var supportsProjectContextRefresh: Bool { true }
    func refreshProjectContext(_ asset: ProjectAsset, edits: EditorEdits) async throws -> EditorContextRefresh {
        struct Response: Decodable, Sendable { let baseline: ModelSnapshot; let draft: ModelSnapshot }
        guard asset.section == .plans else { throw CocoaError(.featureUnsupported) }
        let result = try await client.request("model.refreshPlanContext", parameters: try saveRequest(asset, changes: edits), as: Response.self)
        return try .init(baseline: result.baseline.editorSnapshot, draft: result.draft.editorSnapshot)
    }
    func catalogSurfaceLayers(_ assets: [ProjectAsset]) async throws -> [SurfaceCatalogEntry] {
        struct Request: Encodable, Sendable { let assetPaths: [String] }
        let paths = assets.filter { $0.section == .surfaceLayers && $0.url.pathExtension.lowercased() == "h5" }.map(\.id)
        guard !paths.isEmpty else { return [] }
        return try await client.request("model.catalog", parameters: Request(assetPaths: paths), as: [SurfaceCatalogEntry].self)
    }
    func load(_ asset: ProjectAsset, kind: ModelEditorKind) async throws -> EditorSnapshot {
        if kind == .result {
            guard let project, let projectURL = project.url else {
                throw BackendServiceError(code: "sourceChanged", message: "Open a saved project before inspecting results.")
            }
            let snapshot = try await BackendResultInspectorProvider(client: client).inspect(
                resultPath: asset.url, projectPath: projectURL, projectXML: project.editorXML, revision: nil)
            return snapshot.editorSnapshot
        }
        let capturedContext = captureCoreLayerContext()
        let request = ModelRequest(assetPath: asset.url.path, kind: kind.rawValue,
            projectPath: project?.url?.path, projectXml: project?.editorXML,
            coreLayerContext: capturedContext)
        let result = try await client.request("model.load", parameters: request, as: ModelSnapshot.self)
        return try result.editorSnapshot
    }
    func save(_ asset: ProjectAsset, changes: EditorEdits) async throws {
        _ = try await saveModel(asset, changes: changes)
    }
    func saveModel(_ asset: ProjectAsset, changes: EditorEdits) async throws -> EditorSaveResult {
        let request = try saveRequest(asset, changes: changes)
        let result = try await client.request("model.save", parameters: request, as: ModelSnapshot.self)
        return EditorSaveResult(sourceRevision: result.revision, snapshot: try result.editorSnapshot)
    }
    func inspect(_ asset: ProjectAsset, edits: EditorEdits) async throws -> PlanPrecomputeResult {
        guard asset.section == .plans else { throw CocoaError(.featureUnsupported) }
        return try await client.request("model.precompute", parameters: try saveRequest(asset, changes: edits), as: PlanPrecomputeResult.self)
    }
    func precomputePlan(_ asset: ProjectAsset, changes: EditorEdits) async throws -> PlanPrecomputeResult {
        try await inspect(asset, edits: changes)
    }
    func editSeries(_ asset: ProjectAsset, request: SeriesEditRequest) async throws -> SeriesEditResult {
        struct Request: Encodable, Sendable { let model: ModelSaveRequest; let pageId: String; let operation: String }
        let value = Request(model: try saveRequest(asset, changes: request.edits), pageId: request.pageID, operation: request.operation.rawValue)
        let result = try await client.request("model.seriesTransform", parameters: value, as: ModelSnapshot.self)
        guard let series = result.boundary?.series[request.pageID] else { throw BackendServiceError(code: "sourceChanged", message: "The selected source time series no longer exists.") }
        return series.editResult(state: result.sourceState, fields: result.fields, operation: request.operation)
    }
    func editClassification(_ asset: ProjectAsset, action: EditorAction, edits: EditorEdits) async throws -> EditorSnapshot {
        struct Request: Encodable, Sendable { let model: ModelSaveRequest; let operation: String; let itemId: String?; let from: Int?; let to: Int?; var geometry: ClassificationGeometryMutation? = nil }
        let request: Request
        switch action {
        case .editClassificationGeometry(let mutation): request = .init(model: try saveRequest(asset, changes: edits), operation: "geometry", itemId: nil, from: nil, to: nil, geometry: mutation)
        case .reorderSource(_, let from, let to): request = .init(model: try saveRequest(asset, changes: edits), operation: "reorder", itemId: nil, from: from, to: to)
        case .removeSource(_, let id): request = .init(model: try saveRequest(asset, changes: edits), operation: "remove", itemId: id, from: nil, to: nil)
        default: throw CocoaError(.featureUnsupported)
        }
        return try await client.request("model.classificationTransform", parameters: request, as: ModelSnapshot.self).editorSnapshot
    }
    func editTerrain(_ asset: ProjectAsset, action: EditorAction, edits: EditorEdits) async throws -> EditorSnapshot {
        struct LeveeForceSet: Encodable, Sendable { let command: String; let value: String; let rowIDs: [String] }
        struct Request: Encodable, Sendable {
            let model: ModelSaveRequest
            let operation: String
            let itemId: String?
            let from: Int?
            let to: Int?
            var inputKind: String? = nil
            var hintExtent: TerrainInputValidExtent? = nil
            var tableId: String? = nil
            var rowIDs: [String]? = nil
            var leveeForceSet: LeveeForceSet? = nil
        }
        let request: Request
        switch action {
        case .addRow(let table): request = .init(model: try saveRequest(asset, changes: edits), operation: "addRow", itemId: nil, from: nil, to: nil, tableId: table)
        case .copyRows(let table, let ids): request = .init(model: try saveRequest(asset, changes: edits), operation: "copyRows", itemId: nil, from: nil, to: nil, tableId: table, rowIDs: ids.sorted())
        case .removeRows(let table, let ids): request = .init(model: try saveRequest(asset, changes: edits), operation: "removeRows", itemId: nil, from: nil, to: nil, tableId: table, rowIDs: ids.sorted())
        case .selectSource(let field, let id) where field == TerrainEditorContract.sourceField:
            request = .init(model: try saveRequest(asset, changes: edits), operation: "selectInput", itemId: id, from: nil, to: nil)
        case .selectTableRows(let table, let ids): request = .init(model: try saveRequest(asset, changes: edits), operation: "selectRows", itemId: nil, from: nil, to: nil, tableId: table, rowIDs: ids.sorted())
        case .addTerrainInput(let kind, let hintExtent): request = .init(model: try saveRequest(asset, changes: edits), operation: "add", itemId: nil, from: nil, to: nil, inputKind: kind.rawValue, hintExtent: hintExtent)
        case .reorderSource(_, let from, let to): request = .init(model: try saveRequest(asset, changes: edits), operation: "reorder", itemId: nil, from: from, to: to)
        case .removeSource(_, let id): request = .init(model: try saveRequest(asset, changes: edits), operation: "remove", itemId: id, from: nil, to: nil)
        case .forceSetLeveeProperty(let command, let value, let rowIDs, _):
            request = .init(model: try saveRequest(asset, changes: edits), operation: "forceSetLeveeProperty",
                itemId: nil, from: nil, to: nil, tableId: "LeveeModPropertiesEditor/PropertySets",
                rowIDs: rowIDs.sorted(),
                leveeForceSet: .init(command: command.rawValue, value: value, rowIDs: rowIDs.sorted()))
        default: throw CocoaError(.featureUnsupported)
        }
        return try await client.request("model.terrainTransform", parameters: request, as: ModelSnapshot.self).editorSnapshot
    }
    func terrainMap(_ asset: ProjectAsset, edits: EditorEdits, inputID: String?) async throws -> TerrainMapData {
        struct Request: Encodable, Sendable { let model: ModelSaveRequest; let inputId: String? }
        return try await client.request("model.terrainMap", parameters: Request(model: try saveRequest(asset, changes: edits), inputId: inputID), as: TerrainMapData.self)
    }
    func editManning(_ asset: ProjectAsset, operation: String, edits: EditorEdits) async throws -> EditorSnapshot {
        struct Request: Encodable, Sendable { let model: ModelSaveRequest; let operation: String }
        return try await client.request("model.manningTransform", parameters: Request(model: try saveRequest(asset, changes: edits), operation: operation), as: ModelSnapshot.self).editorSnapshot
    }
    func editBoundary(_ asset: ProjectAsset, action: EditorAction, edits: EditorEdits) async throws -> EditorSnapshot {
        if case .editSpatial(let layerID, let operation, let itemID) = action {
            struct SpatialRequest: Encodable, Sendable { let model: ModelSaveRequest; let layerId: String; let operation: String; let itemId: String? }
            let request = SpatialRequest(model: try saveRequest(asset, changes: edits), layerId: layerID, operation: operation, itemId: itemID)
            return try await client.request("model.spatialTransform", parameters: request, as: ModelSnapshot.self).editorSnapshot
        }
        struct Request: Encodable, Sendable {
            let model: ModelSaveRequest; let lineId: String; let operation: String; let payloadId: String?; let fields: [String: String]
        }
        let request: Request
        switch action {
        case .createBoundaryPayload(let lineID, let fields):
            request = .init(model: try saveRequest(asset, changes: edits), lineId: lineID, operation: "create", payloadId: nil, fields: fields)
        case .removeBoundaryPayload(let lineID, let payloadID):
            request = .init(model: try saveRequest(asset, changes: edits), lineId: lineID, operation: "remove", payloadId: payloadID, fields: [:])
        default: throw BackendServiceError(code: "unsupported", message: "This payload operation is unavailable.")
        }
        let result = try await client.request("model.boundaryTransform", parameters: request, as: ModelSnapshot.self)
        return try result.editorSnapshot
    }
    func inspectGrid(_ asset: ProjectAsset, edits: EditorEdits, layerID: String, files: [URL], subdataset: String?, bands: [SpatialGridBand], previewID: String?) async throws -> SpatialGridInspection {
        struct Request: Encodable, Sendable {
            let model: ModelSaveRequest; let layerId: String; let files: [String]; let subdataset: String?; let bands: [SpatialGridBand]; let previewId: String?
        }
        return try await client.request("model.gridInspect", parameters: Request(model: try saveRequest(asset, changes: edits), layerId: layerID,
            files: files.map(\.path), subdataset: subdataset, bands: bands, previewId: previewID), as: SpatialGridInspection.self)
    }
    func classificationMap(_ asset: ProjectAsset, edits: EditorEdits) async throws -> ClassificationMapData {
        struct Request: Encodable, Sendable { let model: ModelSaveRequest }
        return try await client.request("model.classificationMap", parameters: Request(model: try saveRequest(asset, changes: edits)), as: ClassificationMapData.self)
    }
    func inspectClassification(_ asset: ProjectAsset, edits: EditorEdits, files: [URL], selections: [ClassificationImportFile]) async throws -> ClassificationImportInspection {
        struct Request: Encodable, Sendable { let model: ModelSaveRequest; let files: [String]; let selections: [ClassificationImportFile] }
        return try await client.request("model.classificationInspect", parameters: Request(model: try saveRequest(asset, changes: edits), files: files.map(\.path), selections: selections), as: ClassificationImportInspection.self)
    }
    func importClassification(_ asset: ProjectAsset, edits: EditorEdits, files: [ClassificationImportFile]) async throws -> EditorSaveResult {
        struct Request: Encodable, Sendable { let model: ModelSaveRequest; let files: [ClassificationImportFile] }
        let result = try await client.request("model.classificationImport", parameters: Request(model: try saveRequest(asset, changes: edits), files: files), as: ModelSnapshot.self)
        return .init(sourceRevision: result.revision, snapshot: try result.editorSnapshot)
    }
    func inspectTerrainInputImport(_ asset: ProjectAsset, edits: EditorEdits, files: [URL]) async throws -> TerrainInputImportInspection {
        struct Request: Encodable, Sendable {
            let model: ModelSaveRequest
            let filePaths: [String]
        }
        return try await client.request("model.terrainInputImportInspect",
            parameters: Request(model: try saveRequest(asset, changes: edits), filePaths: files.map(\.path)), as: TerrainInputImportInspection.self)
    }
    func makeTerrainInputAppendRequest(_ asset: ProjectAsset, edits: EditorEdits, selections: [TerrainInputImportSelection], stitchTiles: Bool, draftToken: String, batchToken: String) throws -> TerrainInputAppendRequest {
        TerrainInputAppendRequest(model: try saveRequest(asset, changes: edits), files: selections,
            stitchTiles: stitchTiles, draftToken: draftToken, batchToken: batchToken)
    }
    func appendTerrainInputImport(_ asset: ProjectAsset, request: TerrainInputAppendRequest) async throws -> TerrainInputAppendResult {
        try await client.request("model.terrainInputAppend", parameters: request, as: TerrainInputAppendResult.self)
    }
    func terrainInputImportStatus(_ asset: ProjectAsset, request: TerrainInputAppendRequest) async throws -> TerrainInputImportStatus {
        try await client.request("model.terrainInputImportStatus",
            parameters: TerrainInputImportStatusRequest(request: request), as: TerrainInputImportStatus.self)
    }
    func cancelTerrainInputImport(_ asset: ProjectAsset, request: TerrainInputAppendRequest, operationID: String?) async throws -> TerrainInputImportCancelReceipt {
        struct Request: Encodable, Sendable {
            let model: ModelRequest
            let draftToken: String
            let batchToken: String
            let operationID: String?
        }
        guard asset.section == .terrains else {
            throw BackendServiceError(code: "unsupported", message: "Terrain import cancellation is unavailable for this model.")
        }
        guard request.model.assetPath == asset.url.path, request.model.kind == ModelEditorKind.terrain.rawValue else {
            throw BackendServiceError(code: "sourceChanged", message: "Terrain import cancellation no longer matches the active model.")
        }
        let model = ModelRequest(assetPath: request.model.assetPath, kind: request.model.kind,
            projectPath: request.model.projectPath, projectXml: request.model.projectXml,
            coreLayerContext: request.model.coreLayerContext)
        return try await client.request("model.terrainInputImportCancel",
            parameters: Request(model: model, draftToken: request.draftToken, batchToken: request.batchToken, operationID: operationID),
            as: TerrainInputImportCancelReceipt.self)
    }
    func discardTerrainInputImport(_ asset: ProjectAsset, draftToken: String) async throws -> Bool {
        struct ModelRequest: Encodable, Sendable {
            let assetPath: String
            let kind: String
            let projectPath: String?
            let projectXml: String?
            let coreLayerContext: CoreLayerRequestContext?
        }
        struct Request: Encodable, Sendable { let model: ModelRequest; let draftToken: String }
        guard let kind = ModelEditorKind.allCases.first(where: { $0.section == asset.section }) else {
            throw BackendServiceError(code: "unsupported", message: "Terrain input cleanup is unavailable for this model.")
        }
        let model = ModelRequest(assetPath: asset.url.path, kind: kind.rawValue,
            projectPath: project?.url?.path, projectXml: project?.editorXML,
            coreLayerContext: captureCoreLayerContext())
        return try await client.request("model.terrainInputImportDiscard",
            parameters: Request(model: model, draftToken: draftToken), as: Bool.self)
    }
    func discardTerrainInputImportBatch(_ asset: ProjectAsset, draftToken: String, batchToken: String) async throws -> Bool {
        struct ModelRequest: Encodable, Sendable {
            let assetPath: String
            let kind: String
            let projectPath: String?
            let projectXml: String?
            let coreLayerContext: CoreLayerRequestContext?
        }
        struct Request: Encodable, Sendable { let model: ModelRequest; let draftToken: String; let batchToken: String }
        guard asset.section == .terrains else {
            throw BackendServiceError(code: "unsupported", message: "Terrain import batch cleanup is unavailable for this model.")
        }
        let model = ModelRequest(assetPath: asset.url.path, kind: ModelEditorKind.terrain.rawValue,
            projectPath: project?.url?.path, projectXml: project?.editorXML,
            coreLayerContext: captureCoreLayerContext())
        return try await client.request("model.terrainInputImportDiscardBatch",
            parameters: Request(model: model, draftToken: draftToken, batchToken: batchToken), as: Bool.self)
    }
    func importGrid(_ asset: ProjectAsset, edits: EditorEdits, selection: SpatialGridSelection) async throws -> EditorSaveResult {
        struct Request: Encodable, Sendable { let model: ModelSaveRequest; let selection: SpatialGridSelection }
        let result = try await client.request("model.gridImport", parameters: Request(model: try saveRequest(asset, changes: edits), selection: selection), as: ModelSnapshot.self)
        return .init(sourceRevision: result.revision, snapshot: try result.editorSnapshot)
    }
    func importGrid(_ asset: ProjectAsset, edits: EditorEdits, selection: SpatialGridSelection,
                    progress: @escaping @MainActor @Sendable (BackendProgressUpdate) -> Void,
                    installCancellation: @escaping GridImportCancellationInstaller) async throws -> EditorSaveResult {
        guard selection.dssSource != nil else {
            return try await importGrid(asset, edits: edits, selection: selection)
        }
        struct Request: Encodable, Sendable { let model: ModelSaveRequest; let selection: SpatialGridSelection }
        try Task.checkCancellation()
        let request = Request(model: try saveRequest(asset, changes: edits), selection: selection)
        let operation = try client.startDuplex("model.gridImport", parameters: request,
            control: DssGridImportControl.self, event: BackendProgressUpdate.self,
            as: DssGridImportDuplexResult.self)
        let cancelSender = SpatialGridImportCancelSender(operation: operation)
        installCancellation { cancelSender.cancel() }
        defer { installCancellation(nil) }

        // Keep draining the source after a view task is cancelled. The control
        // asks the backend to stop cooperatively; the terminal response still
        // determines whether publication won the cancel/commit race.
        let importTask = Task.detached(priority: .userInitiated) {
            do {
                for try await update in operation.events { await progress(update) }
            } catch {
                // Preserve the terminal result, including a snapshot committed
                // before a cancellation or progress-stream shutdown.
            }
            return try await operation.value()
        }
        let response = try await withTaskCancellationHandler {
            try await importTask.value
        } onCancel: {
            _ = cancelSender.cancel()
        }
        switch response.state {
        case "completed":
            guard let snapshot = response.snapshot else {
                throw BackendServiceError(code: "protocolFailure", message: "The DSS grid import completed without a saved model snapshot.")
            }
            return .init(sourceRevision: snapshot.revision, snapshot: try snapshot.editorSnapshot,
                refreshWarning: response.refreshWarning)
        case "cancelled": throw CancellationError()
        default:
            throw BackendServiceError(code: "processFailure",
                message: response.errorMessage ?? "The DSS grid import did not complete.")
        }
    }
    func perform(_ asset: ProjectAsset, action: EditorAction, edits: EditorEdits) async throws -> EditorSnapshot {
        if case .selectTableRows = action, asset.section == .terrains {
            return try await editTerrain(asset, action: action, edits: edits)
        }
        guard case .selectSpatialTime(let layer, let step) = action else { return try await perform(asset, action: action) }
        struct Request: Encodable, Sendable { let model: ModelSaveRequest; let layerId: String; let timeId: String?; let component: String }
        let parts = step?.split(separator: "|", maxSplits: 1).map(String.init)
        if let parts, parts.count != 2 { throw BackendServiceError(code: "invalidInput", message: "Invalid raster timestep.") }
        let frame = try await client.request("model.gridFrame", parameters: Request(model: try saveRequest(asset, changes: edits), layerId: layer,
            timeId: parts?.last, component: parts?.first ?? "Value"), as: SpatialGridData.self)
        var snapshot = EditorSnapshot(fields: [:], rows: [:], samples: [:], canEdit: true, images: [:], sourceRevision: edits.sourceRevision)
        snapshot.spatialPresentations[layer] = try frame.presentation()
        return snapshot
    }
    func saveRequest(_ asset: ProjectAsset, changes: EditorEdits) throws -> ModelSaveRequest {
        guard let revision = changes.sourceRevision else {
            throw BackendServiceError(code: "sourceChanged", message: "Reload the model before saving.")
        }
        guard let kind = ModelEditorKind.allCases.first(where: { $0.section == asset.section }),
              (kind == .boundaryCondition || kind == .surface) || kind == .terrain && changes.samples.values.allSatisfy(\.isEmpty)
                || changes.rows.values.allSatisfy(\.isEmpty) && changes.samples.values.allSatisfy(\.isEmpty) else {
            throw BackendServiceError(code: "unsupported", message: "This model edit is not yet connected to the source backend.")
        }
        return ModelSaveRequest(assetPath: asset.url.path, kind: kind.rawValue, projectPath: project?.url?.path,
            revision: revision, fields: changes.fields, images: changes.images.mapValues { $0.map(ImageData.init) }, projectXml: project?.editorXML,
            sourceState: changes.sourceState, rows: changes.rows.mapValues { $0.map(BackendModelRow.init) }, samples: changes.samples.mapValues { $0.map(BackendModelSample.init) },
            planTimeWindowEdits: changes.planTimeWindowEdits, geometryTopologyState: changes.geometryTopologyState,
            geometryMeshState: changes.geometryMeshState, geometryCulvertState: changes.geometryCulvertState,
            tableSelections: changes.tableSelections, changedCells: changes.changedCells,
            coreLayerContext: captureCoreLayerContext())
    }
    func perform(_ asset: ProjectAsset, action: EditorAction) async throws -> EditorSnapshot {
        throw BackendServiceError(code: "unsupported", message: "This model action is not yet connected to the source backend.")
    }
    private struct ModelRequest: Encodable, Sendable {
        let assetPath: String; let kind: String; let projectPath: String?
        let projectXml: String?
        let coreLayerContext: CoreLayerRequestContext?
    }
    struct ModelSaveRequest: Encodable, Sendable {
        let assetPath: String; let kind: String; let projectPath: String?
        let revision: String; let fields: [String: String]; let images: [String: [ImageData]]
        let projectXml: String?
        let sourceState: String?
        let rows: [String: [BackendModelRow]]
        let samples: [String: [BackendModelSample]]
        let planTimeWindowEdits: [PlanTimeWindowEdit]
        let geometryTopologyState: String?
        let geometryMeshState: String?
        let geometryCulvertState: String?
        var tableSelections: [String: [String]] = [:]
        var changedCells: [String: [EditorChangedCell]] = [:]
        var coreLayerContext: CoreLayerRequestContext? = nil
    }
    struct ImageData: Codable, Sendable {
        let id: String; let name: String; let data: Data
        init(_ image: ImageAttachment) { id = image.id; name = image.name; data = image.data }
        var attachment: ImageAttachment { .init(id: id, name: name, data: data) }
    }
    struct ModelSnapshot: Decodable, Sendable {
        let revision: String; let fields: [String: String]; let images: [String: [ImageData]]; let canEdit: Bool
        let fieldGroups: [String: [String]]
        let availableOperations: Set<EditorOperation>
        let boundary: BackendBoundaryData?
        let sourceState: String?
        let readOnlyFields: Set<String>?
        let planTimeWindowFieldIDs: PlanTimeWindowFieldIDs?
        let grids: [String: SpatialGridData]?
        let manning: ManningData?
        let classification: BackendClassificationData?
        let terrain: BackendTerrainData?
        let fieldChoices: [String: [EditorChoice]]?
        let fieldTitles: [String: String]?
        struct ManningData: Decodable, Sendable {
            let classifications: [BackendBoundaryData.Choice]; let rows: [BackendModelRow]; let warning: String?
            func apply(to snapshot: inout EditorSnapshot) {
                snapshot.choiceOptions["ClassificationLayerManningNEditor/NValueLayer_ClassificationLayer"] = classifications.map(\.presentation)
                snapshot.rows[ManningEditorPage.tableID] = rows.map(\.editorRow)
                snapshot.tablePresentations[ManningEditorPage.tableID] = .init(columns: [
                    .init(id: "Key", title: "Classification", sourceType: "string", readOnly: true, width: 240),
                    .init(id: "Value", title: "Manning’s n", sourceType: "float", width: 140)])
                if let warning { snapshot.textSuggestions["ManningWarning"] = [warning] }
            }
        }
        var editorSnapshot: EditorSnapshot {
          get throws {
            var snapshot = EditorSnapshot(fields: fields, rows: [:], samples: [:], canEdit: canEdit, images: images.mapValues { $0.map(\.attachment) }, sourceRevision: revision, fieldGroups: fieldGroups, availableOperations: availableOperations,
                sourceState: sourceState, readOnlyFieldIDs: readOnlyFields ?? [], planTimeWindowFieldIDs: planTimeWindowFieldIDs)
            snapshot.choiceOptions = fieldChoices ?? [:]
            snapshot.fieldTitles = fieldTitles ?? [:]
            boundary?.apply(to: &snapshot)
            manning?.apply(to: &snapshot)
            classification?.apply(to: &snapshot)
            terrain?.apply(to: &snapshot)
            for (id, data) in grids ?? [:] {
                snapshot.spatialPresentations[id] = try data.presentation(basedOn: snapshot.spatialPresentations[id])
            }
            return snapshot
          }
        }
    }
}
