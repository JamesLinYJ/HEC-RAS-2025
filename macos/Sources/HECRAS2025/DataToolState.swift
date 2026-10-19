import Combine
import CryptoKit
import Foundation
import RASWorkspaceCore

extension ToolKind {
    var hasDedicatedDataDialog: Bool {
        [.terrainImport, .classificationImport, .vectorImport, .griddedImport, .spatialImport, .coreImport,
         .initialConditions, .planExport, .rasterExport, .depthExport, .reprojection,
         .backgroundMaps, .tagCreate, .tagEdit, .tagFilter, .addAttribute, .renameAttribute].contains(self)
            || [.newGeometry, .newPlan, .newBoundary, .newShapefile, .poiImport, .unitCalculator, .wilcock, .rasterCalculator].contains(self)
            || [.credentials, .reportIssue, .topology, .contours, .hillshade, .vectorLabels, .crossSection, .arcPoints].contains(self)
    }
}

// These are presentation boundaries for the renamed source importers/exporters.
// File interpretation, previews, reprojection and exports stay in their model
// adapters. An absent adapter never supplies invented metadata or results.
struct DataToolContext: Sendable {
    let projectSessionID: UUID
    let mapID: UUID
    let assetID: String?
    let extent: ViewportRequest?
    var attributeTable: AttributeToolContext? = nil
    var featureID: Int? = nil
    var spatialLayerID: String? = nil
}
enum DataToolOperation: String, Sendable {
    case execute, inspect, preview, query, connectCumulus, selectLatest, selectEarliest, reproject
    case copyFile, addReference
    case createTag, assignTag, assignRecentTag, removeTag, clearCache
    case calculate, importPoints, addCase, removeCase, importCase
    case login, clearCredentials, refineTopology, coarsenTopology, applyTopologyFactor
    case addInput, removeInput, addConstant, removeConstant, addToMap, saveExisting
}
struct ToolCoordinateRow: Identifiable, Equatable, Sendable {
    let id: String
    var x: String
    var y: String
}
struct DataToolLayer: Identifiable, Sendable {
    let id: String
    let name: String
    let detail: String
    let scope: String?
    var classificationKind: ClassificationImportKind? = nil
}
struct DataToolTimeStep: Identifiable, Sendable {
    let id: String
    let title: String
    let date: Date
}
struct DataToolProgress: Sendable {
    let message: String
    let fraction: Double?
}
struct DataToolPreview: Sendable {
    var rasters: [MapRasterLayer] = []
    var vectors: [QueryPreviewLayer] = []
    var extent: ViewportRequest? = nil
    var revision = UUID()
    var isEmpty: Bool { rasters.isEmpty && vectors.isEmpty }
}
struct DataToolPresentation: Sendable {
    var editor = EditorSnapshot(fields: [:], rows: [:], samples: [:], canEdit: true, images: [:])
    var layers: [DataToolLayer] = []
    var selectedLayerIDs: Set<String>? = nil
    var timeSteps: [DataToolTimeStep] = []
    var preview = DataToolPreview()
    var destinationRows: [ToolCoordinateRow] = []
    var message = ""
    var canExecute = false
    var canCancel = false
    var uploadAvailable = false
    var metadata: MetadataToolPresentation? = nil
    var creation: CreationPresentation? = nil
    var unitCalculator: UnitCalculatorPresentation? = nil
    var wilcock: WilcockPresentation? = nil
    var pointImport: PointImportPresentation? = nil
    var support: SupportPresentation? = nil
    var mapStyle: MapStylePresentation? = nil
    var profile: ProfilePresentation? = nil
    var planExport: PlanExportPresentation? = nil
}
enum DataToolError: LocalizedError {
    case unavailable
    var errorDescription: String? { "The original model adapter for this tool is unavailable." }
}

@MainActor
final class DataToolSession: ObservableObject {
    @Published var inputFiles: [URL] = []
    @Published var destination: URL?
    @Published var destinationMayReplace = false
    @Published var selectedLayerIDs: Set<String> = []
    @Published var selectedSettingsLayerID: String?
    @Published var coordinates: [ToolCoordinateRow] = []
    @Published var triggeringField: String?
    @Published var interestPoints: [InterestPoint] = []
    @Published var selectedCalculatorCaseID: String?
    @Published private(set) var pointsModified = false
    @Published var reportComponentIDs: Set<String> = []
    @Published var reportFromCrash = false
    @Published private(set) var presentation = DataToolPresentation()
    @Published private(set) var preparing = false
    @Published private(set) var running = false
    @Published private(set) var executingOperation: DataToolOperation?
    @Published private(set) var progress: DataToolProgress?
    @Published var error: String?
    private var preparation: Task<Void, Never>?
    private var execution: Task<Void, Never>?
    private var revision = 0
    private var preparedSignature: String?
    var busy: Bool { preparing || running }

    // Metadata-only display fields are intentionally excluded from edits sent
    // to the source. The same original field keys are retained for real inputs.
    static let displayFields: Set<String> = [
        "GriddedDataImporter/RawUnits", "RgbTiffExporterControl/DimensionsText",
        "RgbTiffExporterControl/EstimatedSizeText", "CoreLayerImportDialog/CoreLayer_Filename",
        "CoreLayerImportDialog/CoreLayer_Name", "CoreLayerImportDialog/PrettyFileSize",
        "CoreLayerImportDialog/CoreLayer_Description", "GriddedDataImporter/Timeline_StartTime",
        "GriddedDataImporter/Timeline_EndTime", "GriddedDataImporter/TotalTimesteps",
        "SpatialBoundaryConditionRasterImporter/TimeShift", "PoiImporter/BackdropProgress", "PoiImporter/BackdropStatus"
    ]
    func request(kind: ToolKind, editor: ModelEditorSession, context: DataToolContext,
                 operation: DataToolOperation = .inspect) -> ToolRequest {
        var fields = editor.fields.filter { entry in
            let sourceID = entry.key.split(separator: "/").suffix(2).joined(separator: "/")
            return !Self.displayFields.contains(sourceID) && !sourceID.hasPrefix("ProjectionSummary/")
                && SourceEditorLibrary.shared.field(storageID: entry.key)?.readOnly != true
        }
        if kind == .planExport && (!presentation.uploadAvailable || fields["PlanExporterControl/ExportTypeIndex"] == "1") {
            fields["PlanExporterControl/EnableUpload"] = "false"
        }
        if kind == .wilcock {
            let computed = fields["WilcockBTMControl/MergedBTM_IsISBTMMode"] == "true" ? "MergedBTM_ShearVelocity" : "MergedBTM_TotalTransportRate"
            fields["WilcockBTMControl/" + computed] = nil
        }
        if kind == .unitCalculator, fields["UnitCalculator/FromSelectedUnit"] == nil,
           let unit = presentation.unitCalculator?.fromUnitID, !unit.isEmpty {
            fields["UnitCalculator/FromSelectedUnit"] = unit
        }
        if kind == .reportIssue {
            fields["JiraBugReportForm/Report_Components"] = reportComponentIDs.intersection(Set(presentation.support?.components.map(\.id) ?? [])).sorted().joined(separator: "\n")
            let system = ReportSystemInfo()
            fields["JiraBugReportForm/Report_Os"] = system.os; fields["JiraBugReportForm/Report_Cores"] = system.cores
            fields["JiraBugReportForm/Report_Timezone"] = system.timezone
        }
        let outputKey = kind == .planExport ? "PlanExporterControl/OutputPath"
            : kind == .rasterExport ? "RgbTiffExporterControl/OutputPath" : "DepthShapeExporter/ShapefileVm_ShapefileName"
        let sourceDestination = fields[outputKey].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        var rows = editor.rows
        if kind == .wilcock {
            for table in Array(rows.keys) {
                let inputColumns = Set((editor.tablePresentations[table]?.columns ?? []).filter { $0.readOnly != true }.map(\.id))
                if inputColumns.isEmpty { rows[table] = nil }
                else { rows[table] = rows[table]?.map { .init(id: $0.id, values: $0.values.filter { inputColumns.contains($0.key) }) } }
            }
        }
        return ToolRequest(kind: kind.id, fields: fields, inputFiles: inputFiles,
            destination: destination ?? (kind == .newShapefile ? presentation.creation?.directory : sourceDestination),
            images: editor.images, context: context, operation: operation, selectedLayerIDs: selectedLayerIDs, coordinateRows: coordinates, rows: rows,
            sourceItemID: kind == .wilcock ? selectedCalculatorCaseID : nil, triggeringField: triggeringField, interestPoints: interestPoints,
            replaceDestination: destinationMayReplace,
            inputIssue: editor.incompleteEditorInputIssue, reportFromCrash: reportFromCrash)
    }
    // Include values with a length prefix so filenames/newlines cannot collide.
    func signature(_ request: ToolRequest) -> String {
        var components = ["kind", request.kind, "destination", request.destination?.absoluteString ?? "", "replace-destination", String(request.replaceDestination), "input-issue", request.inputIssue ?? "", "report-from-crash", String(request.reportFromCrash)]
        if let context = request.context {
            components += ["context", context.projectSessionID.uuidString, context.mapID.uuidString, context.assetID ?? "",
                context.attributeTable?.modelAssetID ?? "", context.attributeTable?.tableID ?? "", context.attributeTable?.columnID ?? "", context.featureID.map(String.init) ?? "", context.spatialLayerID ?? ""]
            if let extent = context.extent { components += ["extent", String(extent.lowerLeft.x), String(extent.lowerLeft.y), String(extent.upperRight.x), String(extent.upperRight.y)] }
        }
        components += ["trigger", request.triggeringField ?? "", "source-item", request.sourceItemID ?? ""]
        for file in request.inputFiles { components += ["file", file.absoluteString] }
        for entry in request.fields.sorted(by: { $0.key < $1.key }) { components += ["field", entry.key, entry.value] }
        for layer in request.selectedLayerIDs.sorted() { components += ["layer", layer] }
        for row in request.coordinateRows { components += ["coordinate", row.id, row.x, row.y] }
        for point in request.interestPoints { components += ["poi", point.id.uuidString, point.name, String(point.x), String(point.y), point.serverID.map(String.init) ?? ""] }
        for field in request.images.keys.sorted() {
            for attachment in request.images[field] ?? [] { components += ["image", field, attachment.id, attachment.name, String(attachment.data.count)] }
        }
        for entry in request.rows.sorted(by: { $0.key < $1.key }) {
            for row in entry.value {
                components += ["table", entry.key, "row", row.id]
                for cell in row.values.sorted(by: { $0.key < $1.key }) { components += ["cell", cell.key, cell.value] }
            }
        }
        let text = components.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func isCurrent(_ request: ToolRequest) -> Bool { preparedSignature == signature(request) }
    func canExecute(_ request: ToolRequest) -> Bool { !busy && request.inputIssue == nil && presentation.canExecute && isCurrent(request) }

    @discardableResult
    func prepare(_ request: ToolRequest, editor: ModelEditorSession,
                 provider: (any ToolProvider)?, currentRequest: @escaping @MainActor () -> ToolRequest) -> Task<Void, Never>? {
        guard !running else { return nil }
        revision += 1; let captured = revision
        preparation?.cancel(); preparing = false; error = nil; preparedSignature = nil
        if let issue = request.inputIssue { error = L10n.text(issue); return nil }
        guard let provider else { return nil }
        preparing = true
        let requestedSignature = signature(request)
        preparation = Task {
            defer { if captured == revision { preparing = false; preparation = nil } }
            do {
                let value = try await provider.prepare(request)
                guard captured == revision, !Task.isCancelled,
                      requestedSignature == signature(currentRequest()) else { return }
                presentation = value
                if request.kind == ToolKind.planExport.id, let source = value.planExport { destination = source.destination }
                editor.mergeToolPresentation(value.editor, overwriteRows: request.operation == .selectLatest || request.operation == .selectEarliest,
                    sourceWins: calculationOutputs(request))
                if !pointsModified, let points = value.pointImport?.points { interestPoints = points }
                if let calculator = value.wilcock, !calculator.cases.contains(where: { $0.id == selectedCalculatorCaseID }) { selectedCalculatorCaseID = calculator.selectedCaseID }
                if let selection = value.selectedLayerIDs { selectedLayerIDs = selection.intersection(Set(value.layers.map(\.id))) }
                if !value.layers.contains(where: { $0.id == selectedSettingsLayerID }) { selectedSettingsLayerID = value.layers.first?.id }
                preparedSignature = signature(currentRequest())
            } catch {
                if captured == revision, !Task.isCancelled { self.error = L10n.text(error.localizedDescription) }
            }
        }
        return preparation
    }
    @discardableResult
    func execute(_ request: ToolRequest, provider: (any ToolProvider)?,
                 completion: @escaping @MainActor () -> Void) -> Task<Void, Never>? {
        guard canExecute(request), let provider else { return nil }
        if request.kind == ToolKind.reportIssue.id, presentation.support?.showsModelForm == true,
           presentation.support?.modelUploadImplemented != true { return nil }
        revision += 1; let captured = revision
        running = true; executingOperation = request.operation; error = nil; progress = nil
        execution = Task {
            defer { if captured == revision { running = false; executingOperation = nil; progress = nil; execution = nil } }
            do {
                try await provider.execute(request) { value in
                    guard captured == self.revision, !Task.isCancelled else { return }
                    self.progress = .init(message: value.message, fraction: value.fraction.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil })
                }
                guard captured == revision, !Task.isCancelled else { return }
                completion()
            } catch {
                if captured == revision, !Task.isCancelled { self.error = L10n.text(error.localizedDescription) }
            }
        }
        return execution
    }
    func cancelExecution() {
        guard running, presentation.canCancel else { return }
        // Keep the sheet busy until the adapter acknowledges cancellation.
        execution?.cancel()
    }
    func stopPreparation() { revision += 1; preparation?.cancel(); preparation = nil; preparing = false; preparedSignature = nil }

    // Source actions return the updated presentation. Assigning a tag and
    // clearing a map cache keep their original panel open on success.
    @discardableResult
    func perform(_ request: ToolRequest, editor: ModelEditorSession,
                 provider: (any ToolProvider)?, currentRequest: @escaping @MainActor () -> ToolRequest,
                 sourceWins: Set<String> = [], completion: @escaping @MainActor (DataToolPresentation) -> Void = { _ in }) -> Task<Void, Never>? {
        guard !busy, request.inputIssue == nil, currentRequest().inputIssue == nil,
              isCurrent(currentRequest()), let provider else { return nil }
        switch request.operation {
        case .assignRecentTag:
            guard presentation.metadata?.recentTags.contains(where: { $0.id == request.sourceItemID }) == true else { return nil }
        case .removeTag:
            guard request.kind == ToolKind.tagEdit.id,
                  presentation.metadata?.canRemoveAssignedTags == true,
                  let definitionID = request.sourceItemID,
                  presentation.metadata?.assignedTags.contains(where: { $0.definitionID == definitionID }) == true else { return nil }
        case .clearCache:
            // Map cache actions use the map-owned BackgroundMapSession.
            return nil
        case .importPoints:
            guard presentation.pointImport?.canEdit == true, request.inputFiles.count == 1 else { return nil }
        case .addCase, .importCase:
            guard presentation.wilcock?.canAddCases == true else { return nil }
        case .removeCase:
            guard let id = request.sourceItemID, presentation.wilcock?.removableCaseIDs.contains(id) == true else { return nil }
        case .login:
            guard presentation.support?.canLogin == true else { return nil }
        case .clearCredentials:
            guard presentation.support?.canClearCredentials == true else { return nil }
        case .refineTopology, .coarsenTopology:
            guard presentation.mapStyle?.canModifyTopology == true else { return nil }
        case .applyTopologyFactor:
            guard presentation.mapStyle?.canModifyTopology == true, presentation.canExecute else { return nil }
        case .addInput, .addConstant:
            let table = request.operation == .addInput ? "RasterCalculatorEditor/Inputs" : "RasterCalculatorEditor/Constants"
            guard request.kind == ToolKind.rasterCalculator.id, editor.tablePresentations[table]?.canAddRows == true else { return nil }
        case .removeInput, .removeConstant:
            let table = request.operation == .removeInput ? "RasterCalculatorEditor/Inputs" : "RasterCalculatorEditor/Constants"
            guard request.kind == ToolKind.rasterCalculator.id, editor.tablePresentations[table]?.canDeleteRows == true,
                  let id = request.sourceItemID, editor.rows[table]?.contains(where: { $0.id == id }) == true else { return nil }
        case .addToMap:
            guard request.kind == ToolKind.rasterCalculator.id, presentation.canExecute,
                  editor.fields["RasterCalculatorEditor/IsEditingExisting"] != "true" else { return nil }
        case .saveExisting:
            guard request.kind == ToolKind.rasterCalculator.id, presentation.canExecute,
                  editor.fields["RasterCalculatorEditor/IsEditingExisting"] == "true" else { return nil }
        case .createTag, .assignTag, .execute:
            guard presentation.canExecute else { return nil }
        default: return nil
        }
        revision += 1; let captured = revision, origin = signature(currentRequest())
        running = true; executingOperation = request.operation; error = nil
        execution = Task {
            defer { if captured == revision { running = false; executingOperation = nil; execution = nil } }
            do {
                let value = try await provider.perform(request)
                guard captured == revision, !Task.isCancelled, origin == signature(currentRequest()) else { return }
                acceptSourceUpdate(value, editor: editor, sourceWins: sourceWins, currentRequest: currentRequest)
                completion(value)
            } catch { if captured == revision, !Task.isCancelled { self.error = L10n.text(error.localizedDescription) } }
        }
        return execution
    }
    func acceptSourceUpdate(_ value: DataToolPresentation, editor: ModelEditorSession,
                            sourceWins: Set<String>, currentRequest: @MainActor () -> ToolRequest) {
        presentation = value
        editor.mergeToolPresentation(value.editor, sourceWins: sourceWins)
        if let points = value.pointImport?.points { interestPoints = points; pointsModified = false }
        if let calculator = value.wilcock { selectedCalculatorCaseID = calculator.selectedCaseID }
        preparedSignature = signature(currentRequest())
    }
    private func calculationOutputs(_ request: ToolRequest) -> Set<String> {
        if request.kind == ToolKind.unitCalculator.id {
            guard let trigger = request.triggeringField else { return [] }
            if trigger == "UnitCalculator/FromSelectedUnit" {
                return ["UnitCalculator/ToOutput", "UnitCalculator/ToSelectedUnit"]
            }
            return [trigger == "UnitCalculator/FromInput" || trigger == "UnitCalculator/FromSelectedUnit"
                ? "UnitCalculator/ToOutput" : "UnitCalculator/FromInput"]
        }
        if request.kind == ToolKind.wilcock.id {
            return [request.fields["WilcockBTMControl/MergedBTM_IsISBTMMode"] == "true"
                ? "WilcockBTMControl/MergedBTM_ShearVelocity" : "WilcockBTMControl/MergedBTM_TotalTransportRate"]
        }
        return []
    }
    func editPoint(_ id: UUID, name: String? = nil, location: MapPoint? = nil) {
        guard presentation.pointImport?.canEdit == true, !busy, location?.x.isFinite != false, location?.y.isFinite != false,
              let index = interestPoints.firstIndex(where: { $0.id == id }) else { return }
        if let name { interestPoints[index].name = name }
        if let location { interestPoints[index].x = location.x; interestPoints[index].y = location.y }
        pointsModified = true
    }
    func addPoint(_ location: MapPoint) {
        guard presentation.pointImport?.canEdit == true, !busy, location.x.isFinite, location.y.isFinite else { return }
        interestPoints.append(.init(id: UUID(), serverID: nil, name: "", x: location.x, y: location.y)); pointsModified = true
    }
    func removePoints(_ ids: Set<UUID>) {
        guard presentation.pointImport?.canEdit == true, !busy else { return }
        interestPoints.removeAll { ids.contains($0.id) }; pointsModified = true
    }
}
