import Combine
import CryptoKit
import Foundation
import RASWorkspaceCore
import SwiftUI

struct EditorChoice: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    var debugOnly: Bool? = nil
    var titleIsUserData: Bool? = nil
    var sourceIcon: String? = nil
    var description: String? = nil
}
struct SourceEditorField: Codable, Identifiable, Sendable {
    let id: String
    var scope: String
    var storageID: String { scoped(id) }
    func scoped(_ route: String) -> String { scope + "/" + route }
    func inScope(_ prefix: String?) -> Self {
        guard let prefix, !prefix.isEmpty else { return self }
        var result = self; result.scope = prefix + "/" + scope; return result
    }
    var title: String
    func titled(_ title: String) -> Self { var result = self; result.title = title; result.titleIsPrelocalized = nil; return result }
    var titleIsPrelocalized: Bool? = nil
    func titled(verbatim title: String) -> Self { var result = self; result.title = title; result.titleIsPrelocalized = true; return result }
    let kind: String
    let sourceType: String
    let sourceControl: String
    let sourceSetter: String
    let choices: [EditorChoice]
    let sourceLine: Int
    let readOnly: Bool
    let enabledBy: [String]
    var mixedBy: String?
    let visibleBy: [String]
    let help: String
    let placeholder: String
    let minimum: Double?
    let maximum: Double?
    let allowZero: Bool
    let resourceMatched: Bool
    let connectionBy: String?
    let radioBinding: SourceRadioBinding?
    // Some source controls expose instance commands or validation owners
    // which are not represented by the extracted editor schema. The optional
    // values let source-backed hosts carry those semantics without changing
    // the persisted XML/HDF field identity.
    var forceSetCommand: String? = nil
    var clearCommand: String? = nil
    var showClearButton: Bool? = nil
    var errorValidationSource: String? = nil
    var errorValidationPropertyName: String? = nil
    var isReadOnly: Bool? = nil
}
struct SourceRadioBinding: Codable, Sendable { let route: String; let value: String }
struct SourceEditorSchema: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let source: String
    let fields: [SourceEditorField]
    let children: [String]
    let groups: [SourceEditorGroup]
    let preferredColumnWidth: Double?
}
struct SourceEditorGroup: Codable, Sendable { let title: String; let fields: [String] }
struct SourceTableColumn: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let sourceType: String
    let readOnly: Bool?
    let choices: [EditorChoice]?
    let visible: Bool?
    let sortable: Bool?
    let filterable: Bool?
    let width: Double?
    let autoSuggestions: [String]?
    let titleIsUserData: Bool?
    @MainActor var localizedTitle: String {
        if titleIsUserData == true { return title }
        if id.hasPrefix("station/"), let index = Int(id.dropFirst(8)), title == "Station \(index)" { return L10n.format("Station %d", index) }
        return L10n.text(title)
    }
    init(id: String, title: String, sourceType: String, readOnly: Bool? = nil, choices: [EditorChoice]? = nil, visible: Bool? = nil, sortable: Bool? = nil, filterable: Bool? = nil, width: Double? = nil, autoSuggestions: [String]? = nil, titleIsUserData: Bool? = nil) {
        self.id = id; self.title = title; self.sourceType = sourceType; self.readOnly = readOnly
        self.choices = choices; self.visible = visible; self.sortable = sortable; self.filterable = filterable
        self.width = width; self.autoSuggestions = autoSuggestions; self.titleIsUserData = titleIsUserData
    }
}
// IColumnDefinition order/headers and DataGrid row capabilities come from the
// actual source table. An empty columns list is authoritative, not a fallback.
struct EditorTablePresentation: Sendable {
    let columns: [SourceTableColumn]
    var canAddRows = false
    var canCopyRows = false
    var canDeleteRows = false
    var canAddColumns = false
    var renameableColumnIDs: Set<String> = []
    // The source selects actual features/property sets and supplies the editor
    // for that selection, including an aggregate scope for mixed values.
    var selection: TableSelectionPresentation? = nil
    var requestedSelectionRowIDs: Set<String>? = nil
}
struct TableSelectionPresentation: Sendable {
    let rowIDs: Set<String>
    var detail: SourceItemPresentation? = nil
}
struct SourceTableSchema: Codable, Identifiable, Sendable {
    let id: String
    let source: String
    let columns: [SourceTableColumn]
}

struct SourceEditorLibrary: Decodable, Sendable {
    let schemas: [SourceEditorSchema]
    let tables: [SourceTableSchema]
    let mapTools: [MapToolDescriptor]
    static let shared: SourceEditorLibrary = {
        guard let file = Bundle.module.url(forResource: "editor-schemas", withExtension: "json") else {
            preconditionFailure("Missing bundled original UI contracts")
        }
        do { return try JSONDecoder().decode(SourceEditorLibrary.self, from: Data(contentsOf: file)) }
        catch { preconditionFailure("Invalid original UI contracts: \(error)") }
    }()
    func schema(_ id: String) -> SourceEditorSchema? {
        guard let schema = schemas.first(where: { $0.id == id }) else { return nil }
        return SourceEditorSchema(id: schema.id, title: schema.title, source: schema.source,
            fields: schema.fields.map(\.withSourceCommandMetadata), children: schema.children,
            groups: schema.groups, preferredColumnWidth: schema.preferredColumnWidth)
    }
    func field(storageID: String) -> SourceEditorField? {
        let sourceID = storageID.split(separator: "/").suffix(2).joined(separator: "/")
        return schemas.lazy.flatMap(\.fields).first { $0.storageID == sourceID }.map(\.withSourceCommandMetadata)
    }
}

private extension SourceEditorField {
    var withSourceCommandMetadata: SourceEditorField {
        var result = self
        if scope.hasSuffix("LeveeModPropertiesDetailEditor") {
            switch id {
            case "Name":
                result.mixedBy = "NameHasMismatch"
                result.errorValidationSource = "LeveeModPropertiesDetailEditor"
                result.errorValidationPropertyName = "Name"
            case "Mode":
                result.mixedBy = "ModeHasMismatch"
                result.forceSetCommand = "forceSetMode"
            case "ModType":
                result.mixedBy = "ModTypeHasMismatch"
                result.forceSetCommand = "forceSetModType"
            case "TopWidthString":
                result.mixedBy = "TopWidthHasMismatch"
                result.showClearButton = true
                result.clearCommand = "forceResetTopWidth"
                result.errorValidationSource = "LeveeModPropertiesDetailEditor"
                result.errorValidationPropertyName = "TopWidth"
            case "LeftWidthString":
                result.mixedBy = "LeftWidthHasMismatch"
                result.showClearButton = true
                result.clearCommand = "forceResetLeftWidth"
                result.errorValidationSource = "LeveeModPropertiesDetailEditor"
                result.errorValidationPropertyName = "LeftWidth"
            case "RightWidthString":
                result.mixedBy = "RightWidthHasMismatch"
                result.showClearButton = true
                result.clearCommand = "forceResetRightWidth"
                result.errorValidationSource = "LeveeModPropertiesDetailEditor"
                result.errorValidationPropertyName = "RightWidth"
            case "LeftGradeString":
                result.mixedBy = "LeftGradeHasMismatch"
                result.showClearButton = true
                result.clearCommand = "forceResetLeftGrade"
                result.errorValidationSource = "LeveeModPropertiesDetailEditor"
                result.errorValidationPropertyName = "LeftGrade"
            case "RightGradeString":
                result.mixedBy = "RightGradeHasMismatch"
                result.showClearButton = true
                result.clearCommand = "forceResetRightGrade"
                result.errorValidationSource = "LeveeModPropertiesDetailEditor"
                result.errorValidationPropertyName = "RightGrade"
            default: break
            }
        } else if scope.hasSuffix("ConceptualMeshControlPointEditor") {
            switch id {
            case "PatchType":
                result.forceSetCommand = "forceSetPatchType"
            case "ConstantSizeString":
                result.showClearButton = true
                result.clearCommand = "forceResetConstantSize"
                result.errorValidationSource = "ConceptualMeshControlPointEditor"
                result.errorValidationPropertyName = "ConstantSize"
            case "SecondaryConstantSizeString":
                result.showClearButton = true
                result.clearCommand = "forceResetSecondaryConstantSize"
                result.errorValidationSource = "ConceptualMeshControlPointEditor"
                result.errorValidationPropertyName = "SecondaryConstantSize"
            case "RotationDegreesString":
                result.showClearButton = true
                result.clearCommand = "forceResetRotationDegrees"
                result.errorValidationSource = "ConceptualMeshControlPointEditor"
                result.errorValidationPropertyName = "RotationDegrees"
            case "BiasInternalString":
                result.showClearButton = true
                result.clearCommand = "forceResetBiasInternal"
                result.errorValidationSource = "ConceptualMeshControlPointEditor"
                result.errorValidationPropertyName = "BiasInternal"
            case "TinResolutionString":
                result.showClearButton = true
                result.clearCommand = "forceResetTinResolution"
                result.errorValidationSource = "ConceptualMeshControlPointEditor"
                result.errorValidationPropertyName = "TinResolution"
            case "SizeToleranceString":
                result.showClearButton = true
                result.clearCommand = "forceResetSizeTolerance"
                result.errorValidationSource = "ConceptualMeshControlPointEditor"
                result.errorValidationPropertyName = "SizeTolerance"
            default: break
            }
        }
        return result
    }
}

enum ModelEditorKind: String, CaseIterable, Identifiable, Hashable {
    case geometry = "Geometry", plan = "Plan", boundaryCondition = "Boundary Conditions"
    case terrain = "Terrain", surface = "Surface Layers", result = "Results"
    var id: String { rawValue }
    var section: ProjectSection {
        switch self {
        case .geometry: .geometries
        case .plan: .plans
        case .boundaryCondition: .boundaryConditions
        case .terrain: .terrains
        case .surface: .surfaceLayers
        case .result: .results
        }
    }
    var symbol: String { section.symbol }
    var pages: [ModelEditorPage] {
        switch self {
        case .plan: [
            .form("Summary", "PlanCatalogSummary", "PlanNodeDetails", "SmallBoundaryConditionsSummary"),
            .form("General Options", "PlanSettingsPage"),
            .form("Advanced Options", "PlanComputeSettingsPage"),
            .compute("Compute", "PlanComputeControl", "ComputeSummaryControl")]
        case .geometry: [
            .form("Summary", "GeometryCatalogSummary", "GeometrySummaryPage", "GeometryAssociationsPicker", "DetailedGeometryHeaderControl", "GeometryPrepareSummaryControl"),
            .form("Topology", "TopologyControl"),
            .table("Arcs", "TopologyArcsEditor", "ConceptualMeshArcEditor", "ArcEditor", "TopologyArcQuickEditPicker"),
            .table("Regions", "TopologyRegionsEditor", "ControlPointEditor", "ConceptualMeshControlPointEditor", "TopologyRegionQuickEditPicker"),
            .table("Nodes", "TopologyNodesEditor"),
            .form("Mesh", "FlowAreaEditorControl", "MeshErrorProperties", "FlowAreaInformation", "CartesianPatchQuickEditor", "TrianglePatchQuickEditor", "QuadPatchQuickEditorDimensionEditor"),
            .table("Culverts", "CulvertsEditor", "CulvertEditor"),
            .table("Barrel Properties", "BarrelPropertiesEditor", "BarrelPropertiesDetailEditor"),
            .table("Opening Properties", "OpeningPropertiesEditor", "OpeningPropertiesDetailEditor")]
        case .boundaryCondition: [
            .form("General Options", "BoundaryConditionsSummary"),
            .table("Boundary Lines", "BoundaryConditionLineEditor", "DetailedBCLineHeaderControl", "BoundaryConditionLinePayloadsList", "BoundaryConditionLineQuickEditPicker", "PayloadListItem", "NewPayloadPage"),
            .spatial("Spatial", "PrecipitationControl", "EvapotranspirationControl", "WindForcesControl", "WindConstantControl", "AirPressureControl")]
        case .terrain: [
            .form("Properties", "TerrainCatalogSummary", "TerrainProperties"),
            .table("Terrain Inputs", "TerrainLayersEditor", "FunctionalTerrainInputProperties"),
            .form("Terrain Modifications", "TerrainModCreator", "TerrainModStats", "LeveeModDetailEditor", "LeveeModPropertiesDetailEditor", "ChannelModParentEditor", "ChannelModEditor", "ChannelModTerrainInputProperties"),
            .form("Import Terrain", "TerrainImporter")]
        case .surface: [
            .form("Summary", "NValueCatalogSummary", "ClassificationCatalogSummary", "ClassificationLayerSummary"),
            .form("Manning’s n", "ManningsNEditor", "ConstantManningsNEditor", "ClassificationLayerManningNEditor"),
            .table("Classifications", "ClassificationLayersEditor", "ClassificationLayerSummary", "RasterClassificationInputProperties"),
            .form("Visualization", "ClassificationVisualizationOptions")]
        case .result: [
            .form("Summary", "ResultCatalogSummary", "DetailedResultHeader"),
            .form("Result Plan Settings", "ResultPlanSettingsPage"),
            .form("Result Maps", "ResultsSectionLayerProperties", "ResultNodeDetails", "MultiResultNodeDetails", "MultiResultVisualizationSettings", "ResultTerrainAssociation", "RasMapResultPicker"),
            .timeSeries("Time Series", "MapResultsChart", "DynamicTimeSeriesProfilePlot"),
            .timeSeries("Profiles", "DynamicProfilePlot"),
            .form("Velocity", "ParticleSettingsMenu"),
            .form("Raster Calculator", "RasterCalculatorEditor")]
        }
    }
}

struct ModelEditorPage: Identifiable, Hashable {
    let title: String
    let schemaIDs: [String]
    let layout: Layout
    var scopePrefix: String? = nil
    enum Layout: Hashable { case form, table, timeSeries, compute, spatial }
    var id: String { scopePrefix.map { $0 + "/" + title } ?? title }
    static func form(_ title: String, _ schemas: String...) -> Self { Self(title: title, schemaIDs: schemas, layout: .form) }
    static func table(_ title: String, _ schemas: String...) -> Self { Self(title: title, schemaIDs: schemas, layout: .table) }
    static func timeSeries(_ title: String, _ schemas: String...) -> Self { Self(title: title, schemaIDs: schemas, layout: .timeSeries) }
    static func compute(_ title: String, _ schemas: String...) -> Self { Self(title: title, schemaIDs: schemas, layout: .compute) }
    static func spatial(_ title: String, _ schemas: String...) -> Self { Self(title: title, schemaIDs: schemas, layout: .spatial) }
    static let boundaryPayloads = timeSeries("Time Series", "RegularTimeSeriesPayloadEditor", "IrregularTimeSeriesPayloadEditor", "RegularSpatiallyVariableTimeSeriesPayloadEditor", "ConstantPayloadEditor", "ExternalPayloadEditor")
}

struct EditorRow: Identifiable, Sendable {
    let id: String
    var values: [String: String]
    // Optional source bindings keep a cell and its object-property editor on
    // the same draft value. Display titles/row positions never imply identity.
    var fieldBindings: [String: String] = [:]
}
struct ChartSample: Identifiable, Sendable {
    let id: String
    var x: Double
    var y: Double
    let series: String
    var datasetID: String? = nil
    var datasetKey: String { datasetID ?? series }
}
// The UI accepts actual model snapshots through a platform-neutral boundary.
// Field/image keys are "OriginalEditorClass/OriginalBindingRoute", with an
// optional stable object scope prefix for multiple instances of the same
// editor. Adapters preserve both object identity and original binding route.
// No guessed HDF values, synthetic compute results, or .ras metadata writes
// stand in for the original model adapters.
enum EditorOperation: String, Codable, Sendable { case compute, prepareGeometry, setDefaultNValues }
struct EditorIssue: Identifiable, Sendable {
    enum Severity: String, CaseIterable, Sendable { case error, warning, info }
    let id: String
    let severity: Severity
    let message: String
    var detail: String? = nil
    var feature: String? = nil
    var location: MapPoint? = nil
}
struct EditorDiagnosticEntry: Identifiable, Sendable {
    let id: String
    let title: String
    var date: Date? = nil
    let issues: [EditorIssue]
}
struct PlanTimeWindowFieldIDs: Sendable, Equatable, Codable {
    let mode: String
    let start: String
    let end: String

    func contains(_ fieldID: String) -> Bool {
        fieldID == mode || fieldID == start || fieldID == end
    }
}
struct PlanTimeWindowEdit: Sendable, Equatable, Codable, Identifiable {
    let id: UUID
    let fieldID: String
    let value: String

    init(id: UUID = UUID(), fieldID: String, value: String) {
        self.id = id
        self.fieldID = fieldID
        self.value = value
    }
}
struct EditorSnapshot: Sendable {
    let fields: [String: String]
    var rows: [String: [EditorRow]]
    var samples: [String: [ChartSample]]
    let canEdit: Bool
    let images: [String: [ImageAttachment]]
    var editableSamplePages: Set<String> = []
    var choiceOptions: [String: [EditorChoice]] = [:]
    var fieldTitles: [String: String] = [:]
    var textSuggestions: [String: [String]] = [:]
    var sourceCollections: [String: SourceCollection] = [:]
    var tablePresentations: [String: EditorTablePresentation] = [:]
    var boundaryLines: BoundaryLinesPresentation? = nil
    var sourceRevision: String? = nil
    var fieldGroups: [String: [String]] = [:]
    var availableOperations: Set<EditorOperation> = []
    var diagnosticHistory: [EditorDiagnosticEntry] = []
    var seriesPresentations: [String: SeriesEditorPresentation] = [:]
    var spatialPresentations: [String: SpatialDatasetPresentation] = [:]
    var sourceState: String? = nil
    var readOnlyFieldIDs: Set<String> = []
    var planTimeWindowFieldIDs: PlanTimeWindowFieldIDs? = nil
    var terrainInputImportDraftToken: String? = nil
    var terrainInputImportCleanupWarning: String? = nil
    var terrainInputImportCleanupToken: String? = nil
}
struct EditorChangedCell: Codable, Hashable, Sendable {
    let rowID: String
    let columnID: String
}
struct EditorEdits: Sendable {
    let fields: [String: String]
    let rows: [String: [EditorRow]]
    let images: [String: [ImageAttachment]]
    var samples: [String: [ChartSample]] = [:]
    var sourceRevision: String? = nil
    var sourceState: String? = nil
    var planTimeWindowEdits: [PlanTimeWindowEdit] = []
    var geometryTopologyState: String? = nil
    var geometryMeshState: String? = nil
    var geometryCulvertState: String? = nil
    var tableSelections: [String: [String]] = [:]
    var changedCells: [String: [EditorChangedCell]] = [:]
}
struct PlanPrecomputeContext: Sendable {
    let id: String
    let asset: ProjectAsset
    let edits: EditorEdits
}
struct PlanPrecomputeAssociatedEditorCapture: Sendable {
    let editorID: UUID
    let contextID: String
    let asset: ProjectAsset
    let edits: EditorEdits
}
struct PlanPrecomputeAssociatedDraftsCapture: Sendable {
    let id: String
    let planContextID: String
    let projectSessionID: UUID
    let projectPath: String
    let projectXML: String
    let geometry: PlanPrecomputeAssociatedEditorCapture?
    let boundaryCondition: PlanPrecomputeAssociatedEditorCapture?
}
struct EditorSaveResult: Sendable {
    var sourceRevision: String? = nil
    var snapshot: EditorSnapshot? = nil
}
struct EditorContextRefresh: Sendable {
    let baseline: EditorSnapshot
    let draft: EditorSnapshot
}
@MainActor
protocol ModelEditorProvider {
    var supportsProjectContextRefresh: Bool { get }
    func refreshProjectContext(_ asset: ProjectAsset, edits: EditorEdits) async throws -> EditorContextRefresh
    func setProject(_ document: ProjectDocument?)
    func catalogSurfaceLayers(_ assets: [ProjectAsset]) async throws -> [SurfaceCatalogEntry]
    func load(_ asset: ProjectAsset, kind: ModelEditorKind) async throws -> EditorSnapshot
    func save(_ asset: ProjectAsset, changes: EditorEdits) async throws
    func saveModel(_ asset: ProjectAsset, changes: EditorEdits) async throws -> EditorSaveResult
    func perform(_ asset: ProjectAsset, action: EditorAction) async throws -> EditorSnapshot
    func perform(_ asset: ProjectAsset, action: EditorAction, edits: EditorEdits) async throws -> EditorSnapshot
    func classificationMap(_ asset: ProjectAsset, edits: EditorEdits) async throws -> ClassificationMapData
    func inspectClassification(_ asset: ProjectAsset, edits: EditorEdits, files: [URL], selections: [ClassificationImportFile]) async throws -> ClassificationImportInspection
    func importClassification(_ asset: ProjectAsset, edits: EditorEdits, files: [ClassificationImportFile]) async throws -> EditorSaveResult
    func inspectTerrainInputImport(_ asset: ProjectAsset, edits: EditorEdits, files: [URL]) async throws -> TerrainInputImportInspection
    func makeTerrainInputAppendRequest(_ asset: ProjectAsset, edits: EditorEdits, selections: [TerrainInputImportSelection], stitchTiles: Bool, draftToken: String, batchToken: String) throws -> TerrainInputAppendRequest
    func appendTerrainInputImport(_ asset: ProjectAsset, request: TerrainInputAppendRequest) async throws -> TerrainInputAppendResult
    func terrainInputImportStatus(_ asset: ProjectAsset, request: TerrainInputAppendRequest) async throws -> TerrainInputImportStatus
    func cancelTerrainInputImport(_ asset: ProjectAsset, request: TerrainInputAppendRequest, operationID: String?) async throws -> TerrainInputImportCancelReceipt
    func discardTerrainInputImport(_ asset: ProjectAsset, draftToken: String) async throws -> Bool
    func discardTerrainInputImportBatch(_ asset: ProjectAsset, draftToken: String, batchToken: String) async throws -> Bool
    func inspectGrid(_ asset: ProjectAsset, edits: EditorEdits, layerID: String, files: [URL], subdataset: String?, bands: [SpatialGridBand], previewID: String?) async throws -> SpatialGridInspection
    func importGrid(_ asset: ProjectAsset, edits: EditorEdits, selection: SpatialGridSelection) async throws -> EditorSaveResult
    func importCumulusGrid(_ asset: ProjectAsset, edits: EditorEdits, selection: CumulusGridImportSelection, progress: @escaping @MainActor (BackendProgressUpdate) -> Void) async throws -> EditorSaveResult
    func editSeries(_ asset: ProjectAsset, request: SeriesEditRequest) async throws -> SeriesEditResult
    func editClassification(_ asset: ProjectAsset, action: EditorAction, edits: EditorEdits) async throws -> EditorSnapshot
    func editTerrain(_ asset: ProjectAsset, action: EditorAction, edits: EditorEdits) async throws -> EditorSnapshot
    func terrainMap(_ asset: ProjectAsset, edits: EditorEdits, inputID: String?) async throws -> TerrainMapData
    func editTerrainTopology(_ asset: ProjectAsset, inputID: String, operation: TerrainTopologyOperation, featureIDs: [String], points: [TerrainMapCoordinate], mapCellSize: Double?, edits: EditorEdits) async throws -> TerrainTopologyResponse
    func editTerrainTopology(_ asset: ProjectAsset, inputID: String, command: TerrainTopologyCommand, expectedDraftIdentity: String?, edits: EditorEdits) async throws -> TerrainTopologyResponse
    func editManning(_ asset: ProjectAsset, operation: String, edits: EditorEdits) async throws -> EditorSnapshot
    func editBoundary(_ asset: ProjectAsset, action: EditorAction, edits: EditorEdits) async throws -> EditorSnapshot
    func editPatch(_ asset: ProjectAsset, request: PatchEditRequest) async throws -> PatchEditResult
}
extension ModelEditorProvider {
    var supportsProjectContextRefresh: Bool { false }
    func refreshProjectContext(_ asset: ProjectAsset, edits: EditorEdits) async throws -> EditorContextRefresh { throw CocoaError(.featureUnsupported) }
    func perform(_ asset: ProjectAsset, action: EditorAction, edits: EditorEdits) async throws -> EditorSnapshot { try await perform(asset, action: action) }
    func classificationMap(_ asset: ProjectAsset, edits: EditorEdits) async throws -> ClassificationMapData { throw CocoaError(.featureUnsupported) }
    func inspectClassification(_ asset: ProjectAsset, edits: EditorEdits, files: [URL], selections: [ClassificationImportFile]) async throws -> ClassificationImportInspection { throw CocoaError(.featureUnsupported) }
    func importClassification(_ asset: ProjectAsset, edits: EditorEdits, files: [ClassificationImportFile]) async throws -> EditorSaveResult { throw CocoaError(.featureUnsupported) }
    func inspectTerrainInputImport(_ asset: ProjectAsset, edits: EditorEdits, files: [URL]) async throws -> TerrainInputImportInspection { throw CocoaError(.featureUnsupported) }
    func makeTerrainInputAppendRequest(_ asset: ProjectAsset, edits: EditorEdits, selections: [TerrainInputImportSelection], stitchTiles: Bool, draftToken: String, batchToken: String) throws -> TerrainInputAppendRequest { throw CocoaError(.featureUnsupported) }
    func appendTerrainInputImport(_ asset: ProjectAsset, request: TerrainInputAppendRequest) async throws -> TerrainInputAppendResult { throw CocoaError(.featureUnsupported) }
    func terrainInputImportStatus(_ asset: ProjectAsset, request: TerrainInputAppendRequest) async throws -> TerrainInputImportStatus { throw CocoaError(.featureUnsupported) }
    func cancelTerrainInputImport(_ asset: ProjectAsset, request: TerrainInputAppendRequest, operationID: String?) async throws -> TerrainInputImportCancelReceipt { throw CocoaError(.featureUnsupported) }
    func discardTerrainInputImport(_ asset: ProjectAsset, draftToken: String) async throws -> Bool { throw CocoaError(.featureUnsupported) }
    func discardTerrainInputImportBatch(_ asset: ProjectAsset, draftToken: String, batchToken: String) async throws -> Bool { throw CocoaError(.featureUnsupported) }
    func inspectGrid(_ asset: ProjectAsset, edits: EditorEdits, layerID: String, files: [URL], subdataset: String?, bands: [SpatialGridBand], previewID: String?) async throws -> SpatialGridInspection { throw CocoaError(.featureUnsupported) }
    func importGrid(_ asset: ProjectAsset, edits: EditorEdits, selection: SpatialGridSelection) async throws -> EditorSaveResult { throw CocoaError(.featureUnsupported) }
    func importCumulusGrid(_ asset: ProjectAsset, edits: EditorEdits, selection: CumulusGridImportSelection, progress: @escaping @MainActor (BackendProgressUpdate) -> Void) async throws -> EditorSaveResult { throw CocoaError(.featureUnsupported) }
    func setProject(_ document: ProjectDocument?) {}
    func catalogSurfaceLayers(_ assets: [ProjectAsset]) async throws -> [SurfaceCatalogEntry] { [] }
    func editSeries(_ asset: ProjectAsset, request: SeriesEditRequest) async throws -> SeriesEditResult { throw CocoaError(.featureUnsupported) }
    func editClassification(_ asset: ProjectAsset, action: EditorAction, edits: EditorEdits) async throws -> EditorSnapshot { throw CocoaError(.featureUnsupported) }
    func editTerrain(_ asset: ProjectAsset, action: EditorAction, edits: EditorEdits) async throws -> EditorSnapshot { throw CocoaError(.featureUnsupported) }
    func terrainMap(_ asset: ProjectAsset, edits: EditorEdits, inputID: String?) async throws -> TerrainMapData { throw CocoaError(.featureUnsupported) }
    func editTerrainTopology(_ asset: ProjectAsset, inputID: String, operation: TerrainTopologyOperation, featureIDs: [String], points: [TerrainMapCoordinate], mapCellSize: Double?, edits: EditorEdits) async throws -> TerrainTopologyResponse { throw CocoaError(.featureUnsupported) }
    func editTerrainTopology(_ asset: ProjectAsset, inputID: String, command: TerrainTopologyCommand, expectedDraftIdentity: String?, edits: EditorEdits) async throws -> TerrainTopologyResponse {
        switch command.operation {
        case .load, .select, .draw, .remove, .undo, .redo, .sortProfile:
            return try await editTerrainTopology(asset, inputID: inputID, operation: command.operation,
                featureIDs: command.featureIDs, points: command.points, mapCellSize: command.mapCellSize, edits: edits)
        default: throw CocoaError(.featureUnsupported)
        }
    }
    func editManning(_ asset: ProjectAsset, operation: String, edits: EditorEdits) async throws -> EditorSnapshot { throw CocoaError(.featureUnsupported) }
    func editBoundary(_ asset: ProjectAsset, action: EditorAction, edits: EditorEdits) async throws -> EditorSnapshot { throw CocoaError(.featureUnsupported) }
    func editPatch(_ asset: ProjectAsset, request: PatchEditRequest) async throws -> PatchEditResult { throw CocoaError(.featureUnsupported) }
    func saveModel(_ asset: ProjectAsset, changes: EditorEdits) async throws -> EditorSaveResult {
        try await save(asset, changes: changes)
        return EditorSaveResult()
    }
}
enum EditorAction: Sendable {
    case compute, prepareGeometry, setDefaultNValues, refreshManning
    case addRow(table: String), copyRows(table: String, ids: Set<String>), removeRows(table: String, ids: Set<String>)
    case reorderSource(field: String, from: Int, to: Int)
    case importSource(field: String, files: [URL])
    case selectSource(field: String, id: String?)
    case selectTableRows(table: String, ids: Set<String>)
    case selectSpatialTime(layerID: String, stepID: String?)
    case refreshSeries(pageID: String)
    case removeSource(field: String, id: String)
    case addTerrainInput(TerrainInputCreationKind, hintExtent: TerrainInputValidExtent? = nil)
    case editClassificationGeometry(ClassificationGeometryMutation)
    case selectPolygonClassifications(field: String, scope: String, ids: Set<String>)
    case createBoundaryPayload(lineID: String, fields: [String: String])
    case removeBoundaryPayload(lineID: String, payloadID: String)
    case editSpatial(layerID: String, operation: String, itemID: String?)
}

@MainActor
final class ModelEditorSession: ObservableObject {
    private struct TerrainInputImportAttempt {
        let asset: ProjectAsset
        let request: TerrainInputAppendRequest
        let expectedIdentity: String
        let loadRevision: Int
        let editRevision: Int
        let savedBaseline: EditorSnapshot
        let changedFieldIDs: Set<String>
        let changedImageFieldIDs: Set<String>
        let images: [String: [ImageAttachment]]
        let changedSamplePages: Set<String>
        let clearedMixedFieldIDs: Set<String>
        let patchDisplayFieldIDs: Set<String>
        let changedToolCells: [String: Set<ToolCell>]
        let changedSeriesPages: Set<String>
        let wasModified: Bool
        var cancelRequested: Bool
    }
    // Incomplete date/time text belongs to the editor, not to the C# model.
    // Retaining it here makes page replacement and Save All observe the same
    // pending input instead of silently saving the last valid field value.
    @Published private(set) var dateTimeInputDrafts: [String: OriginalDateTimeInputDraft] = [:]
    func dateTimeInputDraft(for fieldID: String, sourceValue: String) -> OriginalDateTimeInputDraft? {
        guard let draft = dateTimeInputDrafts[fieldID] else { return nil }
        guard draft.sourceValue == sourceValue else {
            clearDateTimeInputDraft(for: fieldID)
            return nil
        }
        return draft
    }
    func setDateTimeInputDraft(_ draft: OriginalDateTimeInputDraft, for fieldID: String) {
        guard !isWriteLocked, canEdit, !isSaving, !isPerforming,
              !readOnlyFieldIDs.contains(fieldID), fields[fieldID, default: ""] == draft.sourceValue,
              dateTimeInputDrafts[fieldID] != draft else { return }
        dateTimeInputDrafts[fieldID] = draft
        editRevision += 1
    }
    func clearDateTimeInputDraft(for fieldID: String) {
        guard dateTimeInputDrafts.removeValue(forKey: fieldID) != nil else { return }
        editRevision += 1
    }
    var hasIncompleteDateTimeInput: Bool { !dateTimeInputDrafts.isEmpty }
    @Published private(set) var unitNumberInputDrafts: [OriginalUnitNumberInputOwner: OriginalUnitNumberInputDraft] = [:]
    private var committingUnitNumberInputOwner: OriginalUnitNumberInputOwner?

    var hasIncompleteUnitNumberInput: Bool { !unitNumberInputDrafts.isEmpty }
    var hasIncompleteEditorInput: Bool {
        hasIncompleteDateTimeInput || hasIncompleteUnitNumberInput || geometryTopology?.hasPendingInputs == true
    }
    var incompleteEditorInputIssue: String? {
        if let dateEntry = dateTimeInputDrafts.sorted(by: { $0.key < $1.key }).first {
            let draft = dateEntry.value
            guard let key = draft.issueKey else { return L10n.text("Improperly formatted date.") }
            if key == OriginalDateTimeInputIssue.startsAfterBoundaryTemplate {
                return L10n.format(key, draft.issueArgument ?? "")
            }
            return L10n.text(key)
        }
        if let entry = unitNumberInputDrafts.sorted(by: { $0.key.stableKey < $1.key.stableKey }).first {
            return L10n.text(unitNumberInputDraft(for: entry.key)?.issueKey ?? OriginalUnitNumberInputIssue.invalidNumber)
        }
        return geometryTopology?.pendingInputIssue.map { L10n.text($0) }
    }

    func unitNumberInputDraft(for owner: OriginalUnitNumberInputOwner) -> OriginalUnitNumberInputDraft? {
        guard var draft = unitNumberInputDrafts[owner] else { return nil }
        let currentValue = unitNumberSourceValue(for: owner)
        let selectedID = displayUnitSelections[draft.context.selectionID] ?? draft.context.sourceID
        if draft.isStale || draft.context.editorIdentity != numericCalculatorIdentity
            || currentValue != draft.context.sourceValue || selectedID != draft.context.unitID {
            draft.isStale = true
            draft.issueKey = OriginalUnitNumberInputIssue.staleNumber
        }
        return draft
    }

    func unitNumberInputDraft(for owner: OriginalUnitNumberInputOwner, units: DisplayUnitData, locale: Locale = .autoupdatingCurrent) -> OriginalUnitNumberInputDraft? {
        guard var draft = unitNumberInputDrafts[owner] else { return nil }
        guard let current = unitNumberInputContext(for: owner, units: units, locale: locale),
              !draft.isStale, draft.context == current else {
            draft.isStale = true
            draft.issueKey = OriginalUnitNumberInputIssue.staleNumber
            return draft
        }
        return draft
    }

    func unitNumberInputContext(for owner: OriginalUnitNumberInputOwner, units: DisplayUnitData, locale: Locale = .autoupdatingCurrent) -> OriginalUnitNumberInputContext? {
        guard (try? units.validate()) != nil, let unit = displayUnit(units),
              let binding = unitNumberInputBinding(for: owner) else { return nil }
        return .init(editorIdentity: numericCalculatorIdentity, sourceValue: binding.value,
            fieldBindingID: binding.fieldBindingID, sourceType: binding.sourceType,
            selectionID: units.selectionId, sourceID: units.sourceId, sourceUnitTypeID: units.sourceUnitTypeId,
            unitID: unit.id, unitTypeID: unit.unitTypeId, scale: unit.scale, offset: unit.offset,
            localeIdentifier: locale.identifier)
    }

    func unitNumberInputIssue(for owner: OriginalUnitNumberInputOwner, units: DisplayUnitData, locale: Locale = .autoupdatingCurrent) -> String? {
        unitNumberInputDraft(for: owner, units: units, locale: locale)?.issueKey
    }

    func hasUnitNumberInputDraft(selectionID: String) -> Bool {
        unitNumberInputDrafts.values.contains { $0.context.selectionID == selectionID }
    }

    @discardableResult
    func updateUnitNumberInput(rawText: String, owner: OriginalUnitNumberInputOwner, units: DisplayUnitData,
                               locale: Locale = .autoupdatingCurrent,
                               expectedContext: OriginalUnitNumberInputContext? = nil) -> OriginalUnitNumberInputContext? {
        guard !isWriteLocked, canEdit, !isSaving, !isPerforming, !loadingSelection,
              !isReadOnlyUnitNumberOwner(owner),
              let current = unitNumberInputContext(for: owner, units: units, locale: locale) else { return nil }

        let previous = unitNumberInputDrafts[owner]
        let captured = previous?.context ?? expectedContext ?? current
        if captured != current || previous?.isStale == true {
            storeUnitNumberInputDraft(.init(context: captured, rawDisplayText: rawText,
                issueKey: OriginalUnitNumberInputIssue.staleNumber, isStale: true), for: owner)
            return captured
        }
        if let expectedContext, expectedContext != current {
            storeUnitNumberInputDraft(.init(context: expectedContext, rawDisplayText: rawText,
                issueKey: OriginalUnitNumberInputIssue.staleNumber, isStale: true), for: owner)
            return expectedContext
        }
        if hasOtherUnitNumberDraft(bindingID: current.fieldBindingID, owner: owner) { return nil }

        if rawText.isEmpty {
            if current.sourceValue.isEmpty {
                clearUnitNumberInputDraft(for: owner)
                return unitNumberInputContext(for: owner, units: units, locale: locale)
            }
            guard commitUnitNumberInput("", owner: owner), unitNumberSourceValue(for: owner) == "" else {
                storeUnitNumberInputDraft(.init(context: current, rawDisplayText: rawText), for: owner)
                return current
            }
            clearUnitNumberInputDraft(for: owner)
            return unitNumberInputContext(for: owner, units: units, locale: locale)
        }

        guard let displayed = OriginalUnitNumberInputCodec.parse(rawText, locale: locale),
              let unit = units.choices.first(where: { $0.id == current.unitID }),
              var sourceValue = OriginalUnitNumberInputCodec.sourceValue(fromDisplayValue: displayed, using: unit) else {
            storeUnitNumberInputDraft(.init(context: current, rawDisplayText: rawText), for: owner)
            return current
        }
        if current.sourceType == "float" {
            guard let single = Float(sourceValue), single.isFinite else {
                storeUnitNumberInputDraft(.init(context: current, rawDisplayText: rawText), for: owner)
                return current
            }
            sourceValue = String(single)
        }

        if let existing = Double(current.sourceValue), existing.isFinite, unit.displayed(existing) == displayed {
            clearUnitNumberInputDraft(for: owner)
            return unitNumberInputContext(for: owner, units: units, locale: locale)
        }
        guard commitUnitNumberInput(sourceValue, owner: owner), unitNumberSourceValue(for: owner) == sourceValue else {
            storeUnitNumberInputDraft(.init(context: current, rawDisplayText: rawText,
                issueKey: OriginalUnitNumberInputIssue.staleNumber, isStale: true), for: owner)
            return current
        }
        clearUnitNumberInputDraft(for: owner)
        return unitNumberInputContext(for: owner, units: units, locale: locale)
    }

    func reconcileUnitNumberInputDraft(for owner: OriginalUnitNumberInputOwner, units: DisplayUnitData,
                                       locale: Locale = .autoupdatingCurrent,
                                       focusedContext: OriginalUnitNumberInputContext? = nil,
                                       focusedRawText: String? = nil) {
        let draft = unitNumberInputDrafts[owner]
        guard draft?.isStale != true else { return }
        let capturedContext = draft?.context ?? focusedContext
        let rawText = draft?.rawDisplayText ?? focusedRawText
        guard let capturedContext, let rawText else { return }
        guard let current = unitNumberInputContext(for: owner, units: units, locale: locale), capturedContext == current else {
            storeUnitNumberInputDraft(.init(context: capturedContext, rawDisplayText: rawText,
                issueKey: OriginalUnitNumberInputIssue.staleNumber, isStale: true), for: owner)
            return
        }
    }

    func clearUnitNumberInputDraft(for owner: OriginalUnitNumberInputOwner) {
        guard unitNumberInputDrafts.removeValue(forKey: owner) != nil else { return }
        editRevision += 1
    }

    @Published private(set) var displayUnitSelections: [String: String] = [:]
    func displayUnit(_ units: DisplayUnitData) -> DisplayUnitChoice? {
        units.choices.first { $0.id == (displayUnitSelections[units.selectionId] ?? units.sourceId) } ?? units.choices.first { $0.id == units.sourceId }
    }
    func selectDisplayUnit(_ id: String, units: DisplayUnitData) {
        guard !isWriteLocked, !hasUnitNumberInputDraft(selectionID: units.selectionId),
              units.choices.contains(where: { $0.id == id }), displayUnitSelections[units.selectionId] != id else { return }
        displayUnitSelections[units.selectionId] = id
    }

    private func unitNumberInputBinding(for owner: OriginalUnitNumberInputOwner) -> (value: String, fieldBindingID: String?, sourceType: String)? {
        guard loaded else { return nil }
        switch owner {
        case .field(let fieldID):
            guard let value = fields[fieldID] else { return nil }
            let sourceType = SourceEditorLibrary.shared.field(storageID: fieldID)?.sourceType ?? "double"
            return (value, fieldID, sourceType)
        case .tableCell(let tableID, let rowID, let columnID):
            guard let column = tablePresentations[tableID]?.columns.first(where: { $0.id == columnID }),
                  ["double", "float"].contains(column.sourceType), column.readOnly != true,
                  let row = rows[tableID]?.first(where: { $0.id == rowID }),
                  let value = row.values[columnID] else { return nil }
            return (value, row.fieldBindings[columnID], column.sourceType)
        }
    }

    private func unitNumberSourceValue(for owner: OriginalUnitNumberInputOwner) -> String? {
        switch owner {
        case .field(let fieldID): fields[fieldID]
        case .tableCell(let tableID, let rowID, let columnID):
            rows[tableID]?.first(where: { $0.id == rowID })?.values[columnID]
        }
    }

    private func isReadOnlyUnitNumberOwner(_ owner: OriginalUnitNumberInputOwner) -> Bool {
        switch owner {
        case .field(let fieldID):
            readOnlyFieldIDs.contains(fieldID) || SourceEditorLibrary.shared.field(storageID: fieldID)?.readOnly == true
        case .tableCell(let tableID, _, let columnID):
            tablePresentations[tableID]?.columns.first(where: { $0.id == columnID })?.readOnly == true
                || unitNumberInputBinding(for: owner) == nil
        }
    }

    private func hasOtherUnitNumberDraft(bindingID: String?, owner: OriginalUnitNumberInputOwner) -> Bool {
        guard let bindingID else { return false }
        return unitNumberInputDrafts.contains { candidate, draft in
            candidate != owner && (candidate == .field(bindingID) || draft.context.fieldBindingID == bindingID)
        }
    }

    private func storeUnitNumberInputDraft(_ draft: OriginalUnitNumberInputDraft, for owner: OriginalUnitNumberInputOwner) {
        guard unitNumberInputDrafts[owner] != draft else { return }
        unitNumberInputDrafts[owner] = draft
        editRevision += 1
    }

    private func commitUnitNumberInput(_ value: String, owner: OriginalUnitNumberInputOwner) -> Bool {
        committingUnitNumberInputOwner = owner
        defer { committingUnitNumberInputOwner = nil }
        switch owner {
        case .field(let fieldID): set(fieldID, value)
        case .tableCell(let tableID, let rowID, let columnID): setCell(table: tableID, rowID: rowID, column: columnID, value: value)
        }
        return unitNumberSourceValue(for: owner) == value
    }

    private func hasUnitNumberDraftBlockingField(_ fieldID: String) -> Bool {
        unitNumberInputDrafts.contains { owner, draft in
            guard owner != committingUnitNumberInputOwner else { return false }
            if owner == .field(fieldID) { return true }
            return draft.context.fieldBindingID == fieldID
        }
    }

    private func hasUnitNumberDraftBlockingCell(tableID: String, rowID: String, columnID: String) -> Bool {
        let cell = OriginalUnitNumberInputOwner.tableCell(tableID: tableID, rowID: rowID, columnID: columnID)
        let bindingID = rows[tableID]?.first(where: { $0.id == rowID })?.fieldBindings[columnID]
        return unitNumberInputDrafts.contains { owner, draft in
            guard owner != committingUnitNumberInputOwner else { return false }
            if owner == cell { return true }
            if case .field(let fieldID) = owner, fieldID == bindingID { return true }
            return bindingID != nil && draft.context.fieldBindingID == bindingID
        }
    }

    private(set) var sourceState: String?
    @Published private(set) var readOnlyFieldIDs: Set<String> = []
    private var sourceRevision: String?
    var sourceFileRevision: String? { sourceRevision }
    var terrainSourceRevision: String? { sourceRevision }
    private var terrainTopologyDraftIdentities: [String: (identity: String, editRevision: Int)] = [:]
    private var fieldGroups: [String: [String]] = [:]
    @Published private(set) var availableOperations: Set<EditorOperation> = []
    @Published private(set) var diagnosticHistory: [EditorDiagnosticEntry] = []
    @Published private(set) var seriesPresentations: [String: SeriesEditorPresentation] = [:]
    @Published private(set) var spatialPresentations: [String: SpatialDatasetPresentation] = [:]
    let id = UUID()
    @Published var fields: [String: String] = [:]
    @Published var rows: [String: [EditorRow]] = [:]
    @Published var samples: [String: [ChartSample]] = [:]
    @Published var images: [String: [ImageAttachment]] = [:]
    @Published private(set) var choiceOptions: [String: [EditorChoice]] = [:]
    @Published private(set) var fieldTitles: [String: String] = [:]
    @Published private(set) var textSuggestions: [String: [String]] = [:]
    @Published private(set) var sourceCollections: [String: SourceCollection] = [:]
    @Published private(set) var tablePresentations: [String: EditorTablePresentation] = [:]
    @Published private(set) var boundaryLines: BoundaryLinesPresentation?
    @Published private(set) var selectedBoundaryLineID: String?
    @Published private(set) var selectedBoundaryPayloadIDs: [String: String] = [:]
    @Published private(set) var loaded = false
    @Published private(set) var canEdit = false
    @Published private(set) var modified = false
    @Published private(set) var isSaving = false { didSet { if !isSaving { scheduleProjectContextRefresh() } } }
    @Published private(set) var isPerforming = false { didSet { if !isPerforming { scheduleProjectContextRefresh() } } }
    @Published private(set) var isRefreshingContext = false
    @Published private(set) var loadingSelection = false
    @Published private(set) var terrainInputImportDraftToken: String?
    @Published private(set) var terrainInputImportCleanupWarning: String?
    @Published private(set) var terrainInputImportCleanupToken: String?
    @Published private(set) var terrainInputImportCleanupBatchToken: String?
    @Published private(set) var terrainInputImportCleanupAfterSave = false
    @Published private(set) var isTerrainInputImportRunning = false
    let terrainUSGSImportCleanup = TerrainUSGSImportCleanupSession()
    @Published private(set) var isTerrainInputImportCancelling = false
    @Published private(set) var terrainInputImportStatus: TerrainInputImportStatus?
    @Published private(set) var coreLayerReferenceConflict: String?
    var hasCoreLayerReferenceConflict: Bool { coreLayerReferenceConflict != nil }
    private var terrainInputImportAttempt: TerrainInputImportAttempt?
    var canRecheckTerrainInputImportStatus: Bool {
        guard terrainInputImportCleanupBatchToken != nil, let attempt = terrainInputImportAttempt,
              !isTerrainInputImportRunning else { return false }
        return isCurrentTerrainInputImportAttempt(attempt)
    }
    var canCancelTerrainInputImportOperation: Bool {
        guard let request = terrainInputImportAttempt?.request else { return false }
        return !request.stitchTiles && request.files.count > 1
    }
    var hasPendingTopologyEdit: Bool { geometryTopology?.isEditing == true }
    var hasPendingGeometryEdit: Bool {
        hasPendingTopologyEdit || geometryMesh?.isEditing == true || geometryCulvert?.isEditing == true
            || geometryCulvert?.hasActiveSketch == true
    }
    var isWriteLocked: Bool { hasCoreLayerReferenceConflict || workspaceWriteLocked() }
    // Core source conflicts preserve a stale editor draft and block its writes,
    // but they are not a running operation. Lifecycle and recovery actions need
    // to distinguish that state so the user can explicitly discard or reload it.
    var isBusyExceptCoreLayerConflict: Bool {
        workspaceWriteLocked() || planCompute?.isRunning == true || isSaving || isPerforming
            || isTerrainInputImportRunning || hasPendingGeometryEdit
            || geometryMesh?.isSavingDiagnosticsPreferences == true || resultPlanSettings?.isBusy == true
    }
    var isBusy: Bool { hasCoreLayerReferenceConflict || isBusyExceptCoreLayerConflict }
    var hasUnsavedEditorChanges: Bool { modified || hasIncompleteEditorInput || hasPendingGeometryEdit || geometryMesh?.hasUnsavedDiagnosticsPreferences == true || resultPlanSettings?.hasUnsavedChanges == true }
    var canSave: Bool {
        guard loaded, !loadingSelection, !isBusy, !hasIncompleteEditorInput,
              coreLayerReferenceConflict == nil else { return false }
        if resultPlanSettings?.hasUnsavedChanges == true {
            guard !hasGeometryDraftChanges, !hasOrdinaryDraftChanges,
                  geometryMesh?.hasUnsavedDiagnosticsPreferences != true,
                  let requestedAsset = asset,
                  let capture = currentResultPlanSettingsCapture(for: requestedAsset),
                  resultPlanSettings?.captureDraft(for: capture) != nil else { return false }
            return true
        }
        return canEdit && hasUnsavedEditorChanges
    }
    @Published var error: String?
    let provider: (any ModelEditorProvider)?
    var didSave: (@MainActor () -> Void)?
    var didSaveModelSnapshot: (@MainActor (EditorSnapshot, CoreLayerRequestContext?, String?) -> Void)?
    var persistDiagnosticsPreferences: (@MainActor (GeometryMeshDiagnosticsPreferencesCapture) async throws -> String)?
    var workspaceWriteLocked: @MainActor () -> Bool = { false }
    var currentResultPlanSettingsContext: (@MainActor () -> PlanSettingsResultCapture?)?
    var beginPlanCompute: (@MainActor (PlanComputeInspection) -> Bool)?
    var endPlanCompute: (@MainActor () -> Void)?
    var didComputePlan: (@MainActor (PlanComputeExecutionResult) -> Void)?
    private var asset: ProjectAsset?
    private var geometryProjectContextTask: Task<Void, Never>?
    private var geometryProjectContextGeneration = 0
    var modelAssetID: String? { asset?.id }
    var isSourcePlan: Bool { asset?.section == .plans }
    private var baseline: EditorSnapshot?
    var modelName: String? { asset?.name }
    private(set) var loadRevision = 0
    var numericCalculatorIdentity: String {
        "\(id.uuidString)|\(loadRevision)|\(asset?.id ?? "")|\(sourceRevision ?? "")"
    }
    private var editRevision = 0
    var terrainEditRevision: Int { editRevision }
    private var changedFieldIDs: Set<String> = []
    private var changedSamplePages: Set<String> = []
    private var changedSeriesPages: Set<String> = []
    private var isEditingSourceDraft = false
    private var changedImageFieldIDs: Set<String> = []
    private var clearedMixedFieldIDs: Set<String> = []
    private var patchDisplayFieldIDs: Set<String> = []
    private var selectionRevision = 0
    private var contextRefreshRevision = 0
    private var contextRefreshTask: Task<Void, Never>?
    private var contextRefreshPending = false
    private struct ToolCell: Hashable { let rowID: String; let columnID: String }
    private var changedToolCells: [String: Set<ToolCell>] = [:]
    private var editableSamplePages: Set<String> = []
    private var planTimeWindowFieldIDs: PlanTimeWindowFieldIDs?
    private var planTimeWindowEdits: [PlanTimeWindowEdit] = []
    private var protectedPlanTimeWindowEventIDs: [UUID: Int] = [:]
    let geometryTopology: GeometryTopologySession?
    let geometryMesh: GeometryMeshSession?
    let geometryCulvert: GeometryCulvertSession?
    let resultInspector: ResultInspectorSession?
    let resultPlanSettings: ResultPlanSettingsEditorSession?
    let planResults: PlanResultSelectionSession?
    let planCompute: PlanComputeSession?
    private var childSubscriptions: [AnyCancellable] = []
    init(provider: (any ModelEditorProvider)? = nil,
         topologyProvider: (any GeometryTopologyProvider)? = nil,
         meshProvider: (any GeometryMeshProvider)? = nil,
         culvertProvider: (any GeometryCulvertProvider)? = nil,
         computeProvider: (any PlanComputeProvider)? = nil,
         resultPlanSettingsProvider: (any ResultPlanSettingsEditing)? = nil) {
        self.provider = provider
        let backend = provider as? BackendModelProvider
        let sourceTopology: (any GeometryTopologyProvider)? = topologyProvider ?? backend.map { backend in
            BackendGeometryTopologyProvider(client: backend.client,
                currentProject: { [weak backend] in backend?.project },
                currentCoreLayerContext: { [weak backend] in backend?.captureCoreLayerContext() })
        }
        geometryTopology = sourceTopology.map { GeometryTopologySession(provider: $0) }
        let topologyChild = geometryTopology
        let sourceMesh: (any GeometryMeshProvider)? = meshProvider ?? backend.map { backend in
            BackendGeometryMeshProvider(client: backend.client,
                currentProject: { [weak backend] in backend?.project },
                currentCoreLayerContext: { [weak backend] in backend?.captureCoreLayerContext() },
                currentTopologyDraftState: { [weak topologyChild] in topologyChild?.topologyStateForParentSave })
        }
        let sourceCulverts: (any GeometryCulvertProvider)? = culvertProvider ?? backend.map { backend in
            BackendGeometryCulvertProvider(client: backend.client,
                currentProject: { [weak backend] in backend?.project },
                currentCoreLayerContext: { [weak backend] in backend?.captureCoreLayerContext() })
        }
        geometryMesh = sourceMesh.map { GeometryMeshSession(provider: $0) }
        geometryCulvert = sourceCulverts.map { GeometryCulvertSession(provider: $0) }
        resultInspector = backend.map { ResultInspectorSession(provider: BackendResultInspectorProvider(client: $0.client)) }
        let sourceResultPlanSettings: (any ResultPlanSettingsEditing)? = resultPlanSettingsProvider
            ?? backend.map { BackendPlanSettingsEmbeddedResultProvider(client: $0.client) }
        resultPlanSettings = sourceResultPlanSettings.map { ResultPlanSettingsEditorSession(provider: $0) }
        planResults = backend.map { PlanResultSelectionSession(provider: BackendPlanResultCatalogProvider(client: $0.client)) }
        let sourceCompute = computeProvider ?? (provider as? any PlanComputeProvider)
        planCompute = sourceCompute.map { PlanComputeSession(provider: $0) }
        if let planCompute {
            childSubscriptions.append(planCompute.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() })
        }
        if let planResults {
            childSubscriptions.append(planResults.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() })
        }
        if let resultInspector {
            childSubscriptions.append(resultInspector.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() })
        }
        if let resultPlanSettings {
            childSubscriptions.append(resultPlanSettings.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            })
            resultPlanSettings.onParentDraftChange = { [weak self] dirty in
                self?.resultPlanSettingsDraftDidChange(dirty)
            }
        }
        // All three child ledgers share the parent save boundary. A callback
        // from one child must retain unsaved changes owned by the others.
        if let geometryTopology {
            childSubscriptions.append(geometryTopology.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() })
            geometryTopology.onParentDraftChange = { [weak self] dirty in self?.geometryDraftDidChange(dirty) }
        }
        if let geometryMesh {
            childSubscriptions.append(geometryMesh.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() })
            geometryMesh.onParentDraftChange = { [weak self] dirty in self?.geometryDraftDidChange(dirty) }
        }
        if let geometryCulvert {
            childSubscriptions.append(geometryCulvert.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() })
            geometryCulvert.onParentDraftChange = { [weak self] dirty in self?.geometryDraftDidChange(dirty) }
        }
    }
    private var hasGeometryDraftChanges: Bool {
        geometryTopology?.isDirty == true || geometryMesh?.isDirty == true || geometryCulvert?.isDirty == true
            || geometryCulvert?.hasActiveSketch == true
    }
    private func geometryDraftDidChange(_ dirty: Bool) {
        if dirty { editRevision += 1 }
        modified = hasGeometryDraftChanges || hasOrdinaryDraftChanges
    }
    private func resultPlanSettingsDraftDidChange(_ dirty: Bool) {
        if dirty { editRevision += 1 }
        modified = hasGeometryDraftChanges || hasOrdinaryDraftChanges || resultPlanSettings?.hasUnsavedChanges == true
    }
    private func invalidateGeometryChildren() {
        geometryProjectContextGeneration += 1
        if let geometryProjectContextTask {
            geometryProjectContextTask.cancel()
            self.geometryProjectContextTask = nil
            isPerforming = false
        }
        geometryTopology?.invalidate()
        geometryMesh?.invalidate()
        geometryCulvert?.invalidate()
    }
    private var hasOrdinaryDraftChanges: Bool {
        !changedFieldIDs.isEmpty || !changedSamplePages.isEmpty || !changedImageFieldIDs.isEmpty
            || !changedSeriesPages.isEmpty || !clearedMixedFieldIDs.isEmpty || !changedToolCells.isEmpty
            || !planTimeWindowEdits.isEmpty || sourceState != baseline?.sourceState
    }
    var geometryTopologyIdentity: String { (modelAssetID ?? "") + "|" + (sourceRevision ?? "") }
    private var projectDraftIdentity: String {
        let xml = (provider as? BackendModelProvider)?.project?.editorXML ?? ""
        return SHA256.hash(data: Data(xml.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    var geometryMeshIdentity: String {
        let topology = geometryTopology?.topologyStateForParentSave ?? ""
        let topologyHash = SHA256.hash(data: Data(topology.utf8)).map { String(format: "%02x", $0) }.joined()
        return geometryTopologyIdentity + "|" + projectDraftIdentity + "|" + topologyHash
    }
    var geometryCulvertIdentity: String { geometryTopologyIdentity + "|" + projectDraftIdentity }
    func currentPlanPrecomputeContext() -> PlanPrecomputeContext? {
        guard !isBusy else { return nil }
        return currentPlanComputeContext()
    }
    func currentPlanComputeContext() -> PlanPrecomputeContext? {
        guard loaded, let asset, asset.section == .plans, let sourceRevision,
              (!isWriteLocked || planCompute?.isRunning == true),
              !isSaving, !isPerforming, !hasPendingGeometryEdit,
              !loadingSelection, !isRefreshingContext, !contextRefreshPending,
              !hasIncompleteEditorInput else { return nil }
        let backend = provider as? BackendModelProvider
        let identity = [id.uuidString, String(loadRevision), String(editRevision),
            String(contextRefreshRevision), asset.id, sourceRevision, sourceState ?? "",
            backend?.project?.url?.path ?? "", backend?.project?.editorXML ?? ""]
        guard let bytes = try? JSONEncoder().encode(identity) else { return nil }
        let token = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return .init(id: token, asset: asset,
            edits: .init(fields: sourceDraftFields, rows: [:], images: [:],
                sourceRevision: sourceRevision, sourceState: sourceState,
                planTimeWindowEdits: planTimeWindowEdits, tableSelections: currentTableSelections, changedCells: currentChangedCells))
    }
    func isCurrentPlanPrecomputeContext(_ id: String) -> Bool {
        currentPlanPrecomputeContext()?.id == id
    }
    var associatedPlanPrecomputeDraftIdentity: String {
        [numericCalculatorIdentity, String(editRevision), String(contextRefreshRevision),
         String(hasUnsavedEditorChanges), String(isBusy), String(loadingSelection),
         String(isRefreshingContext), String(contextRefreshPending),
         String(hasIncompleteEditorInput)].joined(separator: "|")
    }
    func captureAssociatedPlanPrecomputeDraft() throws -> PlanPrecomputeAssociatedEditorCapture {
        guard loaded, let asset,
              asset.section == .geometries || asset.section == .boundaryConditions,
              hasUnsavedEditorChanges, !isBusy, !loadingSelection,
              !isRefreshingContext, !contextRefreshPending,
              !hasIncompleteEditorInput, sourceRevision != nil,
              geometryTopology?.canBeginParentSave != false,
              geometryMesh?.canBeginParentSave != false,
              geometryCulvert?.canBeginParentSave != false else {
            throw ProjectFileError.invalid("Complete the associated model edit before checking the Plan.")
        }
        var edits = gridEdits
        edits.geometryTopologyState = geometryTopology?.topologyStateForParentSave
        edits.geometryMeshState = geometryMesh?.geometryMeshStateForParentSave
        edits.geometryCulvertState = geometryCulvert?.geometryCulvertStateForParentSave
        return .init(editorID: id, contextID: associatedPlanPrecomputeDraftIdentity,
            asset: asset, edits: edits)
    }
    func isCurrentPlanComputeContext(_ id: String) -> Bool {
        currentPlanComputeContext()?.id == id
    }
    func ensureGeometryTopologyLoaded() async {
        guard let asset, asset.section == .geometries, loaded else { return }
        await geometryTopology?.ensureLoaded(asset: asset, sourceRevision: sourceRevision)
    }
    func ensureGeometryMeshLoaded() async {
        guard let asset, asset.section == .geometries, loaded else { return }
        await geometryMesh?.ensureLoaded(asset: asset, sourceRevision: sourceRevision,
            topologyDraftState: geometryTopology?.topologyStateForParentSave)
    }
    func requestGeometryProjectContextRefresh() {
        guard let asset, asset.section == .geometries, loaded, !isBusy else { return }
        let revision = loadRevision
        geometryProjectContextGeneration += 1
        let generation = geometryProjectContextGeneration
        isPerforming = true
        geometryProjectContextTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if revision == self.loadRevision, generation == self.geometryProjectContextGeneration {
                    self.geometryProjectContextTask = nil
                    self.isPerforming = false
                }
            }
            await self.geometryMesh?.ensureLoaded(asset: asset, sourceRevision: self.sourceRevision,
                topologyDraftState: self.geometryTopology?.topologyStateForParentSave)
            guard revision == self.loadRevision, generation == self.geometryProjectContextGeneration,
                  !Task.isCancelled else { return }
            await self.geometryCulvert?.ensureLoaded(asset: asset, sourceRevision: self.sourceRevision)
        }
    }
    func ensureGeometryCulvertLoaded() async {
        guard let asset, asset.section == .geometries, loaded else { return }
        await geometryCulvert?.ensureLoaded(asset: asset, sourceRevision: sourceRevision)
    }
    func ensureLoaded(_ asset: ProjectAsset?, kind: ModelEditorKind) async {
        guard !hasCoreLayerReferenceConflict else { return }
        if loaded, self.asset == asset { return }
        await load(asset, kind: kind)
    }
    func load(_ asset: ProjectAsset?, kind: ModelEditorKind) async {
        guard planCompute?.isRunning != true else { return }
        if resultPlanSettings?.isBusy == true {
            error = L10n.text("Wait for the embedded Result Plan operation to finish before changing the Result.")
            return
        }
        if resultPlanSettings?.hasUnsavedChanges == true {
            error = L10n.text("Save or discard the pending Result Plan changes before reloading the Result.")
            return
        }
        guard geometryMesh?.hasUnsavedDiagnosticsPreferences != true,
              geometryMesh?.isSavingDiagnosticsPreferences != true else {
            error = L10n.text("Save or discard the mesh diagnostics settings before changing the geometry.")
            return
        }
        guard geometryCulvert?.hasActiveSketch != true else {
            error = L10n.text("Finish or cancel the active culvert map preview before changing the geometry.")
            return
        }
        let abandonedTerrainAsset = self.asset
        let activeTerrainAttempt = terrainInputImportAttempt
        let abandonedTerrainToken = terrainInputImportDraftToken ?? terrainInputImportCleanupToken ?? activeTerrainAttempt?.request.draftToken
        if let activeTerrainAttempt {
            scheduleAbandonedTerrainInputImport(activeTerrainAttempt)
        } else if let abandonedTerrainAsset, let abandonedTerrainToken {
            scheduleTerrainInputDraftCleanup(asset: abandonedTerrainAsset, token: abandonedTerrainToken, reportFailure: false)
        }
        invalidateGeometryChildren()
        resultInspector?.invalidate()
        resultPlanSettings?.discard()
        resultPlanSettings?.invalidateOwner()
        planResults?.invalidate()
        planCompute?.invalidate()
        invalidateProjectContextRefresh()
        displayUnitSelections = [:]
        dateTimeInputDrafts = [:]
        unitNumberInputDrafts = [:]
        invalidateSelection()
        loadRevision += 1; let revision = loadRevision; self.asset = asset
        sourceRevision = nil; sourceState = nil; readOnlyFieldIDs = []
        terrainInputImportDraftToken = nil; terrainInputImportCleanupWarning = nil; terrainInputImportCleanupToken = nil
        terrainInputImportCleanupBatchToken = nil; terrainInputImportCleanupAfterSave = false
        terrainInputImportAttempt = nil; terrainInputImportStatus = nil
        isTerrainInputImportRunning = false; isTerrainInputImportCancelling = false
        error = nil
        fieldGroups = [:]; availableOperations = []; diagnosticHistory = []; seriesPresentations = [:]; spatialPresentations = [:]; changedSeriesPages = []
        changedFieldIDs = []; changedSamplePages = []; changedImageFieldIDs = []; clearedMixedFieldIDs = []; patchDisplayFieldIDs = []; changedToolCells = [:]; editableSamplePages = []; baseline = nil
        planTimeWindowFieldIDs = nil; planTimeWindowEdits = []; protectedPlanTimeWindowEventIDs = [:]
        fields = [:]; rows = [:]; samples = [:]; images = [:]; choiceOptions = [:]; fieldTitles = [:]; textSuggestions = [:]; sourceCollections = [:]; tablePresentations = [:]; boundaryLines = nil; selectedBoundaryLineID = nil; selectedBoundaryPayloadIDs = [:]; loaded = false; canEdit = false; modified = false
        guard let asset, let provider else { return }
        do {
            let snapshot = try await provider.load(asset, kind: kind)
            guard revision == loadRevision, !Task.isCancelled else { return }
            try snapshot.validatePresentation()
            install(snapshot)
            coreLayerReferenceConflict = nil
            scheduleProjectContextRefresh()
        } catch { if revision == loadRevision, !Task.isCancelled { self.error = L10n.text(error.localizedDescription) } }
    }
    func set(_ field: String, _ value: String) {
        guard !isWriteLocked, !hasUnitNumberDraftBlockingField(field) else { return }
        if readOnlyFieldIDs.contains(field) || SourceEditorLibrary.shared.field(storageID: field)?.readOnly == true { return }
        let related = Set(fieldGroups.values.filter { $0.contains(field) }.flatMap { $0 }).union([field])
        let definition = SourceEditorLibrary.shared.field(storageID: field)
        let planTimeWindowFieldID = asset?.section == .plans && planTimeWindowFieldIDs?.contains(field) == true ? field : nil
        let mixedField = definition.flatMap { item in item.mixedBy.map { item.scoped($0) } }
        guard mixedField.map({ fields[$0] == "true" }) == true || related.contains(where: { fields[$0] != value }) else { return }
        for id in related { fields[id] = value }
        changedFieldIDs.insert(field); editRevision += 1; modified = true
        if let planTimeWindowFieldID { appendPlanTimeWindowEdit(fieldID: planTimeWindowFieldID, value: value) }
        for (table, records) in rows {
            var updated = records, changed = false
            for index in updated.indices {
                for (column, binding) in updated[index].fieldBindings where related.contains(binding) {
                    updated[index].values[column] = value; changed = true
                    changedToolCells[table, default: []].insert(ToolCell(rowID: updated[index].id, columnID: column))
                }
            }
            if changed { rows[table] = updated }
        }
        if asset?.section == .plans, definition?.id == "ViewModel_SelectedPlan_TimeWindowMode" {
            requestProjectContextRefresh()
        }
    }

    private func sourcePropertyValidationRequest(for field: SourceEditorField,
                                                 text: String? = nil) -> SourcePropertyValidationRequest? {
        guard let validationSource = field.errorValidationSource,
              let propertyName = field.errorValidationPropertyName,
              let asset, let sourceRevision, let provider = provider as? BackendModelProvider,
              loaded, canEdit, !isSaving, !isPerforming, !isBusy, !loadingSelection,
              !isWriteLocked, !hasIncompleteEditorInput,
              !field.readOnly, field.isReadOnly != true,
              !readOnlyFieldIDs.contains(field.storageID),
              ModelEditorKind.allCases.contains(where: { $0.section == asset.section }) else { return nil }

        let tableID: String
        switch validationSource {
        case "LeveeModPropertiesDetailEditor":
            guard asset.section == .terrains,
                  field.scope.hasSuffix("/LeveeModPropertiesDetailEditor") || field.scope == "LeveeModPropertiesDetailEditor" else { return nil }
            tableID = "LeveeModPropertiesEditor/PropertySets"
        case "ConceptualMeshControlPointEditor":
            guard asset.section == .geometries,
                  field.scope.hasSuffix("/ConceptualMeshControlPointEditor") || field.scope == "ConceptualMeshControlPointEditor" else { return nil }
            tableID = "Regions"
        default: return nil
        }
        guard let selectedRowIDs = currentTableSelections[tableID], !selectedRowIDs.isEmpty,
              Set(selectedRowIDs).count == selectedRowIDs.count else { return nil }

        let value = text ?? fields[field.storageID, default: ""]
        var validationFields = sourceDraftFields
        validationFields[field.storageID] = value
        let edits = EditorEdits(fields: validationFields, rows: [:], images: [:], samples: [:],
            sourceRevision: sourceRevision, sourceState: sourceState,
            planTimeWindowEdits: planTimeWindowEdits,
            geometryTopologyState: asset.section == .geometries ? geometryTopology?.topologyStateForParentSave : nil,
            geometryMeshState: asset.section == .geometries ? geometryMesh?.geometryMeshStateForParentSave : nil,
            geometryCulvertState: asset.section == .geometries ? geometryCulvert?.geometryCulvertStateForParentSave : nil,
            tableSelections: currentTableSelections, changedCells: [:])
        guard let model = try? provider.saveRequest(asset, changes: edits) else { return nil }
        let sourceStateFingerprint = BackendSourcePropertyValidationProvider.fingerprint(model.sourceState ?? "")
        guard let parentDraftIdentity = try? BackendSourcePropertyValidationProvider.fingerprint(model) else { return nil }
        let sortedRowIDs = selectedRowIDs.sorted()
        let requestIdentity = [id.uuidString.lowercased(), String(loadRevision), String(editRevision),
            String(selectionRevision), validationSource, field.storageID, propertyName, value,
            sourceStateFingerprint, parentDraftIdentity, sortedRowIDs.joined(separator: "\u{1f}")]
            .joined(separator: "\u{0}")
        let requestID = BackendSourcePropertyValidationProvider.fingerprint(requestIdentity)
        return SourcePropertyValidationRequest(model: model, requestID: requestID,
            editorID: id.uuidString.lowercased(), loadRevision: loadRevision,
            editRevision: editRevision, selectionRevision: selectionRevision,
            validationSource: validationSource, fieldID: field.storageID,
            propertyName: propertyName, text: value, selectedRowIDs: sortedRowIDs,
            sourceStateFingerprint: sourceStateFingerprint, parentDraftIdentity: parentDraftIdentity)
    }

    func sourcePropertyValidationIdentity(for field: SourceEditorField) -> String? {
        sourcePropertyValidationRequest(for: field)?.requestID
    }

    func validateSourceProperty(_ field: SourceEditorField,
                                expectedIdentity: String) async -> [SharedVisualValidationMessage]? {
        guard let backend = provider as? BackendModelProvider,
              let request = sourcePropertyValidationRequest(for: field),
              request.requestID == expectedIdentity else { return nil }
        do {
            let messages = try await BackendSourcePropertyValidationProvider(client: backend.client).validate(request)
            guard !Task.isCancelled,
                  sourcePropertyValidationRequest(for: field)?.requestID == expectedIdentity else { return nil }
            return messages
        } catch {
            guard !Task.isCancelled,
                  sourcePropertyValidationRequest(for: field)?.requestID == expectedIdentity else { return nil }
            return [.init(id: field.storageID + ":request", text: L10n.text(error.localizedDescription), level: .error)]
        }
    }

    func geometryRegionInputState(for field: SourceEditorField) -> (value: String, isMixed: Bool)? {
        guard field.scope.hasSuffix("/ConceptualMeshControlPointEditor") || field.scope == "ConceptualMeshControlPointEditor",
              let propertyName = Self.geometryRegionProperty(for: field.id),
              let rowIDs = currentTableSelections["Regions"], !rowIDs.isEmpty else { return nil }
        guard let topology = geometryTopology,
              let sourceState = topology.regionInputText(rowIDs: rowIDs, fieldID: propertyName) else { return nil }
        if topology.isWritingRegionInputs {
            return (fields[field.storageID] ?? sourceState.value, false)
        }
        return sourceState
    }

    func canContinueGeometryRegionInput(_ field: SourceEditorField) -> Bool {
        guard field.errorValidationSource == "ConceptualMeshControlPointEditor",
              field.scope.hasSuffix("/ConceptualMeshControlPointEditor") || field.scope == "ConceptualMeshControlPointEditor",
              Self.geometryRegionProperty(for: field.id) != nil,
              !field.readOnly, field.isReadOnly != true, !readOnlyFieldIDs.contains(field.storageID),
              let asset, asset.section == .geometries,
              let topology = geometryTopology, topology.isWritingRegionInputs,
              canEdit, !loadingSelection, !isWriteLocked, !isSaving, !isPerforming,
              !isTerrainInputImportRunning, planCompute?.isRunning != true,
              geometryMesh?.isEditing != true, geometryMesh?.isSavingDiagnosticsPreferences != true,
              geometryCulvert?.isEditing != true, geometryCulvert?.hasActiveSketch != true,
              resultPlanSettings?.isBusy != true else { return false }
        return true
    }

    func setGeometryRegionInput(_ field: SourceEditorField, value: String) {
        guard field.scope.hasSuffix("/ConceptualMeshControlPointEditor") || field.scope == "ConceptualMeshControlPointEditor",
              let propertyName = Self.geometryRegionProperty(for: field.id),
              let rowIDs = currentTableSelections["Regions"], !rowIDs.isEmpty,
              !field.readOnly, field.isReadOnly != true, !readOnlyFieldIDs.contains(field.storageID),
              let asset, asset.section == .geometries, canEdit,
              (!isBusy || canContinueGeometryRegionInput(field)), !loadingSelection,
              !isWriteLocked, !isSaving, !isPerforming,
              let topology = geometryTopology else { return }
        let capturedLoadRevision = loadRevision
        let capturedSelectionRevision = selectionRevision
        let capturedAssetID = asset.id
        let capturedEditRevision = editRevision + 1
        fields[field.storageID] = value
        if let mixedBy = field.mixedBy { fields[field.scoped(mixedBy)] = "false" }
        editRevision = capturedEditRevision

        let complete: @MainActor (Bool) -> Void = { [weak self] didApply in
            guard let self else { return }
            guard self.loadRevision == capturedLoadRevision, self.asset?.id == capturedAssetID,
                  self.selectionRevision == capturedSelectionRevision else { return }
            guard !didApply, self.editRevision == capturedEditRevision,
                  self.fields[field.storageID] == value,
                  let current = topology.regionInputText(rowIDs: rowIDs, fieldID: propertyName) else { return }
            self.fields[field.storageID] = current.value
            if let mixedBy = field.mixedBy { self.fields[field.scoped(mixedBy)] = String(current.isMixed) }
        }
        if !topology.enqueueRegionInput(rowIDs: rowIDs, fieldID: propertyName,
                                        value: value, completion: complete) {
            complete(false)
        }
    }

    func forceSetGeometryRegionPatchType(_ field: SourceEditorField, value: String) {
        guard field.forceSetCommand == "forceSetPatchType",
              field.scope.hasSuffix("/ConceptualMeshControlPointEditor") || field.scope == "ConceptualMeshControlPointEditor",
              ["Quad", "TrianglePaver", "Cartesian", "OneD", "Empty"].contains(value),
              let rowIDs = currentTableSelections["Regions"], !rowIDs.isEmpty,
              !field.readOnly, field.isReadOnly != true, !readOnlyFieldIDs.contains(field.storageID),
              let asset, asset.section == .geometries, canEdit, !isBusy, !loadingSelection,
              !isWriteLocked, !isSaving, !isPerforming,
              let topology = geometryTopology else { return }
        let capturedLoadRevision = loadRevision
        let capturedSelectionRevision = selectionRevision
        let capturedAssetID = asset.id
        let capturedEditRevision = editRevision + 1
        fields[field.storageID] = value
        if let mixedBy = field.mixedBy { fields[field.scoped(mixedBy)] = "false" }
        editRevision = capturedEditRevision

        Task { @MainActor [weak self] in
            let didApply = await topology.forceSetPatchType(rowIDs: rowIDs, patchType: value)
            guard let self, self.loadRevision == capturedLoadRevision,
                  self.asset?.id == capturedAssetID, self.selectionRevision == capturedSelectionRevision,
                  !didApply, self.editRevision == capturedEditRevision,
                  self.fields[field.storageID] == value else { return }
            let currentRows = topology.selectedRows(for: "region").filter { rowIDs.contains($0.id) }
            let currentValues = currentRows.compactMap { $0.values["PatchType"] }
            if currentValues.count == rowIDs.count, let first = currentValues.first {
                self.fields[field.storageID] = first
                if let mixedBy = field.mixedBy {
                    self.fields[field.scoped(mixedBy)] = String(currentValues.dropFirst().contains { $0 != first })
                }
            }
        }
    }

    func resetGeometryRegionInput(_ field: SourceEditorField) {
        guard let command = field.clearCommand, command.hasPrefix("forceReset"),
              field.scope.hasSuffix("/ConceptualMeshControlPointEditor") || field.scope == "ConceptualMeshControlPointEditor",
              let propertyName = Self.geometryRegionProperty(for: field.id),
              let rowIDs = currentTableSelections["Regions"], rowIDs.count > 1,
              !field.readOnly, field.isReadOnly != true, !readOnlyFieldIDs.contains(field.storageID),
              let asset, asset.section == .geometries, canEdit, !isBusy, !loadingSelection,
              !isWriteLocked, !isSaving, !isPerforming,
              let topology = geometryTopology else { return }
        let capturedLoadRevision = loadRevision
        let capturedSelectionRevision = selectionRevision
        let capturedAssetID = asset.id
        let capturedEditRevision = editRevision + 1
        editRevision = capturedEditRevision
        Task { @MainActor [weak self] in
            let didReset = await topology.resetRegionField(rowIDs: rowIDs, fieldID: propertyName)
            guard let self, self.loadRevision == capturedLoadRevision,
                  self.asset?.id == capturedAssetID, self.selectionRevision == capturedSelectionRevision,
                  self.editRevision == capturedEditRevision else { return }
            if didReset {
                self.fields[field.storageID] = ""
                if let mixedBy = field.mixedBy { self.fields[field.scoped(mixedBy)] = "false" }
            } else if let current = topology.regionInputText(rowIDs: rowIDs, fieldID: propertyName) {
                self.fields[field.storageID] = current.value
                if let mixedBy = field.mixedBy { self.fields[field.scoped(mixedBy)] = String(current.isMixed) }
            }
        }
    }

    private static func geometryRegionProperty(for sourceFieldID: String) -> String? {
        switch sourceFieldID {
        case "ConstantSizeString": "ConstantSize"
        case "SecondaryConstantSizeString": "SecondaryConstantSize"
        case "RotationDegreesString": "RotationDegrees"
        case "BiasInternalString": "BiasInternal"
        case "TinResolutionString": "TinResolution"
        case "SizeToleranceString": "SizeTolerance"
        default: nil
        }
    }
    private func appendPlanTimeWindowEdit(fieldID: String, value: String) {
        let edit = PlanTimeWindowEdit(fieldID: fieldID, value: value)
        if let last = planTimeWindowEdits.last,
           protectedPlanTimeWindowEventIDs[last.id, default: 0] == 0, last.fieldID == fieldID {
            planTimeWindowEdits[planTimeWindowEdits.count - 1] = edit
        } else {
            planTimeWindowEdits.append(edit)
        }
    }
    private func protectPlanTimeWindowPrefix(_ edits: [PlanTimeWindowEdit]) {
        for edit in edits { protectedPlanTimeWindowEventIDs[edit.id, default: 0] += 1 }
    }
    private func releasePlanTimeWindowPrefix(_ edits: [PlanTimeWindowEdit]) {
        for edit in edits {
            let count = protectedPlanTimeWindowEventIDs[edit.id, default: 0]
            if count <= 1 { protectedPlanTimeWindowEventIDs.removeValue(forKey: edit.id) }
            else { protectedPlanTimeWindowEventIDs[edit.id] = count - 1 }
        }
    }
    private func acknowledgePlanTimeWindowPrefix(_ edits: [PlanTimeWindowEdit]) {
        guard !edits.isEmpty,
              planTimeWindowEdits.prefix(edits.count).map(\.id) == edits.map(\.id) else { return }
        planTimeWindowEdits.removeFirst(edits.count)
    }
    func clearMixedFlag(_ field: String?) { guard !isWriteLocked else { return }; if let field { fields[field] = "false"; clearedMixedFieldIDs.insert(field) } }
    func addImage(_ field: String, image: ImageAttachment) { guard !isWriteLocked else { return }; images[field, default: []].append(image); changedImageFieldIDs.insert(field); editRevision += 1; modified = true }
    func removeImage(_ field: String, id: String) { guard !isWriteLocked else { return }; images[field]?.removeAll { $0.id == id }; changedImageFieldIDs.insert(field); editRevision += 1; modified = true }
    func setCell(table: String, rowID: String, column: String, value: String) {
        guard !isWriteLocked, !hasUnitNumberDraftBlockingCell(tableID: table, rowID: rowID, columnID: column) else { return }
        if column != "Value", SourceEditorLibrary.shared.field(storageID: table)?.kind == "classificationMapping" { return }
        if let presentation = tablePresentations[table] {
            guard let definition = presentation.columns.first(where: { $0.id == column }), definition.readOnly != true else { return }
        }
        guard canEdit, var records = rows[table], let index = records.firstIndex(where: { $0.id == rowID }) else { return }
        if let field = records[index].fieldBindings[column] { set(field, value); return }
        guard records[index].values[column] != value else { return }
        records[index].values[column] = value; rows[table] = records
        changedToolCells[table, default: []].insert(ToolCell(rowID: rowID, columnID: column))
        editRevision += 1; modified = true
    }
    func canEditSamples(_ page: String) -> Bool { canEdit && !isBusy && editableSamplePages.contains(page) }
    func canEditSampleAxis(_ page: String, xAxis: Bool) -> Bool {
        guard canEditSamples(page) else { return false }
        guard let presentation = seriesPresentations[page] else { return true }
        return xAxis ? presentation.canEditX : presentation.canEditY
    }
    func setSample(page: String, id: String, x: Double? = nil, y: Double? = nil, datasetID: String? = nil) {
        guard canEditSamples(page), x?.isFinite != false, y?.isInfinite != true,
              x == nil || canEditSampleAxis(page, xAxis: true), y == nil || canEditSampleAxis(page, xAxis: false),
              var values = samples[page], let index = values.firstIndex(where: { $0.id == id && (datasetID == nil || $0.datasetKey == datasetID) }) else { return }
        let unchangedX = x == nil || x == values[index].x
        let unchangedY = y == nil || y == values[index].y || y?.isNaN == true && values[index].y.isNaN
        guard !unchangedX || !unchangedY else { return }
        if let x { values[index].x = x }; if let y { values[index].y = y }
        samples[page] = values; changedSamplePages.insert(page); editRevision += 1; modified = true
    }
    @discardableResult
    func editSeries(pageID: String, operation: SeriesEditOperation) async -> Bool {
        guard !hasIncompleteEditorInput, let asset, let provider, loaded, canEdit, !isBusy, !loadingSelection,
              let presentation = seriesPresentations[pageID], presentation.operations.contains(operation) else { return false }
        let modelRevision = loadRevision, draftRevision = editRevision
        let edits = EditorEdits(fields: sourceDraftFields, rows: rows, images: images,
            samples: samples.filter { editableSamplePages.contains($0.key) && (changedSamplePages.contains($0.key) || $0.key == pageID) }, sourceRevision: sourceRevision, sourceState: sourceState,
            planTimeWindowEdits: planTimeWindowEdits, tableSelections: currentTableSelections, changedCells: currentChangedCells)
        isPerforming = true; isEditingSourceDraft = true; error = nil
        defer { isPerforming = false; isEditingSourceDraft = false }
        do {
            let result = try await provider.editSeries(asset, request: .init(pageID: pageID, operation: operation, edits: edits))
            guard modelRevision == loadRevision, asset == self.asset, draftRevision == editRevision else { return false }
            try Task.checkCancellation()
            // Clearing a source series legitimately produces missing (NaN) values.
            // Infinite data, duplicate identities and a different table scope are
            // invalid responses, not a reason to replace another payload's draft.
            if let values = result.samples {
                guard Set(values.map { SeriesPlotPoint.ID(dataset: $0.datasetKey, sample: $0.id) }).count == values.count,
                      values.allSatisfy({ !$0.id.isEmpty && $0.x.isFinite && !$0.y.isInfinite }) else {
                    throw ProjectFileError.invalid("The series response contains invalid samples.")
                }
            }
            if let rows = result.rows {
                guard presentation.tableID != nil, Set(rows.map(\.id)).count == rows.count,
                      rows.allSatisfy({ !$0.id.isEmpty }) else { throw ProjectFileError.invalid("The series response contains invalid table rows.") }
            }
            if let updated = result.presentation, updated.tableID != presentation.tableID {
                throw ProjectFileError.invalid("The series response targets a different table.")
            }
            try (result.presentation ?? presentation).chart?.validate(samples: result.samples ?? samples[pageID] ?? [])
            try (result.presentation ?? presentation).valueUnits?.validate()
            if let table = result.table, Set(table.columns.map(\.id)).count != table.columns.count {
                throw ProjectFileError.invalid("The series response contains duplicate columns.")
            }
            let additionalIDs = Set([presentation.stationTableID].compactMap { $0 })
            guard Set(result.additionalRows.keys).isSubset(of: additionalIDs), Set(result.additionalTables.keys).isSubset(of: additionalIDs),
                  result.additionalRows.values.allSatisfy({ values in Set(values.map(\.id)).count == values.count && values.allSatisfy { !$0.id.isEmpty } }) else {
                throw ProjectFileError.invalid("The series response targets a different station table.")
            }
            if let values = result.fields {
                for (key, value) in values {
                    fields[key] = value
                }
            }
            if operation == .refresh {
                if let values = result.samples { samples[pageID] = values }
                if let tableID = presentation.tableID, let values = result.rows { rows[tableID] = values }
                if let updated = result.presentation { seriesPresentations[pageID] = updated }
                if let tableID = presentation.tableID, let table = result.table { tablePresentations[tableID] = table }
                rows.merge(result.additionalRows) { _, latest in latest }; tablePresentations.merge(result.additionalTables) { _, latest in latest }
                sourceState = result.sourceState ?? sourceState
                return true
            }
            guard result.changed else { return true }
            guard result.samples != nil || result.rows != nil || result.presentation != nil || result.table != nil else {
                throw ProjectFileError.invalid("The series response did not include the changed data.")
            }
            if let values = result.samples {
                samples[pageID] = values
                // Table-backed plots are derived views. Only the canonical
                // source rows may be submitted as edits for those pages.
                if editableSamplePages.contains(pageID) { changedSamplePages.insert(pageID) }
            }
            if let tableID = presentation.tableID {
                if let values = result.rows { rows[tableID] = values }
                if let table = result.table { tablePresentations[tableID] = table }
            }
            if let updated = result.presentation { seriesPresentations[pageID] = updated }
            sourceState = result.sourceState ?? sourceState
            rows.merge(result.additionalRows) { _, latest in latest }; tablePresentations.merge(result.additionalTables) { _, latest in latest }
            changedSeriesPages.insert(pageID); editRevision += 1; modified = true
            return true
        } catch {
            if modelRevision == loadRevision, !Task.isCancelled, !(error is CancellationError) {
                self.error = L10n.text(error.localizedDescription)
            }
            return false
        }
    }
    @discardableResult
    func editPatch(scope: String, operation: PatchEditOperation) async -> Bool {
        guard !hasIncompleteEditorInput, let asset, let provider, loaded, canEdit, !isBusy, !loadingSelection,
              let detail = tablePresentations[GeometryMeshBindings.regions]?.selection?.detail,
              detail.scope == scope, let presentation = detail.patch, presentation.permits(operation) else { return false }
        let modelRevision = loadRevision, draftRevision = editRevision, selectedRevision = selectionRevision
        let edits = EditorEdits(fields: sourceDraftFields, rows: rows, images: images,
            samples: samples.filter { changedSamplePages.contains($0.key) }, sourceRevision: sourceRevision, sourceState: sourceState,
            planTimeWindowEdits: planTimeWindowEdits, tableSelections: currentTableSelections, changedCells: currentChangedCells)
        isPerforming = true; isEditingSourceDraft = true; error = nil
        defer { isPerforming = false; isEditingSourceDraft = false }
        do {
            let result = try await provider.editPatch(asset, request: .init(scope: scope, operation: operation, edits: edits))
            guard modelRevision == loadRevision, asset == self.asset, draftRevision == editRevision, selectedRevision == selectionRevision else { return false }
            try Task.checkCancellation()
            guard Set(result.fields.keys).isSubset(of: presentation.editableFieldIDs),
                  Set(result.displayFields.keys).isSubset(of: presentation.displayFieldIDs),
                  result.fields.keys.allSatisfy({ SourceEditorLibrary.shared.field(storageID: $0)?.readOnly != true }),
                  !result.changed || !result.fields.isEmpty else {
                throw ProjectFileError.invalid("The patch response does not match the source editing scope.")
            }
            if result.changed {
                for (field, value) in result.fields where fields[field] != value { set(field, value) }
            } else if !result.fields.isEmpty {
                throw ProjectFileError.invalid("The patch response changed fields without declaring a model edit.")
            }
            for (field, value) in result.displayFields { fields[field] = value; patchDisplayFieldIDs.insert(field) }
            return true
        } catch {
            if modelRevision == loadRevision, !Task.isCancelled { self.error = L10n.text(error.localizedDescription) }
            return false
        }
    }
    func startDraft(_ snapshot: EditorSnapshot? = nil) {
        guard planCompute?.isRunning != true, geometryCulvert?.hasActiveSketch != true,
              geometryMesh?.hasUnsavedDiagnosticsPreferences != true,
              geometryMesh?.isSavingDiagnosticsPreferences != true,
              resultPlanSettings?.isBusy != true else { return }
        let abandonedTerrainAsset = asset
        let activeTerrainAttempt = terrainInputImportAttempt
        let abandonedTerrainToken = terrainInputImportDraftToken ?? terrainInputImportCleanupToken ?? activeTerrainAttempt?.request.draftToken
        if let activeTerrainAttempt {
            scheduleAbandonedTerrainInputImport(activeTerrainAttempt)
        } else if let abandonedTerrainAsset, let abandonedTerrainToken {
            scheduleTerrainInputDraftCleanup(asset: abandonedTerrainAsset, token: abandonedTerrainToken, reportFailure: false)
        }
        invalidateGeometryChildren()
        resultInspector?.invalidate()
        resultPlanSettings?.discard()
        resultPlanSettings?.invalidateOwner()
        planResults?.invalidate()
        planCompute?.invalidate()
        invalidateSelection()
        dateTimeInputDrafts = [:]
        unitNumberInputDrafts = [:]
        sourceRevision = nil; sourceState = nil; readOnlyFieldIDs = []
        coreLayerReferenceConflict = nil
        terrainInputImportDraftToken = nil; terrainInputImportCleanupWarning = nil; terrainInputImportCleanupToken = nil
        terrainInputImportCleanupBatchToken = nil; terrainInputImportCleanupAfterSave = false
        terrainInputImportAttempt = nil; terrainInputImportStatus = nil
        isTerrainInputImportRunning = false; isTerrainInputImportCancelling = false
        fieldGroups = [:]; availableOperations = []; diagnosticHistory = []; seriesPresentations = [:]; spatialPresentations = [:]; changedSeriesPages = []
        fields = [:]; rows = [:]; samples = [:]; images = [:]; choiceOptions = [:]; fieldTitles = [:]; textSuggestions = [:]; sourceCollections = [:]; tablePresentations = [:]; boundaryLines = nil; selectedBoundaryLineID = nil; selectedBoundaryPayloadIDs = [:]; baseline = nil
        changedFieldIDs = []; changedSamplePages = []; changedImageFieldIDs = []; clearedMixedFieldIDs = []; patchDisplayFieldIDs = []; changedToolCells = [:]; editableSamplePages = []
        canEdit = true; loaded = true; modified = false
        if let snapshot { install(snapshot) }
    }
    func invalidateForProjectReplacement() {
        guard planCompute?.isRunning != true, geometryCulvert?.hasActiveSketch != true,
              geometryMesh?.hasUnsavedDiagnosticsPreferences != true,
              geometryMesh?.isSavingDiagnosticsPreferences != true,
              resultPlanSettings?.isBusy != true else { return }
        invalidateProjectContextRefresh()
        loadRevision += 1
        asset = nil
        startDraft()
        loaded = false; canEdit = false; error = nil
    }

    func markCoreLayerReferenceConflict(_ message: String) {
        guard !message.isEmpty else { return }
        coreLayerReferenceConflict = L10n.text(message)
    }
    func clearCoreLayerReferenceConflictAfterExplicitDiscard() {
        coreLayerReferenceConflict = nil
    }
    // Refresh source metadata/options without overwriting unsaved tool inputs.
    func mergeToolPresentation(_ snapshot: EditorSnapshot, overwriteRows: Bool = false, sourceWins: Set<String> = []) {
        changedFieldIDs.subtract(sourceWins)
        let edits = fields.filter { changedFieldIDs.contains($0.key) || clearedMixedFieldIDs.contains($0.key) || patchDisplayFieldIDs.contains($0.key) }
        fields = snapshot.fields.merging(edits) { _, edit in edit }
        if overwriteRows { changedToolCells = [:] }
        var mergedRows = snapshot.rows
        for (table, changes) in changedToolCells {
            let existing = Dictionary((rows[table] ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let readonlyColumns = Set((snapshot.tablePresentations[table]?.columns ?? []).filter { $0.readOnly == true }.map(\.id))
            changedToolCells[table] = changes.filter { !readonlyColumns.contains($0.columnID) }
            mergedRows[table] = mergedRows[table]?.map { row in
                var merged = row
                for cell in changes where cell.rowID == row.id && !readonlyColumns.contains(cell.columnID) {
                    if let edit = existing[row.id]?.values[cell.columnID] { merged.values[cell.columnID] = edit }
                }
                return merged
            }
        }
        rows = mergedRows
        samples = snapshot.samples
        choiceOptions = snapshot.choiceOptions; fieldTitles = snapshot.fieldTitles; textSuggestions = snapshot.textSuggestions
        sourceCollections = snapshot.sourceCollections; tablePresentations = snapshot.tablePresentations
        seriesPresentations = snapshot.seriesPresentations; spatialPresentations = snapshot.spatialPresentations
        editableSamplePages = snapshot.editableSamplePages; fieldGroups = snapshot.fieldGroups
        canEdit = snapshot.canEdit; loaded = true
    }
    func resetToolRows() { rows = [:]; changedToolCells = [:] }
    var selectedBoundaryLine: BoundaryLinePresentation? { boundaryLines?.lines.first { $0.id == selectedBoundaryLineID } }
    var selectedBoundaryPayload: BoundaryPayloadPresentation? {
        guard let line = selectedBoundaryLine else { return nil }
        return line.payloads.first { $0.id == selectedBoundaryPayloadIDs[line.id] }
    }
    func boundaryLineName(_ line: BoundaryLinePresentation) -> String {
        line.nameField.flatMap { fields[$0.storageID] } ?? line.name
    }
    func boundaryPayloadName(_ payload: BoundaryPayloadPresentation) -> String {
        payload.field("_Name").flatMap { fields[$0.storageID] } ?? payload.name
    }
    func boundaryPayloadEnabled(_ payload: BoundaryPayloadPresentation) -> Bool {
        payload.field("_IsEnabled").flatMap { fields[$0.storageID] }.map { $0.lowercased() == "true" } ?? payload.isEnabled
    }
    func selectBoundaryLine(_ id: String?) {
        guard !isBusy, id == nil || boundaryLines?.lines.contains(where: { $0.id == id }) == true else { return }
        selectedBoundaryLineID = id
    }
    func selectBoundaryPayload(_ id: String?, lineID: String) {
        guard !isBusy, let line = boundaryLines?.lines.first(where: { $0.id == lineID }),
              id == nil || line.payloads.contains(where: { $0.id == id && $0.isHydraulic }) else { return }
        selectedBoundaryPayloadIDs[lineID] = id
    }
    func renameBoundaryPayload(_ name: String, lineID: String, payloadID: String) {
        guard canEdit, !isBusy,
              let payload = boundaryLines?.lines.first(where: { $0.id == lineID })?.payloads.first(where: { $0.id == payloadID }),
              let field = payload.field("_Name") else { return }
        set(field.storageID, name)
    }
    func setBoundaryPayloadEnabled(_ value: Bool, lineID: String, payloadID: String) {
        guard canEdit, !isBusy, let line = boundaryLines?.lines.first(where: { $0.id == lineID }),
              let payload = line.payloads.first(where: { $0.id == payloadID }), let field = payload.field("_IsEnabled") else { return }
        set(field.storageID, String(value))
        // ObservableBoundaryConditionLine.TryDisableOtherHydraulicPayloads.
        if value, payload.isHydraulic {
            for other in line.payloads where other.id != payload.id && other.isHydraulic && boundaryPayloadEnabled(other) {
                if let field = other.field("_IsEnabled") { set(field.storageID, "false") }
            }
        }
    }
    private func invalidateSelection() {
        selectionRevision += 1; loadingSelection = false
    }
    // Source selection is navigation. It must neither save outstanding edits
    // nor replace another object's draft with a fresh source snapshot.
    private func select(_ action: EditorAction, asset: ProjectAsset, provider: any ModelEditorProvider) async -> Bool {
        let previousFields = baseline?.fields ?? fields
        let previousTables = baseline?.tablePresentations ?? tablePresentations
        let previousSpatial = spatialPresentations
        // Apply the old selected object's edits before the source switches to
        // the newly requested rows. Their content-derived IDs are not aliases.
        let terrainEdits = asset.section == .terrains ? gridEdits : nil
        switch action {
        case .refreshSeries(let pageID):
            guard !hasIncompleteEditorInput, seriesPresentations[pageID]?.chart?.canRefresh == true else { return false }
        case .selectSpatialTime(let layerID, let stepID):
            guard var presentation = spatialPresentations[layerID], presentation.canSelectTime,
                  stepID == nil || presentation.timeSteps.contains(where: { $0.id == stepID }) else { return false }
            if !loadingSelection, presentation.selectedTimeStepID == stepID { return true }
            presentation.selectedTimeStepID = stepID; spatialPresentations[layerID] = presentation
        case .selectSource(let field, let id):
            let items = sourceCollections[field]?.items ?? choiceOptions[field]
            guard let items, id == nil || items.contains(where: { $0.id == id }) else { return false }
            if !loadingSelection, (fields[field] ?? "") == (id ?? ""),
               id == nil || id.flatMap({ sourceCollections[field]?.itemDetails[$0] }) != nil { return true }
            fields[field] = id ?? ""
        case .selectTableRows(let table, let ids):
            guard var tablePresentation = tablePresentations[table], tablePresentation.selection != nil,
                  ids.isSubset(of: Set((rows[table] ?? []).map(\.id))) else { return false }
            if !loadingSelection, tablePresentation.selection?.rowIDs == ids,
               ids.isEmpty || tablePresentation.selection?.detail != nil { return true }
            tablePresentation.selection = .init(rowIDs: ids)
            tablePresentations[table] = tablePresentation
        case .selectPolygonClassifications(let field, let scope, let ids):
            guard let presentation = sourceCollections[field]?.itemDetails.values.first(where: { $0.scope == scope })?.polygons,
                  presentation.canSelect, ids.isSubset(of: Set(presentation.items.map(\.id))) else { return false }
        default: return false
        }
        selectionRevision += 1
        let selectionRequest = selectionRevision, modelRevision = loadRevision
        loadingSelection = true; error = nil
        defer { if selectionRequest == selectionRevision { loadingSelection = false } }
        do {
            let snapshot = try await provider.perform(asset, action: action, edits: terrainEdits ?? gridEdits)
            guard modelRevision == loadRevision, selectionRequest == selectionRevision else { return false }
            try Task.checkCancellation()
            try snapshot.validatePresentation()
            let matches: Bool
            switch action {
            case .refreshSeries(let pageID): matches = snapshot.samples[pageID] != nil && snapshot.seriesPresentations[pageID] != nil
            case .selectSpatialTime(let layerID, let stepID): matches = snapshot.spatialPresentations[layerID]?.selectedTimeStepID == stepID && snapshot.spatialPresentations[layerID] != nil
            case .selectSource(let field, let id): matches = (snapshot.fields[field] ?? "") == (id ?? "")
            case .selectTableRows(let table, let ids):
                matches = snapshot.tablePresentations[table]?.selection?.rowIDs == ids
                    || asset.section == .terrains && snapshot.tablePresentations[table]?.requestedSelectionRowIDs == ids
            case .selectPolygonClassifications(let field, let scope, let ids):
                matches = snapshot.sourceCollections[field]?.itemDetails.values.first(where: { $0.scope == scope })?.polygons?.selectedIDs == ids
            default: matches = false
            }
            guard matches else { throw ProjectFileError.invalid("The source did not return properties for the selected objects.") }
            if case .selectSpatialTime(let layerID, _) = action, var grid = snapshot.spatialPresentations[layerID], grid.gridData != nil {
                // A frame is navigation only. Preserve both the current point
                // draft and its distinct discard baseline, including identities.
                grid.pointData = spatialPresentations[layerID]?.pointData
                spatialPresentations[layerID] = grid
                var savedGrid = grid; savedGrid.pointData = baseline?.spatialPresentations[layerID]?.pointData
                baseline?.spatialPresentations[layerID] = savedGrid
            } else if case .selectTableRows = action, asset.section == .terrains {
                // The reply is the current terrain draft with newly selected
                // property rows. It must not become the discard baseline for
                // structural additions, imported rasters or edited values.
                guard snapshot.sourceRevision == sourceRevision, snapshot.sourceState != nil else {
                    throw ProjectFileError.invalid("The source revision changed during a draft operation.")
                }
                let originalBaseline = baseline
                acknowledgeTerrainDraftCellsAndDetails()
                mergeSelection(snapshot)
                baseline = originalBaseline
            } else { mergeSelection(snapshot) }
            return true
        } catch {
            if modelRevision == loadRevision, selectionRequest == selectionRevision {
                switch action {
                case .selectSpatialTime(let layerID, _): spatialPresentations[layerID] = previousSpatial[layerID]
                case .selectSource(let field, _): fields[field] = previousFields[field]
                case .selectTableRows(let table, _): tablePresentations[table] = previousTables[table]
                default: break
                }
                if !Task.isCancelled { self.error = L10n.text(error.localizedDescription) }
            }
        }
        return false
    }
    private func acknowledgeTerrainDraftCellsAndDetails() {
        // These edits are now in the returned opaque channel/levee draft.
        // Resending their old content-derived row/scope IDs would either fail
        // or address a different generation. General model fields stay dirty.
        changedToolCells = [:]
        changedFieldIDs = changedFieldIDs.filter { !$0.hasPrefix("TerrainSelection/") }
        clearedMixedFieldIDs = clearedMixedFieldIDs.filter { !$0.hasPrefix("TerrainSelection/") }
        patchDisplayFieldIDs = patchDisplayFieldIDs.filter { !$0.hasPrefix("TerrainSelection/") }
    }
    private func mergeSelection(_ snapshot: EditorSnapshot) {
        let edits = fields.filter { changedFieldIDs.contains($0.key) || clearedMixedFieldIDs.contains($0.key) || patchDisplayFieldIDs.contains($0.key) }
        let editedSamples = samples.filter { changedSamplePages.contains($0.key) }
        let editedImages = images.filter { changedImageFieldIDs.contains($0.key) }
        let existingRows = rows
        let editedSeries = seriesPresentations.filter { changedSeriesPages.contains($0.key) }
        let editedTableIDs = Set(editedSeries.values.compactMap(\.tableID))
        let editedTables = tablePresentations.filter { editedTableIDs.contains($0.key) }
        let source = Self.accumulatingSelection(snapshot, baseline: baseline)
        baseline = source; sourceState = source.sourceState; readOnlyFieldIDs = source.readOnlyFieldIDs
        fields = source.fields.merging(edits) { _, edit in edit }
        rows = source.rows
        for (table, cells) in changedToolCells {
            let existing = Dictionary((existingRows[table] ?? []).map { ($0.id, $0.values) }, uniquingKeysWith: { first, _ in first })
            let readonly = Set((source.tablePresentations[table]?.columns ?? []).filter { $0.readOnly == true }.map(\.id))
            changedToolCells[table] = cells.filter { !readonly.contains($0.columnID) }
            rows[table] = rows[table]?.map { row in
                var result = row
                for cell in cells where cell.rowID == row.id && !readonly.contains(cell.columnID) {
                    if let edit = existing[row.id]?[cell.columnID] { result.values[cell.columnID] = edit }
                }
                return result
            }
        }
        samples = source.samples.merging(editedSamples) { _, edit in edit }
        images = source.images.merging(editedImages) { _, edit in edit }
        choiceOptions = source.choiceOptions; fieldTitles = source.fieldTitles; textSuggestions = source.textSuggestions
        sourceCollections = source.sourceCollections; tablePresentations = source.tablePresentations
        editableSamplePages = source.editableSamplePages
        seriesPresentations = source.seriesPresentations.merging(editedSeries) { _, edit in edit }
        spatialPresentations = source.spatialPresentations
        for tableID in editedTableIDs { rows[tableID] = existingRows[tableID] }
        tablePresentations.merge(editedTables) { _, edit in edit }
        fieldGroups = source.fieldGroups; availableOperations = source.availableOperations; diagnosticHistory = source.diagnosticHistory
        canEdit = source.canEdit
    }
    private static func accumulatingSelection(_ incoming: EditorSnapshot, baseline: EditorSnapshot?) -> EditorSnapshot {
        guard let baseline else { return incoming }
        var collections = baseline.sourceCollections
        for (key, var collection) in incoming.sourceCollections {
            let itemIDs = Set(collection.items.map(\.id))
            collection.itemDetails = (collections[key]?.itemDetails ?? [:]).merging(collection.itemDetails) { _, latest in latest }
                .filter { itemIDs.contains($0.key) }
            collections[key] = collection
        }
        return EditorSnapshot(
            fields: baseline.fields.merging(incoming.fields) { _, latest in latest },
            rows: baseline.rows.merging(incoming.rows) { _, latest in latest },
            samples: baseline.samples.merging(incoming.samples) { _, latest in latest },
            canEdit: incoming.canEdit,
            images: baseline.images.merging(incoming.images) { _, latest in latest },
            editableSamplePages: baseline.editableSamplePages.union(incoming.editableSamplePages),
            choiceOptions: baseline.choiceOptions.merging(incoming.choiceOptions) { _, latest in latest },
            fieldTitles: baseline.fieldTitles.merging(incoming.fieldTitles) { _, latest in latest },
            textSuggestions: baseline.textSuggestions.merging(incoming.textSuggestions) { _, latest in latest },
            sourceCollections: collections,
            tablePresentations: baseline.tablePresentations.merging(incoming.tablePresentations) { _, latest in latest },
            boundaryLines: incoming.boundaryLines ?? baseline.boundaryLines,
            sourceRevision: incoming.sourceRevision ?? baseline.sourceRevision,
            fieldGroups: baseline.fieldGroups.merging(incoming.fieldGroups) { _, latest in latest },
            availableOperations: incoming.availableOperations,
            diagnosticHistory: incoming.diagnosticHistory.isEmpty ? baseline.diagnosticHistory : incoming.diagnosticHistory,
            seriesPresentations: baseline.seriesPresentations.merging(incoming.seriesPresentations) { _, latest in latest },
            spatialPresentations: baseline.spatialPresentations.merging(incoming.spatialPresentations) { _, latest in latest },
            sourceState: incoming.sourceState ?? baseline.sourceState, readOnlyFieldIDs: baseline.readOnlyFieldIDs.union(incoming.readOnlyFieldIDs),
            planTimeWindowFieldIDs: incoming.planTimeWindowFieldIDs ?? baseline.planTimeWindowFieldIDs)
    }
    @discardableResult
    func perform(_ action: EditorAction) async -> Bool {
        guard coreLayerReferenceConflict == nil else {
            error = coreLayerReferenceConflict
            return false
        }
        if case .compute = action {
            guard !isWriteLocked, let compute = planCompute, !compute.isRunning,
                  let context = currentPlanComputeContext(),
                  let beginPlanCompute, let endPlanCompute, let didComputePlan else { return false }
            error = nil
            let result = await compute.run(context: context,
                isCurrent: { [weak self] in self?.isCurrentPlanComputeContext($0) == true },
                begin: beginPlanCompute, end: endPlanCompute, completed: didComputePlan)
            if let message = compute.errorMessage { error = L10n.text(message) }
            return result?.state == "completed"
        }
        if case .selectSource(let field, let id) = action, field == ClassificationEditorContract.sourceField || isTerrainSource(field) {
            guard loaded, !isBusy, !loadingSelection, let collection = sourceCollections[field], id == nil || collection.items.contains(where: { $0.id == id }) else { return false }
            if isTerrainSource(field) {
                let wasModified = modified
                guard await editBoundary(action) else { return false }
                modified = wasModified
            } else {
                fields[field] = id ?? ""
            }
            // Every input detail is present. Navigation updates only this field
            // in the saved baseline, retaining structural draft/discard state.
            let savedSelection = baseline?.sourceCollections[field]?.items.contains(where: { $0.id == id }) == true ? id ?? "" : ""
            let navigation = EditorSnapshot(fields: [field: savedSelection], rows: [:], samples: [:], canEdit: canEdit, images: [:], availableOperations: availableOperations)
            baseline = Self.accumulatingSelection(navigation, baseline: baseline)
            return true
        }
        if case .selectPolygonClassifications(let field, let scope, let ids) = action, field == ClassificationEditorContract.sourceField {
            guard loaded, !isBusy, var collection = sourceCollections[field], let item = collection.itemDetails.first(where: { $0.value.scope == scope }), let polygons = item.value.polygons,
                  ids.isSubset(of: Set(polygons.items.map(\.id))) else { return false }
            var detail = item.value; detail.polygons = .init(items: polygons.items, selectedIDs: ids, canSelect: true)
            collection.itemDetails[item.key] = detail; sourceCollections[field] = collection
            if var saved = baseline?.sourceCollections[field], var savedDetail = saved.itemDetails[item.key], let savedPolygons = savedDetail.polygons {
                savedDetail.polygons = .init(items: savedPolygons.items, selectedIDs: ids.intersection(Set(savedPolygons.items.map(\.id))), canSelect: true)
                saved.itemDetails[item.key] = savedDetail; baseline?.sourceCollections[field] = saved
            }
            return true
        }
        switch action {
        case .addTerrainInput: return await editBoundary(action)
        case .addRow, .copyRows, .removeRows:
            if asset?.section == .terrains { return await editBoundary(action) }
        case .editClassificationGeometry: return await editBoundary(action)
        case .reorderSource(let field, _, _) where field == ClassificationEditorContract.sourceField || isTerrainSource(field): return await editBoundary(action)
        case .removeSource(let field, _) where field == ClassificationEditorContract.sourceField || isTerrainSource(field): return await editBoundary(action)
        case .createBoundaryPayload, .removeBoundaryPayload, .editSpatial, .setDefaultNValues, .refreshManning: return await editBoundary(action)
        default: break
        }
        guard let asset, let provider, loaded, !isBusy else { return false }
        switch action {
        case .setDefaultNValues: guard canEdit, availableOperations.contains(.setDefaultNValues) else { return false }
        case .selectSource, .selectTableRows, .selectPolygonClassifications, .selectSpatialTime, .refreshSeries:
            return await select(action, asset: asset, provider: provider)
        default: break
        }
        guard !loadingSelection else { return false }
        switch action {
        case .reorderSource(let field, let from, let to):
            guard canEdit, let collection = sourceCollections[field], collection.canReorder,
                  collection.items.indices.contains(from), collection.items.indices.contains(to), from != to else { return false }
        case .importSource(let field, let files):
            guard canEdit, let collection = sourceCollections[field], collection.canImport, !files.isEmpty,
                  files.allSatisfy(\.isFileURL), collection.multipleImports || files.count == 1 else { return false }
        case .removeSource(let field, let id): guard canEdit, sourceCollections[field]?.canRemove(id) == true else { return false }
        case .addRow(let table): guard canEdit, tablePresentations[table]?.canAddRows == true else { return false }
        case .copyRows(let table, let ids): guard canEdit, !ids.isEmpty, ids.isSubset(of: Set((rows[table] ?? []).map(\.id))), tablePresentations[table]?.canCopyRows == true else { return false }
        case .removeRows(let table, let ids): guard canEdit, !ids.isEmpty, ids.isSubset(of: Set((rows[table] ?? []).map(\.id))), tablePresentations[table]?.canDeleteRows == true else { return false }
        case .createBoundaryPayload(let lineID, _): guard canEdit, boundaryLines?.lines.first(where: { $0.id == lineID })?.newPayload != nil else { return false }
        case .removeBoundaryPayload(let lineID, let payloadID): guard canEdit, boundaryLines?.lines.first(where: { $0.id == lineID })?.payloads.first(where: { $0.id == payloadID })?.canDelete == true else { return false }
        default: break
        }
        isPerforming = true
        defer { isPerforming = false }
        if hasUnsavedEditorChanges, !(await saveLoadedModel()) { return false }
        invalidateSelection()
        let revision = loadRevision
        do {
            let snapshot = try await provider.perform(asset, action: action)
            guard revision == loadRevision else { return false }
            try snapshot.validatePresentation()
            install(snapshot)
            return true
        }
        catch { if revision == loadRevision { self.error = L10n.text(error.localizedDescription) } }
        return false
    }
    private func editBoundary(_ action: EditorAction) async -> Bool {
        let isTerrainNavigation: Bool
        if case .selectSource(let field, _) = action { isTerrainNavigation = isTerrainSource(field) }
        else { isTerrainNavigation = false }
        guard !hasIncompleteEditorInput, let asset, let provider, loaded, canEdit || isTerrainNavigation,
              !isBusy, !loadingSelection else { return false }
        switch action {
        case .selectSource(let field, let id) where isTerrainSource(field):
            guard let collection = sourceCollections[field], id == nil || collection.items.contains(where: { $0.id == id }) else { return false }
        case .addRow(let table) where asset.section == .terrains:
            guard tablePresentations[table]?.canAddRows == true else { return false }
        case .copyRows(let table, let ids) where asset.section == .terrains:
            guard !ids.isEmpty, tablePresentations[table]?.canCopyRows == true,
                  ids.isSubset(of: Set((rows[table] ?? []).map(\.id))) else { return false }
        case .removeRows(let table, let ids) where asset.section == .terrains:
            guard !ids.isEmpty, tablePresentations[table]?.canDeleteRows == true,
                  ids.isSubset(of: Set((rows[table] ?? []).map(\.id))) else { return false }
        case .addTerrainInput:
            guard asset.section == .terrains, sourceCollections[TerrainEditorContract.sourceField] != nil else { return false }
        case .editClassificationGeometry(let mutation):
            guard let tools = sourceCollections[ClassificationEditorContract.sourceField]?.classificationTools else { return false }
            if mutation.operation == "undo", !tools.canUndo { return false }
            if mutation.operation == "redo", !tools.canRedo { return false }
        case .reorderSource(let field, let from, let to) where field == ClassificationEditorContract.sourceField || isTerrainSource(field):
            guard let collection = sourceCollections[field], collection.canReorder, collection.items.indices.contains(from), collection.items.indices.contains(to), from != to else { return false }
        case .removeSource(let field, let id) where field == ClassificationEditorContract.sourceField || isTerrainSource(field):
            guard sourceCollections[field]?.canRemove(id) == true else { return false }
        case .setDefaultNValues:
            guard availableOperations.contains(.setDefaultNValues) else { return false }
        case .refreshManning:
            guard fields["ManningsNEditor/NValueLayer_Mode"] != nil else { return false }
        case .createBoundaryPayload(let lineID, _):
            guard boundaryLines?.lines.first(where: { $0.id == lineID })?.newPayload != nil else { return false }
        case .removeBoundaryPayload(let lineID, let payloadID):
            guard boundaryLines?.lines.first(where: { $0.id == lineID })?.payloads.first(where: { $0.id == payloadID })?.canDelete == true else { return false }
        case .editSpatial(let layerID, let operation, let itemID):
            guard let data = spatialPresentations[layerID]?.pointData else { return false }
            switch operation {
            case "refresh", "addStation": break
            case "removeStation", "addGauge": guard data.stations.contains(where: { $0.id == itemID }) else { return false }
            case "removeGauge": guard data.inputs.contains(where: { $0.id == itemID }) else { return false }
            default: return false
            }
        default: return false
        }
        let loadedRevision = loadRevision, revision = editRevision
        let edits = EditorEdits(fields: sourceDraftFields, rows: rows, images: images,
            samples: samples.filter { changedSamplePages.contains($0.key) }, sourceRevision: sourceRevision, sourceState: sourceState,
            planTimeWindowEdits: planTimeWindowEdits, tableSelections: currentTableSelections, changedCells: currentChangedCells)
        let savedBaseline = baseline, fieldIDs = changedFieldIDs, imageIDs = changedImageFieldIDs, draftImages = images
        let classificationBefore = sourceCollections[ClassificationEditorContract.sourceField]
        let mixedIDs = clearedMixedFieldIDs, displayIDs = patchDisplayFieldIDs, toolCells = changedToolCells
        isPerforming = true; isEditingSourceDraft = true; error = nil
        defer { isPerforming = false; isEditingSourceDraft = false }
        do {
            let snapshot: EditorSnapshot
            switch action {
            case .addRow, .copyRows, .removeRows:
                snapshot = try await provider.editTerrain(asset, action: action, edits: edits)
            case .addTerrainInput: snapshot = try await provider.editTerrain(asset, action: action, edits: edits)
            case .selectSource(let field, _) where isTerrainSource(field):
                snapshot = try await provider.editTerrain(asset, action: action, edits: edits)
            case .reorderSource(let field, _, _) where isTerrainSource(field): snapshot = try await provider.editTerrain(asset, action: action, edits: edits)
            case .removeSource(let field, _) where isTerrainSource(field): snapshot = try await provider.editTerrain(asset, action: action, edits: edits)
            case .editClassificationGeometry: snapshot = try await provider.editClassification(asset, action: action, edits: edits)
            case .reorderSource(let field, _, _) where field == ClassificationEditorContract.sourceField: snapshot = try await provider.editClassification(asset, action: action, edits: edits)
            case .removeSource(let field, _) where field == ClassificationEditorContract.sourceField: snapshot = try await provider.editClassification(asset, action: action, edits: edits)
            case .setDefaultNValues: snapshot = try await provider.editManning(asset, operation: "setNLCD", edits: edits)
            case .refreshManning: snapshot = try await provider.editManning(asset, operation: "refresh", edits: edits)
            default: snapshot = try await provider.editBoundary(asset, action: action, edits: edits)
            }
            guard loadedRevision == loadRevision, asset == self.asset, revision == editRevision else { return false }
            try Task.checkCancellation()
            try snapshot.validatePresentation()
            guard snapshot.sourceRevision == edits.sourceRevision else { throw ProjectFileError.invalid("The source revision changed during a draft operation.") }
            invalidateSelection()
            install(snapshot)
            if let classificationBefore { retainClassificationSelection(from: classificationBefore, action: action) }
            // The source returned a transformed draft, not a saved baseline.
            // Keep original discard state and all independent image edits.
            baseline = savedBaseline
            changedFieldIDs = fieldIDs.intersection(Set(fields.keys))
            changedImageFieldIDs = imageIDs
            images = draftImages
            changedSamplePages = editableSamplePages
            clearedMixedFieldIDs = mixedIDs; patchDisplayFieldIDs = displayIDs; changedToolCells = toolCells
            if asset.section == .terrains { acknowledgeTerrainDraftCellsAndDetails() }
            editRevision += 1; modified = true
            return true
        } catch {
            if loadedRevision == loadRevision, !Task.isCancelled, !(error is CancellationError) {
                self.error = L10n.text(error.localizedDescription)
            }
            return false
        }
    }

    private func install(_ snapshot: EditorSnapshot) {
        // Source transformations can replace a snapshot while another page has
        // incomplete input. Keep that input only when its valid baseline still
        // matches; explicit reload/discard/model replacement clears it first.
        dateTimeInputDrafts = dateTimeInputDrafts.filter {
            snapshot.fields[$0.key, default: ""] == $0.value.sourceValue
        }
        fieldGroups = snapshot.fieldGroups; availableOperations = snapshot.availableOperations; diagnosticHistory = snapshot.diagnosticHistory
        seriesPresentations = snapshot.seriesPresentations; spatialPresentations = snapshot.spatialPresentations; changedSeriesPages = []
        fields = snapshot.fields; rows = snapshot.rows; samples = snapshot.samples; images = snapshot.images
        choiceOptions = snapshot.choiceOptions
        fieldTitles = snapshot.fieldTitles
        textSuggestions = snapshot.textSuggestions
        sourceCollections = snapshot.sourceCollections
        tablePresentations = snapshot.tablePresentations
        boundaryLines = snapshot.boundaryLines
        selectedBoundaryLineID = snapshot.boundaryLines?.selectedLineID
        selectedBoundaryPayloadIDs = Dictionary(uniqueKeysWithValues: (snapshot.boundaryLines?.lines ?? []).compactMap { line in
            (line.selectedPayloadID ?? line.activeHydraulicPayloadID).map { (line.id, $0) }
        })
        baseline = snapshot; sourceRevision = snapshot.sourceRevision; sourceState = snapshot.sourceState; readOnlyFieldIDs = snapshot.readOnlyFieldIDs; editableSamplePages = snapshot.editableSamplePages
        let previousTerrainInputDraftToken = terrainInputImportDraftToken
        terrainInputImportDraftToken = snapshot.terrainInputImportDraftToken
        if let warning = snapshot.terrainInputImportCleanupWarning {
            terrainInputImportCleanupWarning = warning
            terrainInputImportCleanupToken = snapshot.terrainInputImportCleanupToken
            terrainInputImportCleanupBatchToken = nil
            terrainInputImportCleanupAfterSave = true
            error = L10n.text("The model was saved, but temporary terrain import files could not be removed.")
        } else if terrainInputImportCleanupToken == nil {
            terrainInputImportCleanupWarning = nil
            terrainInputImportCleanupBatchToken = nil
            terrainInputImportCleanupAfterSave = false
        } else if isSaving, let previousTerrainInputDraftToken,
                  terrainInputImportCleanupToken == previousTerrainInputDraftToken,
                  snapshot.terrainInputImportDraftToken == nil {
            // A successful save of an accepted import draft removes its whole
            // staging directory. A failed first batch or abandoned draft has
            // no token in sourceState, so an unrelated save cannot acknowledge
            // that cleanup warning.
            terrainInputImportCleanupWarning = nil
            terrainInputImportCleanupToken = nil
            terrainInputImportCleanupBatchToken = nil
            terrainInputImportCleanupAfterSave = false
        }
        changedFieldIDs = []; changedSamplePages = []; changedImageFieldIDs = []; clearedMixedFieldIDs = []; patchDisplayFieldIDs = []; changedToolCells = [:]
        modified = hasGeometryDraftChanges || hasOrdinaryDraftChanges || resultPlanSettings?.hasUnsavedChanges == true
        planTimeWindowFieldIDs = snapshot.planTimeWindowFieldIDs; planTimeWindowEdits = []; protectedPlanTimeWindowEventIDs = [:]
        canEdit = snapshot.canEdit; loaded = true
    }
    // Project associations live in the unsaved project document. Re-read the
    // source getters against that document without saving or acknowledging any
    // model edits. Separate snapshots are essential for a correct Discard.
    func requestProjectContextRefresh() {
        guard asset?.section == .plans, provider?.supportsProjectContextRefresh == true else { return }
        invalidateProjectContextRefresh(keepPending: true)
        contextRefreshPending = true
        scheduleProjectContextRefresh()
    }
    private func invalidateProjectContextRefresh(keepPending: Bool = false) {
        let pending = contextRefreshPending || isRefreshingContext
        contextRefreshRevision += 1
        contextRefreshTask?.cancel(); contextRefreshTask = nil
        isRefreshingContext = false
        contextRefreshPending = keepPending && pending
    }
    private func scheduleProjectContextRefresh() {
        guard contextRefreshPending, loaded, !isBusy, asset?.section == .plans,
              provider?.supportsProjectContextRefresh == true else { return }
        contextRefreshTask?.cancel()
        let revision = contextRefreshRevision
        contextRefreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard let self, revision == self.contextRefreshRevision else { return }
            _ = await self.refreshProjectContext(revision: revision)
        }
    }
    @discardableResult
    func refreshProjectContext() async -> Bool {
        invalidateProjectContextRefresh()
        return await refreshProjectContext(revision: contextRefreshRevision)
    }
    private func refreshProjectContext(revision: Int) async -> Bool {
        guard !hasIncompleteEditorInput, let asset, asset.section == .plans, loaded, !isBusy,
              let provider, provider.supportsProjectContextRefresh else { return false }
        let loadedRevision = loadRevision, editedRevision = editRevision
        let edits = gridEdits
        let capturedPlanTimeWindowEdits = edits.planTimeWindowEdits
        protectPlanTimeWindowPrefix(capturedPlanTimeWindowEdits)
        contextRefreshPending = false
        isRefreshingContext = true
        defer {
            releasePlanTimeWindowPrefix(capturedPlanTimeWindowEdits)
            if revision == contextRefreshRevision { isRefreshingContext = false }
        }
        do {
            let result = try await provider.refreshProjectContext(asset, edits: edits)
            guard revision == contextRefreshRevision, loadedRevision == loadRevision,
                  asset == self.asset, !Task.isCancelled else { return false }
            guard editedRevision == editRevision else {
                requestProjectContextRefresh()
                return false
            }
            guard result.baseline.sourceRevision == sourceRevision, result.draft.sourceRevision == sourceRevision else {
                throw BackendServiceError(code: "sourceChanged", message: "Reload the model before saving.")
            }
            try result.baseline.validatePresentation(); try result.draft.validatePresentation()
            guard let windowFields = result.draft.planTimeWindowFieldIDs,
                  result.baseline.planTimeWindowFieldIDs == windowFields else {
                throw BackendServiceError(code: "invalidInput", message: "The plan refresh did not return its time-window field identities.")
            }
            // Keep the user's exact spelling and every alias while adopting
            // freshly evaluated gates, choices and inherited source values.
            // The window fields are computed from the source setter history,
            // so a stale raw text value must never replace those getters.
            let dirtyIDs = changedFieldIDs.filter { !windowFields.contains($0) }.reduce(into: Set<String>()) { ids, field in
                ids.insert(field)
                ids.formUnion(fieldGroups.values.filter { $0.contains(field) }.flatMap { $0 })
                ids.formUnion(result.draft.fieldGroups.values.filter { $0.contains(field) }.flatMap { $0 })
            }.union(clearedMixedFieldIDs.filter { !windowFields.contains($0) })
            var refreshedFields = result.draft.fields
            for id in dirtyIDs { if let value = fields[id] { refreshedFields[id] = value } }
            baseline = result.baseline
            fieldGroups = result.draft.fieldGroups
            fields = refreshedFields
            planTimeWindowFieldIDs = windowFields
            choiceOptions = result.draft.choiceOptions; fieldTitles = result.draft.fieldTitles; textSuggestions = result.draft.textSuggestions
            sourceCollections = result.draft.sourceCollections; tablePresentations = result.draft.tablePresentations
            readOnlyFieldIDs = result.draft.readOnlyFieldIDs; availableOperations = result.draft.availableOperations
            diagnosticHistory = result.draft.diagnosticHistory; canEdit = result.draft.canEdit
            sourceState = result.draft.sourceState
            acknowledgePlanTimeWindowPrefix(capturedPlanTimeWindowEdits)
            return true
        } catch {
            if revision == contextRefreshRevision, loadedRevision == loadRevision, !Task.isCancelled {
                self.error = L10n.text(error.localizedDescription)
            }
            return false
        }
    }
    @discardableResult
    func save(_ requestedAsset: ProjectAsset?, gridImport: SpatialGridSelection? = nil, classificationImport: [ClassificationImportFile]? = nil,
              cumulusImport: CumulusGridImportSelection? = nil,
              cumulusProgress: (@MainActor (BackendProgressUpdate) -> Void)? = nil) async -> Bool {
        guard geometryMesh?.isSavingDiagnosticsPreferences != true else { return false }
        if resultPlanSettings?.hasUnsavedChanges == true {
            return await saveResultPlanSettings(requestedAsset)
        }
        guard await saveModel(requestedAsset, gridImport: gridImport, classificationImport: classificationImport,
                              cumulusImport: cumulusImport, cumulusProgress: cumulusProgress) else { return false }
        guard let mesh = geometryMesh, mesh.hasUnsavedDiagnosticsPreferences else { return true }
        guard let persistDiagnosticsPreferences, let capture = mesh.beginDiagnosticsPreferencesSave() else {
            error = L10n.text("Save the mesh diagnostics settings before continuing.")
            return false
        }
        do {
            let revision = try await persistDiagnosticsPreferences(capture)
            mesh.acceptDiagnosticsPreferencesSave(capture, newSourceRevision: revision)
            return !mesh.hasUnsavedDiagnosticsPreferences
        } catch {
            mesh.diagnosticsPreferencesSaveFailed(capture, message: error.localizedDescription)
            self.error = L10n.text(error.localizedDescription)
            return false
        }
    }
    private func currentResultPlanSettingsCapture(for requestedAsset: ProjectAsset) -> PlanSettingsResultCapture? {
        guard requestedAsset == asset, requestedAsset.section == .results,
              let sourceRevision, let ownedCapture = resultPlanSettings?.currentOwnerCapture,
              let capture = currentResultPlanSettingsContext?(),
              capture.identity == ownedCapture.identity,
              capture.owner.resultAssetID == requestedAsset.id,
              SourceFilePaths.canonical(URL(fileURLWithPath: capture.owner.resultPath)) == SourceFilePaths.canonical(requestedAsset.url),
              capture.owner.resultRevision.caseInsensitiveCompare(sourceRevision) == .orderedSame,
              let project = (provider as? BackendModelProvider)?.project,
              let projectURL = project.url, let projectRevision = project.sourceRevision,
              SourceFilePaths.canonical(projectURL) == SourceFilePaths.canonical(URL(fileURLWithPath: capture.projectPath)),
              projectRevision.caseInsensitiveCompare(capture.projectRevision) == .orderedSame,
              let inspector = resultInspector?.snapshot,
              SourceFilePaths.canonical(URL(fileURLWithPath: inspector.resultPath)) == SourceFilePaths.canonical(requestedAsset.url),
              inspector.revision.caseInsensitiveCompare(capture.owner.resultRevision) == .orderedSame else { return nil }
        return capture
    }
    private func saveResultPlanSettings(_ requestedAsset: ProjectAsset?) async -> Bool {
        guard !isBusy, !loadingSelection,
              !hasOrdinaryDraftChanges, !hasGeometryDraftChanges,
              geometryMesh?.hasUnsavedDiagnosticsPreferences != true,
              let requestedAsset,
              let child = resultPlanSettings,
              let owner = currentResultPlanSettingsCapture(for: requestedAsset),
              let capture = child.captureDraft(for: owner),
              let provider else {
            error = L10n.text("The selected Result Plan context changed. Reload the Result before saving.")
            return false
        }
        let loadedRevision = loadRevision
        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            let receipt = try await child.save(capture)
            // The embedded Plan save is already committed. Rebase the child
            // immediately so a later refresh failure cannot make it retry the
            // stale Result revision or imply rollback.
            child.accept(capture, receipt: receipt)
            guard loadedRevision == loadRevision, requestedAsset == asset else { return false }
            sourceRevision = receipt.revision
            resultInspector?.invalidate()
            guard loadedRevision == loadRevision, requestedAsset == asset else { return !child.hasUnsavedChanges }
            do {
                let refreshed = try await provider.load(requestedAsset, kind: .result)
                guard loadedRevision == loadRevision, requestedAsset == asset else { return !child.hasUnsavedChanges }
                try refreshed.validatePresentation()
                let refreshedPath = refreshed.fields["ResultCatalogSummary/Context_Filename"]
                guard refreshed.sourceRevision?.caseInsensitiveCompare(receipt.revision) == .orderedSame,
                      refreshedPath.map({ SourceFilePaths.canonical(URL(fileURLWithPath: $0)) == SourceFilePaths.canonical(requestedAsset.url) }) == true else {
                    throw BackendServiceError(code: "protocolFailure",
                        message: L10n.text("The saved Result Plan was committed, but the refreshed Result snapshot does not match it."))
                }
                install(refreshed)
                guard let inspector = resultInspector else {
                    throw BackendServiceError(code: "sourceChanged",
                        message: L10n.text("The Result was saved, but its source inspector is unavailable."))
                }
                let projectURL = URL(fileURLWithPath: owner.projectPath)
                await inspector.ensureLoaded(asset: requestedAsset, projectPath: projectURL,
                    projectXML: owner.projectXML,
                    sourceContextRevision: "\(owner.owner.projectSessionID):\(owner.assetsRevision)")
                guard loadedRevision == loadRevision, requestedAsset == asset else { return false }
                guard let inspection = inspector.snapshot,
                      SourceFilePaths.canonical(URL(fileURLWithPath: inspection.resultPath)) == SourceFilePaths.canonical(requestedAsset.url),
                      inspection.revision.caseInsensitiveCompare(receipt.revision) == .orderedSame else {
                    throw BackendServiceError(code: "sourceChanged",
                        message: L10n.format("Result source refresh did not confirm the saved revision: %@",
                            L10n.text(inspector.error ?? "The Result source revision is not current.")))
                }
            } catch {
                guard loadedRevision == loadRevision, requestedAsset == asset else { return false }
                self.error = L10n.format("The embedded Plan settings were saved, but the Result inspector could not be refreshed: %@", L10n.text(error.localizedDescription))
                return false
            }
            return !child.hasUnsavedChanges
        } catch {
            if loadedRevision == loadRevision { self.error = L10n.text(error.localizedDescription) }
            return false
        }
    }
    private func saveModel(_ requestedAsset: ProjectAsset?, gridImport: SpatialGridSelection? = nil, classificationImport: [ClassificationImportFile]? = nil,
                           cumulusImport: CumulusGridImportSelection? = nil,
                           cumulusProgress: (@MainActor (BackendProgressUpdate) -> Void)? = nil) async -> Bool {
        guard coreLayerReferenceConflict == nil else {
            error = coreLayerReferenceConflict
            return false
        }
        guard !hasIncompleteEditorInput else {
            if hasIncompleteDateTimeInput {
                error = L10n.text("Complete or discard the invalid date or time input before saving.")
            } else if hasIncompleteUnitNumberInput {
                error = L10n.text(OriginalUnitNumberInputIssue.blockedBeforeSave)
            } else {
                error = incompleteEditorInputIssue
            }
            return false
        }
        guard terrainInputImportCleanupBatchToken == nil else {
            error = L10n.text("Resolve the unresolved terrain import batch before saving.")
            return false
        }
        guard !hasPendingGeometryEdit else {
            error = L10n.text("Wait for the geometry operation to finish before saving.")
            return false
        }
        guard modified || gridImport != nil || classificationImport != nil || cumulusImport != nil else { return true }
        guard let requestedAsset, requestedAsset == asset, let provider, canEdit, !isWriteLocked, !isSaving, !loadingSelection, !isEditingSourceDraft else { return false }
        let topology = requestedAsset.section == .geometries ? geometryTopology : nil
        let mesh = requestedAsset.section == .geometries ? geometryMesh : nil
        let culverts = requestedAsset.section == .geometries ? geometryCulvert : nil
        guard topology?.canBeginParentSave != false, mesh?.canBeginParentSave != false,
              culverts?.canBeginParentSave != false else {
            error = L10n.text("Wait for the geometry operation to finish before saving.")
            return false
        }
        do {
            for id in changedFieldIDs where SourceEditorLibrary.shared.field(storageID: id)?.kind == "recipe" {
                _ = try RecipeDocument.parse(fields[id] ?? "", commands: RecipeLibrary.commands)
            }
        } catch { self.error = L10n.text(error.localizedDescription); return false }
        let revision = editRevision, loadedRevision = loadRevision
        let classificationBefore = sourceCollections[ClassificationEditorContract.sourceField]
        let topologyCapture = topology?.beginParentSave()
        let meshCapture = mesh?.beginParentSave()
        let culvertCapture = culverts?.beginParentSave()
        var topologyAcknowledged = false, meshAcknowledged = false, culvertsAcknowledged = false
        defer {
            if let topologyCapture, !topologyAcknowledged { topology?.parentSaveFailed(topologyCapture) }
            if let meshCapture, !meshAcknowledged { mesh?.parentSaveFailed(meshCapture) }
            if let culvertCapture, !culvertsAcknowledged { culverts?.parentSaveFailed(culvertCapture) }
        }
        let changes = EditorEdits(fields: sourceDraftFields, rows: rows, images: images, samples: samples.filter { changedSamplePages.contains($0.key) }, sourceRevision: sourceRevision, sourceState: sourceState, planTimeWindowEdits: planTimeWindowEdits,
            geometryTopologyState: topologyCapture?.draftState,
            geometryMeshState: meshCapture?.draftState,
            geometryCulvertState: culvertCapture?.draftState, tableSelections: currentTableSelections, changedCells: currentChangedCells)
        let capturedPlanTimeWindowEdits = changes.planTimeWindowEdits
        // Retain the same exact session reference capture that BackendModelProvider
        // serializes before its first suspension. A late save must not rebase a
        // newer registry entry for the same external HDF path.
        let capturedCoreLayerContext = (provider as? BackendModelProvider)?.captureCoreLayerContext()
        protectPlanTimeWindowPrefix(capturedPlanTimeWindowEdits)
        var savedBaseline = EditorSnapshot(fields: fields, rows: rows, samples: samples, canEdit: canEdit, images: images, editableSamplePages: editableSamplePages, choiceOptions: choiceOptions, fieldTitles: fieldTitles, textSuggestions: textSuggestions, sourceCollections: sourceCollections, tablePresentations: tablePresentations, boundaryLines: boundaryLines?.selecting(lineID: selectedBoundaryLineID, payloadIDs: selectedBoundaryPayloadIDs), sourceRevision: sourceRevision, fieldGroups: fieldGroups, availableOperations: availableOperations, diagnosticHistory: diagnosticHistory, seriesPresentations: seriesPresentations, spatialPresentations: spatialPresentations, sourceState: sourceState, readOnlyFieldIDs: readOnlyFieldIDs, planTimeWindowFieldIDs: planTimeWindowFieldIDs,
            terrainInputImportDraftToken: terrainInputImportDraftToken, terrainInputImportCleanupWarning: terrainInputImportCleanupWarning, terrainInputImportCleanupToken: terrainInputImportCleanupToken)
        invalidateProjectContextRefresh(keepPending: true)
        isSaving = true; error = nil
        defer {
            releasePlanTimeWindowPrefix(capturedPlanTimeWindowEdits)
            isSaving = false
        }
        do {
            let result: EditorSaveResult
            if let classificationImport { result = try await provider.importClassification(requestedAsset, edits: changes, files: classificationImport) }
            else if let gridImport { result = try await provider.importGrid(requestedAsset, edits: changes, selection: gridImport) }
            else if let cumulusImport {
                result = try await provider.importCumulusGrid(requestedAsset, edits: changes,
                    selection: cumulusImport, progress: { cumulusProgress?($0) })
            }
            else { result = try await provider.saveModel(requestedAsset, changes: changes) }
            guard loadedRevision == loadRevision, requestedAsset == asset else { return false }
            if asset?.section == .plans, (changes.sourceState != nil || !capturedPlanTimeWindowEdits.isEmpty), result.snapshot?.planTimeWindowFieldIDs == nil {
                throw ProjectFileError.invalid("The plan save did not return its canonical time-window state.")
            }
            sourceRevision = result.sourceRevision ?? result.snapshot?.sourceRevision ?? sourceRevision
            savedBaseline = result.snapshot ?? savedBaseline
            if let classificationBefore, classificationImport == nil { Self.rebaseClassificationSelection(in: &savedBaseline, from: classificationBefore) }
            savedBaseline.sourceRevision = sourceRevision
            baseline = savedBaseline
            sourceState = savedBaseline.sourceState
            readOnlyFieldIDs = savedBaseline.readOnlyFieldIDs
            planTimeWindowFieldIDs = savedBaseline.planTimeWindowFieldIDs
            acknowledgePlanTimeWindowPrefix(capturedPlanTimeWindowEdits)
            if let topologyCapture {
                await topology?.acknowledgeParentSave(topologyCapture, newSourceRevision: sourceRevision)
                topologyAcknowledged = true
            }
            if let meshCapture {
                await mesh?.acknowledgeParentSave(meshCapture, newSourceRevision: sourceRevision)
                meshAcknowledged = true
            }
            if let culvertCapture {
                await culverts?.acknowledgeParentSave(culvertCapture, newSourceRevision: sourceRevision)
                culvertsAcknowledged = true
            }
            guard loadedRevision == loadRevision, requestedAsset == asset else { return false }
            didSave?()
            if let committedSnapshot = result.snapshot {
                didSaveModelSnapshot?(committedSnapshot, capturedCoreLayerContext,
                    capturedCoreLayerContext?.projectRevision)
            }
            // A save acknowledges only the captured edits. Later edits remain
            // dirty even if a provider resumes after the user types again.
            guard revision == editRevision else { return false }
            if result.snapshot != nil {
                let lineID = selectedBoundaryLineID, payloadIDs = selectedBoundaryPayloadIDs
                install(savedBaseline)
                if let lines = boundaryLines?.lines {
                    selectedBoundaryLineID = lines.contains(where: { $0.id == lineID }) ? lineID : boundaryLines?.selectedLineID
                    for (lineID, payloadID) in payloadIDs where lines.first(where: { $0.id == lineID })?.payloads.contains(where: { $0.id == payloadID }) == true {
                        selectedBoundaryPayloadIDs[lineID] = payloadID
                    }
                }
                return true
            }
            modified = false; changedFieldIDs = []; changedSamplePages = []; changedImageFieldIDs = []; clearedMixedFieldIDs = []; patchDisplayFieldIDs = []; changedToolCells = [:]; changedSeriesPages = []
            return true
        }
        catch { if loadedRevision == loadRevision { self.error = L10n.text(error.localizedDescription) }; return false }
    }
    @discardableResult func saveLoadedModel() async -> Bool { await save(asset) }
    func captureBoundaryInitialConditions(projectSessionID: UUID, projectURL: URL, projectRevision: String,
                                          documentXML: String, submittedProjectXML: String,
                                          descriptionDraft: String) throws -> BoundaryInitialConditionsCapture {
        guard loaded, canEdit, !isSaving, !isPerforming, !loadingSelection, !isRefreshingContext,
              !isWriteLocked, !hasIncompleteEditorInput,
              let asset, asset.section == .boundaryConditions, let sourceRevision,
              let backend = provider as? BackendModelProvider,
              let project = backend.project, project.url?.standardizedFileURL == projectURL.standardizedFileURL,
              project.sourceRevision == projectRevision, project.editorXML == documentXML else {
            throw BackendServiceError(code: "sourceChanged",
                message: "Reload the boundary condition and project before attaching initial conditions.")
        }
        guard !submittedProjectXML.isEmpty, !projectRevision.isEmpty else {
            throw BackendServiceError(code: "invalidInput", message: "Save the project before attaching initial conditions.")
        }
        let edits = EditorEdits(fields: sourceDraftFields, rows: rows, images: images,
            samples: samples.filter { changedSamplePages.contains($0.key) },
            sourceRevision: sourceRevision, sourceState: sourceState)
        let base = try backend.saveRequest(asset, changes: edits)
        let model = BackendModelProvider.ModelSaveRequest(
            assetPath: base.assetPath, kind: base.kind, projectPath: projectURL.path,
            revision: base.revision, fields: base.fields, images: base.images,
            projectXml: submittedProjectXML, sourceState: base.sourceState,
            rows: base.rows, samples: base.samples, planTimeWindowEdits: base.planTimeWindowEdits,
            geometryTopologyState: base.geometryTopologyState,
            geometryMeshState: base.geometryMeshState, geometryCulvertState: base.geometryCulvertState,
            coreLayerContext: base.coreLayerContext)
        return BoundaryInitialConditionsCapture(
            id: UUID().uuidString.lowercased(), projectSessionID: projectSessionID,
            editorID: id, loadRevision: loadRevision, editRevision: editRevision,
            asset: asset, projectPath: projectURL.path, projectRevision: projectRevision,
            capturedDocumentXML: documentXML, submittedProjectXML: submittedProjectXML,
            projectXmlFingerprint: Self.boundaryInitialConditionsDigest(Data(submittedProjectXML.utf8)),
            descriptionDraft: descriptionDraft, model: model, editorFields: fields,
            editorRows: rows, editorImages: images, editorSamples: samples, editorSourceState: sourceState)
    }

    func isCurrentBoundaryInitialConditionsCapture(_ capture: BoundaryInitialConditionsCapture,
                                                    projectSessionID: UUID, projectURL: URL,
                                                    projectRevision: String, documentXML: String,
                                                    submittedProjectXML: String) -> Bool {
        guard loaded, canEdit, !isSaving, !isPerforming, !loadingSelection, !isRefreshingContext,
              !isWriteLocked, !hasIncompleteEditorInput,
              capture.editorID == id, capture.projectSessionID == projectSessionID,
              capture.loadRevision == loadRevision, capture.editRevision == editRevision,
              capture.asset == asset, capture.asset.section == .boundaryConditions,
              capture.model.revision == sourceRevision,
              capture.projectRevision == projectRevision,
              capture.projectPath == projectURL.path,
              capture.capturedDocumentXML == documentXML,
              capture.submittedProjectXML == submittedProjectXML,
              capture.projectXmlFingerprint == Self.boundaryInitialConditionsDigest(Data(submittedProjectXML.utf8)),
              let backend = provider as? BackendModelProvider,
              let project = backend.project, project.url?.standardizedFileURL == projectURL.standardizedFileURL,
              project.sourceRevision == projectRevision, project.editorXML == documentXML else { return false }
        return true
    }

    @discardableResult
    func acknowledgeBoundaryInitialConditions(_ capture: BoundaryInitialConditionsCapture,
                                              receipt: BoundaryInitialConditionsReceipt) -> Bool {
        guard capture.editorID == id, capture.asset == asset,
              capture.loadRevision == loadRevision,
              receipt.assetPath == capture.model.assetPath ||
                SourceFilePaths.canonical(URL(fileURLWithPath: receipt.assetPath)) ==
                SourceFilePaths.canonical(URL(fileURLWithPath: capture.model.assetPath)),
              receipt.model.revision != capture.model.revision else { return false }
        // A status recovery may deliver the same committed receipt again. Do
        // not reinstall it over a newer draft that was kept after first ack.
        if sourceRevision == receipt.model.revision { return true }
        guard sourceRevision == capture.model.revision,
              let snapshot = try? receipt.model.editorSnapshot,
              snapshot.sourceRevision == receipt.model.revision else { return false }

        let laterFields = fields.filter { key, value in capture.editorFields[key] != value }
        let currentRows = rows
        let changedTables = Set(capture.editorRows.keys).union(currentRows.keys).filter { tableID in
            !Self.boundaryRowsEqual(currentRows[tableID] ?? [], capture.editorRows[tableID] ?? [])
        }
        let laterImages = images.filter { key, value in
            !Self.boundaryImagesEqual(value, capture.editorImages[key] ?? [])
        }
        let laterSamples = samples.filter { key, value in
            !Self.boundarySamplesEqual(value, capture.editorSamples[key] ?? [])
        }
        let didChangeSourceStateAfterCapture = sourceState != capture.editorSourceState
        let laterSourceState = sourceState

        install(snapshot)
        for (field, value) in laterFields {
            fields[field] = value
            changedFieldIDs.insert(field)
        }
        for tableID in changedTables {
            guard let current = currentRows[tableID] else {
                rows.removeValue(forKey: tableID)
                // The full row dictionary is part of the captured save request;
                // an empty set preserves a table-level edit with no changed cell.
                changedToolCells[tableID] = []
                continue
            }
            rows[tableID] = current
            let submitted = Dictionary(uniqueKeysWithValues: (capture.editorRows[tableID] ?? []).map { ($0.id, $0) })
            var changedCells: Set<ToolCell> = []
            for row in current {
                let changedValues = row.values.filter { column, value in submitted[row.id]?.values[column] != value }
                for column in changedValues.keys {
                    changedCells.insert(ToolCell(rowID: row.id, columnID: column))
                }
            }
            changedToolCells[tableID] = changedCells
        }
        for (field, value) in laterImages {
            images[field] = value
            changedImageFieldIDs.insert(field)
        }
        for (page, value) in laterSamples {
            samples[page] = value
            changedSamplePages.insert(page)
        }
        if didChangeSourceStateAfterCapture { sourceState = laterSourceState }
        modified = !changedFieldIDs.isEmpty || !changedToolCells.isEmpty ||
            !changedImageFieldIDs.isEmpty || !changedSamplePages.isEmpty ||
            !changedSeriesPages.isEmpty || !changedTables.isEmpty || sourceState != snapshot.sourceState
        didSave?()
        didSaveModelSnapshot?(snapshot, capture.model.coreLayerContext, receipt.projectRevision)
        return true
    }

    private static func boundaryInitialConditionsDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }
    private static func boundaryImagesEqual(_ left: [ImageAttachment], _ right: [ImageAttachment]) -> Bool {
        left.count == right.count && zip(left, right).allSatisfy { pair in
            pair.0.id == pair.1.id && pair.0.name == pair.1.name && pair.0.data == pair.1.data
        }
    }
    private static func boundaryRowsEqual(_ left: [EditorRow], _ right: [EditorRow]) -> Bool {
        left.count == right.count && zip(left, right).allSatisfy { pair in
            pair.0.id == pair.1.id && pair.0.values == pair.1.values && pair.0.fieldBindings == pair.1.fieldBindings
        }
    }
    private static func boundarySamplesEqual(_ left: [ChartSample], _ right: [ChartSample]) -> Bool {
        left.count == right.count && zip(left, right).allSatisfy { pair in
            pair.0.id == pair.1.id && pair.0.x == pair.1.x &&
                (pair.0.y == pair.1.y || pair.0.y.isNaN && pair.1.y.isNaN) &&
                pair.0.series == pair.1.series && pair.0.datasetID == pair.1.datasetID
        }
    }

    private var sourceDraftFields: [String: String] {
        fields.filter { (changedFieldIDs.contains($0.key) || $0.key == ClassificationEditorContract.sourceField || isTerrainSource($0.key)) && !(asset?.section == .plans && planTimeWindowFieldIDs?.contains($0.key) == true) }
    }
    private var gridEdits: EditorEdits {
        .init(fields: sourceDraftFields, rows: rows, images: images,
            samples: samples.filter { changedSamplePages.contains($0.key) }, sourceRevision: sourceRevision, sourceState: sourceState,
            planTimeWindowEdits: planTimeWindowEdits, tableSelections: currentTableSelections, changedCells: currentChangedCells)
    }
    private var currentChangedCells: [String: [EditorChangedCell]] {
        changedToolCells.mapValues { cells in
            cells.sorted { ($0.rowID, $0.columnID) < ($1.rowID, $1.columnID) }
                .map { EditorChangedCell(rowID: $0.rowID, columnID: $0.columnID) }
        }.filter { !$0.value.isEmpty }
    }
    private var currentTableSelections: [String: [String]] {
        tablePresentations.compactMapValues { $0.selection.map { $0.rowIDs.sorted() } }
    }
    func inspectGrid(layerID: String, files: [URL], subdataset: String?, bands: [SpatialGridBand], previewID: String?) async throws -> SpatialGridInspection {
        guard !hasIncompleteEditorInput, let asset, let provider, !isBusy else { throw DataToolError.unavailable }
        let revision = loadRevision, edits = editRevision
        let result = try await provider.inspectGrid(asset, edits: gridEdits, layerID: layerID, files: files, subdataset: subdataset, bands: bands, previewID: previewID)
        guard revision == loadRevision, edits == editRevision, asset == self.asset else { throw CancellationError() }
        try result.preview?.validate()
        return result
    }
    private func retainClassificationSelection(from previous: SourceCollection, action: EditorAction) {
        let field = ClassificationEditorContract.sourceField
        guard var collection = sourceCollections[field] else { return }
        let oldIDs = Set(previous.itemDetails.values.flatMap { $0.polygons?.items.map(\.id) ?? [] })
        var selectAppearing = false, creating = false
        if case .editClassificationGeometry(let mutation) = action {
            creating = ["create", "paste"].contains(mutation.operation)
            selectAppearing = ["create", "paste", "undo", "redo"].contains(mutation.operation)
        }
        for (id, var detail) in collection.itemDetails {
            guard let polygons = detail.polygons else { continue }
            let ids = Set(polygons.items.map(\.id))
            var selected = (previous.itemDetails[id]?.polygons?.selectedIDs ?? []).intersection(ids)
            if creating { selected = ids.subtracting(oldIDs) }
            else if selectAppearing { selected.formUnion(ids.subtracting(oldIDs)) }
            if case .editClassificationGeometry(let mutation) = action, mutation.operation == "replace" { selected.formUnion(Set(mutation.polygonIds ?? []).intersection(ids)) }
            detail.polygons = .init(items: polygons.items, selectedIDs: selected, canSelect: polygons.canSelect)
            collection.itemDetails[id] = detail
        }
        sourceCollections[field] = collection
    }
    private static func rebaseClassificationSelection(in snapshot: inout EditorSnapshot, from previous: SourceCollection) {
        let field = ClassificationEditorContract.sourceField
        guard var collection = snapshot.sourceCollections[field] else { return }
        let oldOrder = Array(previous.items.reversed()), newOrder = Array(collection.items.reversed())
        for index in oldOrder.indices where newOrder.indices.contains(index) {
            guard let old = previous.itemDetails[oldOrder[index].id]?.polygons, var detail = collection.itemDetails[newOrder[index].id], let polygons = detail.polygons else { continue }
            let ordinals = old.items.indices.filter { old.selectedIDs.contains(old.items[$0].id) }
            let selected = Set(ordinals.filter { polygons.items.indices.contains($0) }.map { polygons.items[$0].id })
            detail.polygons = .init(items: polygons.items, selectedIDs: selected, canSelect: polygons.canSelect)
            collection.itemDetails[newOrder[index].id] = detail
        }
        snapshot.sourceCollections[field] = collection
    }
    private func isTerrainSource(_ field: String) -> Bool { field == TerrainEditorContract.sourceField && sourceCollections[field]?.terrainConnected == true }
    var terrainInputImportIdentity: String {
        [id.uuidString, String(loadRevision), asset?.id ?? "", sourceRevision ?? "", String(editRevision),
            fields[TerrainEditorContract.sourceField] ?? "", terrainInputImportDraftToken ?? ""].joined(separator: "|")
    }
    func inspectTerrainInputImport(files: [URL], expectedIdentity: String) async throws -> TerrainInputImportInspection {
        guard expectedIdentity == terrainInputImportIdentity, terrainInputImportCleanupToken == nil, !hasIncompleteEditorInput,
              let asset, let provider, loaded, canEdit, !isBusy, !loadingSelection,
              isTerrainSource(TerrainEditorContract.sourceField),
              sourceCollections[TerrainEditorContract.sourceField]?.canImport == true,
              !files.isEmpty, files.allSatisfy(\.isFileURL) else { throw DataToolError.unavailable }
        let capturedLoad = loadRevision, capturedEdit = editRevision
        let result = try await provider.inspectTerrainInputImport(asset, edits: gridEdits, files: files)
        guard !Task.isCancelled, capturedLoad == loadRevision, capturedEdit == editRevision,
              asset == self.asset, expectedIdentity == terrainInputImportIdentity else { throw CancellationError() }
        try result.validate()
        return result
    }
    @discardableResult
    func appendTerrainInputImport(_ selections: [TerrainInputImportSelection], inspection: TerrainInputImportInspection,
                                  stitchTiles: Bool, expectedIdentity: String) async -> TerrainInputAppendResult? {
        guard expectedIdentity == terrainInputImportIdentity, terrainInputImportCleanupToken == nil, !hasIncompleteEditorInput,
              let asset, let provider, loaded, canEdit, !isBusy, !loadingSelection,
              isTerrainSource(TerrainEditorContract.sourceField),
              sourceCollections[TerrainEditorContract.sourceField]?.canImport == true,
              !selections.isEmpty, Set(selections.map(\.path)).count == selections.count,
              let savedBaseline = baseline else { return nil }
        do { try inspection.validate() }
        catch { self.error = L10n.text(error.localizedDescription); return nil }
        let sourceByPath = Dictionary(uniqueKeysWithValues: inspection.sources.map { ($0.path, $0) })
        guard selections.allSatisfy({ selection in
            guard let source = sourceByPath[selection.path], source.isValid,
                  selection.sourceRevision == source.revision,
                  selection.sourceID == nil || selection.sourceID == source.id,
                  inspection.roundingOptions.contains(selection.rounding),
                  inspection.unitConversionOptions.contains(selection.unitConversion) else { return false }
            if selection.unitConversion == "Custom" { return selection.customScaleFactor?.isFinite == true }
            return selection.customScaleFactor == nil
        }) else {
            error = L10n.text("The terrain import settings no longer match the inspected files.")
            return nil
        }

        let capturedLoad = loadRevision, capturedEdit = editRevision
        let token = terrainInputImportDraftToken ?? Self.newTerrainInputImportToken()
        let batchToken = Self.newTerrainInputImportToken()
        let normalizedSelections = selections.map { selection -> TerrainInputImportSelection in
            var selection = selection
            selection.sourceID = sourceByPath[selection.path]?.id
            return selection
        }
        let edits = gridEdits
        let request: TerrainInputAppendRequest
        do {
            request = try provider.makeTerrainInputAppendRequest(asset, edits: edits, selections: normalizedSelections,
                stitchTiles: stitchTiles && normalizedSelections.count > 1, draftToken: token, batchToken: batchToken)
        } catch {
            self.error = L10n.text(error.localizedDescription)
            return nil
        }
        let attempt = TerrainInputImportAttempt(asset: asset, request: request, expectedIdentity: expectedIdentity,
            loadRevision: capturedLoad, editRevision: capturedEdit, savedBaseline: savedBaseline,
            changedFieldIDs: changedFieldIDs, changedImageFieldIDs: changedImageFieldIDs, images: images,
            changedSamplePages: changedSamplePages, clearedMixedFieldIDs: clearedMixedFieldIDs,
            patchDisplayFieldIDs: patchDisplayFieldIDs, changedToolCells: changedToolCells,
            changedSeriesPages: changedSeriesPages, wasModified: modified, cancelRequested: false)
        terrainInputImportAttempt = attempt
        isTerrainInputImportRunning = true; isEditingSourceDraft = true
        terrainInputImportStatus = .init(state: "Running", result: nil, operations: [])
        error = nil
        isPerforming = true
        defer { isPerforming = false; isEditingSourceDraft = false }
        do {
            let result = try await provider.appendTerrainInputImport(asset, request: request)
            return try acceptTerrainInputAppendResult(result, for: attempt)
        } catch {
            // The append process can finish its staged conversion while the
            // client loses its response. Query with the exact request before
            // surfacing an error or allowing a retry; never delete a batch
            // whose operation results are still unknown.
            do {
                if let result = try await recoverTerrainInputImportAfterLostResponse(attempt) { return result }
                if canRecheckTerrainInputImportStatus { return nil }
                self.error = terrainInputImportStatus?.isNotFound == true
                    ? L10n.text("The terrain import is not registered yet. Check its status again before retrying.")
                    : L10n.text("The terrain import is still running. Check its status before retrying.")
            } catch let statusError {
                if attempt.loadRevision == loadRevision, attempt.asset == self.asset {
                    if isTerrainInputSourceChanged(statusError) {
                        stopTerrainInputImportAfterSourceChanged(attempt)
                    } else {
                        self.error = L10n.text("The terrain import result could not be recovered. Check its status before retrying.")
                    }
                }
            }
            return nil
        }
    }

    @discardableResult
    func refreshTerrainInputImportStatus(expectedIdentity: String) async -> TerrainInputAppendResult? {
        guard let attempt = terrainInputImportAttempt, attempt.expectedIdentity == expectedIdentity,
              attempt.loadRevision == loadRevision, attempt.asset == asset,
              provider != nil, !isPerforming else { return nil }
        isPerforming = true
        defer { isPerforming = false }
        do {
            return try await recoverTerrainInputImportAfterLostResponse(attempt)
        } catch {
            if attempt.loadRevision == loadRevision, attempt.asset == asset {
                if isTerrainInputSourceChanged(error) {
                    stopTerrainInputImportAfterSourceChanged(attempt)
                } else {
                    self.error = L10n.text("The terrain import result could not be recovered. Check its status before retrying.")
                }
            }
            return nil
        }
    }

    @discardableResult
    func cancelTerrainInputImport(expectedIdentity: String, operationID: String? = nil) async -> Bool {
        guard let attempt = terrainInputImportAttempt, attempt.expectedIdentity == expectedIdentity,
              attempt.loadRevision == loadRevision, attempt.asset == asset,
              let provider, !isTerrainInputImportCancelling else { return false }
        var cancellationAttempt = attempt
        cancellationAttempt.cancelRequested = operationID == nil
        terrainInputImportAttempt = cancellationAttempt
        isTerrainInputImportCancelling = true
        defer { isTerrainInputImportCancelling = false }
        do {
            let receipt = try await provider.cancelTerrainInputImport(cancellationAttempt.asset,
                request: cancellationAttempt.request, operationID: operationID)
            guard isCurrentTerrainInputImportAttempt(attempt),
                  ["NotFound", "Queued", "Running", "Completed", "Partial", "Failed", "Cancelled", "CancelledPartial"].contains(receipt.state) else {
                throw ProjectFileError.invalid("The terrain import cancellation response is unsupported.")
            }
            if !receipt.accepted, operationID == nil,
               var current = terrainInputImportAttempt,
               current.request.batchToken == attempt.request.batchToken {
                current.cancelRequested = false
                terrainInputImportAttempt = current
            }
            if !receipt.accepted { error = L10n.text("The terrain import could not be cancelled.") }
            return receipt.accepted
        } catch {
            if isCurrentTerrainInputImportAttempt(attempt) {
                if isTerrainInputSourceChanged(error) {
                    stopTerrainInputImportAfterSourceChanged(attempt)
                } else {
                    self.error = L10n.text(error.localizedDescription)
                }
            }
            return false
        }
    }

    private func updateTerrainInputImportStatus(_ status: TerrainInputImportStatus,
        for attempt: TerrainInputImportAttempt) throws -> TerrainInputAppendResult? {
        try status.validate(draftToken: attempt.request.draftToken, batchToken: attempt.request.batchToken,
            expectedMode: attempt.request.stitchTiles ? "Stitched" : "Individual")
        guard terrainInputImportAttempt?.request.batchToken == attempt.request.batchToken else { return nil }
        terrainInputImportStatus = status
        if status.resultUnavailableCode == "sourceChanged" {
            stopTerrainInputImportAfterSourceChanged(attempt)
            return nil
        }
        if status.state == "Running" {
            if terrainInputImportCleanupToken == attempt.request.draftToken,
               terrainInputImportCleanupBatchToken == attempt.request.batchToken {
                terrainInputImportCleanupToken = nil
                terrainInputImportCleanupWarning = nil
                terrainInputImportCleanupBatchToken = nil
                terrainInputImportCleanupAfterSave = false
            }
            isTerrainInputImportRunning = true
            isTerrainInputImportCancelling = false
        }
        guard let result = status.result else { return nil }
        return try acceptTerrainInputAppendResult(result, for: attempt)
    }

    private func stopTerrainInputImportAfterSourceChanged(_ attempt: TerrainInputImportAttempt) {
        guard isCurrentTerrainInputImportAttempt(attempt) else { return }
        let message = L10n.text("The terrain source changed while this import was running. Review the batch results, clean up the unresolved batch, then reload or discard the model draft before continuing.")
        // Keep the batch-scoped cleanup owner. The backend deliberately retains
        // its journal and staged files when the cached snapshot no longer
        // matches its source dependencies; only explicit cleanup or full
        // draft discard may remove them.
        terrainInputImportCleanupToken = attempt.request.draftToken
        terrainInputImportCleanupBatchToken = attempt.request.batchToken
        terrainInputImportCleanupWarning = message
        terrainInputImportCleanupAfterSave = false
        // Keep the exact request so the user can explicitly check status again
        // after restoring the source files. No automatic polling continues.
        isTerrainInputImportRunning = false
        isTerrainInputImportCancelling = false
        error = message
    }

    private func isTerrainInputSourceChanged(_ error: Error) -> Bool {
        (error as? BackendServiceError)?.code == "sourceChanged"
    }

    private func recoverTerrainInputImportAfterLostResponse(_ attempt: TerrainInputImportAttempt) async throws -> TerrainInputAppendResult? {
        guard let provider, isCurrentTerrainInputImportAttempt(attempt) else { return nil }
        for poll in 0..<3 {
            let status = try await provider.terrainInputImportStatus(attempt.asset, request: attempt.request)
            guard isCurrentTerrainInputImportAttempt(attempt) else { return nil }
            try status.validate(draftToken: attempt.request.draftToken, batchToken: attempt.request.batchToken,
                expectedMode: attempt.request.stitchTiles ? "Stitched" : "Individual")
            if !status.isNotFound { return try updateTerrainInputImportStatus(status, for: attempt) }
            terrainInputImportStatus = status
            if poll < 2 {
                try await Task.sleep(for: .milliseconds(250))
                guard isCurrentTerrainInputImportAttempt(attempt) else { return nil }
            }
        }
        guard let retryAttempt = terrainInputImportAttempt, isCurrentTerrainInputImportAttempt(attempt),
              !retryAttempt.cancelRequested else { return nil }
        isTerrainInputImportRunning = true
        let result = try await provider.appendTerrainInputImport(retryAttempt.asset, request: retryAttempt.request)
        guard isCurrentTerrainInputImportAttempt(attempt) else { return nil }
        return try acceptTerrainInputAppendResult(result, for: retryAttempt)
    }

    private func isCurrentTerrainInputImportAttempt(_ attempt: TerrainInputImportAttempt) -> Bool {
        guard let current = terrainInputImportAttempt else { return false }
        return current.request.batchToken == attempt.request.batchToken &&
            attempt.loadRevision == loadRevision && attempt.asset == asset &&
            attempt.editRevision == editRevision && attempt.expectedIdentity == terrainInputImportIdentity
    }

    private func acceptTerrainInputAppendResult(_ result: TerrainInputAppendResult,
        for attempt: TerrainInputImportAttempt) throws -> TerrainInputAppendResult? {
        try result.validate(expectedDraftToken: attempt.request.draftToken,
            expectedBatchToken: attempt.request.batchToken,
            expectedMode: attempt.request.stitchTiles ? "Stitched" : "Individual")
        guard isCurrentTerrainInputImportAttempt(attempt) else { return nil }
        guard attempt.loadRevision == loadRevision, attempt.editRevision == editRevision,
              attempt.asset == asset, attempt.expectedIdentity == terrainInputImportIdentity else {
            // A stale result may contain successful pending outputs. Do not
            // remove it as though the entire operation failed; its owner token
            // remains scoped to the captured model and can be reconciled by a
            // subsequent load/status recovery.
            isTerrainInputImportRunning = false
            terrainInputImportAttempt = nil
            return nil
        }
        let snapshot = try result.snapshot.editorSnapshot
        try snapshot.validatePresentation()
        guard snapshot.sourceRevision == attempt.request.model.revision,
              snapshot.terrainInputImportDraftToken == attempt.request.draftToken else {
            throw ProjectFileError.invalid("The terrain import response does not match the current editor draft.")
        }
        if terrainInputImportCleanupToken == attempt.request.draftToken,
           terrainInputImportCleanupBatchToken == attempt.request.batchToken {
            terrainInputImportCleanupToken = nil
            terrainInputImportCleanupWarning = nil
            terrainInputImportCleanupBatchToken = nil
            terrainInputImportCleanupAfterSave = false
        }
        invalidateSelection()
        install(snapshot)
        baseline = attempt.savedBaseline
        changedFieldIDs = attempt.changedFieldIDs.intersection(Set(fields.keys))
        changedImageFieldIDs = attempt.changedImageFieldIDs; images = attempt.images
        changedSamplePages = attempt.changedSamplePages.intersection(editableSamplePages)
        changedSeriesPages = attempt.changedSeriesPages
        clearedMixedFieldIDs = attempt.clearedMixedFieldIDs
        patchDisplayFieldIDs = attempt.patchDisplayFieldIDs
        changedToolCells = attempt.changedToolCells
        editRevision += 1
        modified = attempt.wasModified || result.hasStagedOutputs
        error = nil
        terrainInputImportAttempt = nil
        isTerrainInputImportRunning = false
        isTerrainInputImportCancelling = false
        terrainInputImportStatus = .init(state: result.batchStatus, result: result, operations: result.operations)
        return result
    }
    @discardableResult
    func retryTerrainInputImportCleanup() async -> Bool {
        guard let token = terrainInputImportCleanupToken, let asset, let provider, loaded, !isBusy else { return false }
        let batchToken = terrainInputImportCleanupBatchToken
        let capturedLoad = loadRevision, capturedAsset = asset
        isPerforming = true
        defer { isPerforming = false }
        do {
            let removed: Bool
            if let batchToken {
                removed = try await provider.discardTerrainInputImportBatch(capturedAsset, draftToken: token, batchToken: batchToken)
            } else {
                removed = try await provider.discardTerrainInputImport(capturedAsset, draftToken: token)
            }
            guard capturedLoad == loadRevision, capturedAsset == self.asset,
                  terrainInputImportCleanupToken == token, terrainInputImportCleanupBatchToken == batchToken else { return false }
            guard removed else { throw ProjectFileError.invalid("The temporary terrain import files could not be removed.") }
            terrainInputImportCleanupToken = nil; terrainInputImportCleanupWarning = nil
            terrainInputImportCleanupBatchToken = nil; terrainInputImportCleanupAfterSave = false; error = nil
            if let batchToken, terrainInputImportAttempt?.request.batchToken == batchToken {
                terrainInputImportAttempt = nil
                isTerrainInputImportRunning = false
                isTerrainInputImportCancelling = false
                terrainInputImportStatus = nil
            }
            return true
        } catch {
            if capturedLoad == loadRevision { self.error = L10n.text(error.localizedDescription) }
            return false
        }
    }
    private static func newTerrainInputImportToken() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
    private func scheduleAbandonedTerrainInputImport(_ attempt: TerrainInputImportAttempt) {
        guard let provider else { return }
        Task {
            _ = try? await provider.cancelTerrainInputImport(attempt.asset, request: attempt.request, operationID: nil)
            for _ in 0..<40 {
                if let status = try? await provider.terrainInputImportStatus(attempt.asset, request: attempt.request),
                   (try? status.validate(draftToken: attempt.request.draftToken, batchToken: attempt.request.batchToken,
                       expectedMode: attempt.request.stitchTiles ? "Stitched" : "Individual")) != nil,
                   status.isTerminal {
                    _ = try? await provider.discardTerrainInputImport(attempt.asset, draftToken: attempt.request.draftToken)
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }
    private func scheduleFailedTerrainInputBatchCleanup(asset: ProjectAsset, draftToken: String,
        batchToken: String, isNewDraft: Bool, reportFailure: Bool) {
        if isNewDraft {
            scheduleTerrainInputDraftCleanup(asset: asset, token: draftToken, reportFailure: reportFailure)
            return
        }
        guard let provider else { return }
        Task {
            do {
                let removed = try await provider.discardTerrainInputImportBatch(asset, draftToken: draftToken, batchToken: batchToken)
                guard removed else { throw ProjectFileError.invalid("The temporary terrain import batch could not be removed.") }
            } catch {
                guard reportFailure, self.asset == asset else { return }
                terrainInputImportCleanupWarning = error.localizedDescription
                terrainInputImportCleanupToken = draftToken
                terrainInputImportCleanupBatchToken = batchToken
                terrainInputImportCleanupAfterSave = false
                self.error = L10n.text("The temporary terrain import files could not be removed.")
            }
        }
    }
    var terrainMapIdentity: String { classificationMapIdentity + "|" + (fields[TerrainEditorContract.sourceField] ?? "") }
    func terrainTopology(inputID: String, operation: TerrainTopologyOperation,
                         featureIDs: [String] = [], points: [TerrainMapCoordinate] = [],
                         mapCellSize: Double? = nil) async throws -> TerrainTopologyData {
        let key = numericCalculatorIdentity + "|" + inputID
        if operation != .load && operation != .sortProfile,
           terrainTopologyDraftIdentities[key]?.editRevision != editRevision {
            _ = try await terrainTopology(inputID: inputID,
                command: .init(operation: .load), expectedDraftIdentity: nil)
        }
        return try await terrainTopology(inputID: inputID,
            command: .init(operation: operation, featureIDs: featureIDs, points: points, mapCellSize: mapCellSize),
            expectedDraftIdentity: operation == .load || operation == .sortProfile
                ? nil : terrainTopologyDraftIdentities[numericCalculatorIdentity + "|" + inputID]?.identity)
    }
    func terrainTopology(inputID: String, command: TerrainTopologyCommand,
                         expectedDraftIdentity: String?) async throws -> TerrainTopologyData {
        let operation = command.operation
        guard loaded, !loadingSelection, !hasIncompleteEditorInput, !isBusy,
              let asset, asset.section == .terrains, let provider,
              fields[TerrainEditorContract.sourceField] == inputID else { throw DataToolError.unavailable }
        let capturedLoad = loadRevision, capturedEdit = editRevision
        let edits = gridEdits
        let savedBaseline = baseline, wasModified = modified
        let fieldIDs = changedFieldIDs, imageIDs = changedImageFieldIDs, draftImages = images
        let mixedIDs = clearedMixedFieldIDs, displayIDs = patchDisplayFieldIDs, toolCells = changedToolCells
        isPerforming = true; isEditingSourceDraft = true
        defer { isPerforming = false; isEditingSourceDraft = false }
        let response = try await provider.editTerrainTopology(asset, inputID: inputID,
            command: command, expectedDraftIdentity: expectedDraftIdentity, edits: edits)
        try Task.checkCancellation()
        guard capturedLoad == loadRevision, capturedEdit == editRevision, asset == self.asset,
              fields[TerrainEditorContract.sourceField] == inputID,
              response.topology.inputId == inputID,
              response.topology.sourceRevision == edits.sourceRevision,
              !response.topology.draftIdentity.isEmpty,
              Set(response.topology.features.map(\.id)).count == response.topology.features.count,
              response.topology.features.allSatisfy({ feature in
                  !feature.id.isEmpty && feature.points.allSatisfy { $0.x.isFinite && $0.y.isFinite }
                    && (feature.rings?.allSatisfy { ring in
                        ring.count >= 3 && ring.allSatisfy { $0.x.isFinite && $0.y.isFinite }
                    } ?? true)
              }),
              Set(response.topology.selectedFeatureIDs).isSubset(of: Set(response.topology.features.map(\.id))) else {
            throw CancellationError()
        }
        let snapshot = try response.snapshot.editorSnapshot
        try snapshot.validatePresentation()
        guard snapshot.sourceRevision == edits.sourceRevision,
              snapshot.fields[TerrainEditorContract.sourceField] == inputID else {
            throw ProjectFileError.invalid("The terrain topology response belongs to another input.")
        }
        invalidateSelection(); install(snapshot)
        baseline = savedBaseline
        changedFieldIDs = fieldIDs.intersection(Set(fields.keys))
        changedImageFieldIDs = imageIDs; images = draftImages
        changedSamplePages = editableSamplePages
        clearedMixedFieldIDs = mixedIDs; patchDisplayFieldIDs = displayIDs; changedToolCells = toolCells
        acknowledgeTerrainDraftCellsAndDetails()
        if operation == .load || operation == .select { modified = wasModified }
        else { editRevision += 1; modified = true }
        terrainTopologyDraftIdentities[numericCalculatorIdentity + "|" + inputID] =
            (response.topology.draftIdentity, editRevision)
        return response.topology
    }
    func terrainMap(inputID: String?) async throws -> TerrainMapData {
        guard !hasIncompleteEditorInput, let asset, let provider, !isBusy else { throw DataToolError.unavailable }
        let revision = loadRevision, edits = editRevision, selection = fields[TerrainEditorContract.sourceField]
        let result = try await provider.terrainMap(asset, edits: gridEdits, inputID: inputID)
        guard revision == loadRevision, edits == editRevision, asset == self.asset, selection == fields[TerrainEditorContract.sourceField] else { throw CancellationError() }
        try result.raster?.validate(); try result.selectedRaster?.validate(); return result
    }
    var classificationMapIdentity: String { (modelAssetID ?? "") + "|" + (sourceRevision ?? "") + "|" + String(editRevision) + "|" + String(isBusy) + "|" + (fields[ClassificationEditorContract.sourceField] ?? "") }
    func classificationMap() async throws -> ClassificationMapData {
        guard !hasIncompleteEditorInput, let asset, let provider, !isBusy else { throw DataToolError.unavailable }
        let revision = loadRevision, edits = editRevision
        let selectedInput = fields[ClassificationEditorContract.sourceField]
        let result = try await provider.classificationMap(asset, edits: gridEdits)
        guard revision == loadRevision, edits == editRevision, asset == self.asset,
              selectedInput == fields[ClassificationEditorContract.sourceField] else { throw CancellationError() }
        let selection = selectedInput.flatMap { $0.isEmpty ? nil : $0 }
        guard result.selectedInputId == selection || result.raster == nil && result.selectedInputId == nil else {
            throw ProjectFileError.invalid("The selected classification raster belongs to another input.")
        }
        _ = try result.presentation(); return result
    }
    private var terrainRasterExportIdentity: String {
        [id.uuidString, String(loadRevision), String(editRevision), modelAssetID ?? "", sourceRevision ?? "",
         sourceState ?? "", projectDraftIdentity, fields[TerrainEditorContract.sourceField] ?? "",
         currentTableSelections.keys.sorted().map { key in
             key + ":" + (currentTableSelections[key] ?? []).joined(separator: ",")
         }.joined(separator: "|")].joined(separator: "\n")
    }
    func captureTerrainRasterExportContext() -> TerrainRasterExportCapture? {
        guard loaded, let asset, asset.section == .terrains, !isBusy, !loadingSelection,
              !hasIncompleteEditorInput, let sourceRevision, !sourceRevision.isEmpty else { return nil }
        return .init(id: terrainRasterExportIdentity, editorID: id, asset: asset, edits: gridEdits)
    }
    func isCurrentTerrainRasterExportContext(_ capture: TerrainRasterExportCapture) -> Bool {
        // The export's own workspace reader lease intentionally disables editor
        // writes. It does not invalidate this immutable captured draft.
        loaded && capture.editorID == id && capture.asset == asset
            && capture.id == terrainRasterExportIdentity && !hasIncompleteEditorInput
            && capture.edits.sourceRevision == sourceRevision && !isSaving && !isPerforming && !loadingSelection
    }
    func inspectClassification(files: [URL], selections: [ClassificationImportFile]) async throws -> ClassificationImportInspection {
        guard !hasIncompleteEditorInput, let asset, let provider, !isBusy else { throw DataToolError.unavailable }
        let revision = loadRevision, edits = editRevision
        let result = try await provider.inspectClassification(asset, edits: gridEdits, files: files, selections: selections)
        guard revision == loadRevision, edits == editRevision, asset == self.asset else { throw CancellationError() }
        for item in result.items { _ = try item.preview() }
        return result
    }
    @discardableResult func importClassification(_ files: [ClassificationImportFile]) async -> Bool { await save(asset, classificationImport: files) }
    @discardableResult func importGrid(_ selection: SpatialGridSelection) async -> Bool { await save(asset, gridImport: selection) }
    @discardableResult
    func importCumulusGrid(_ selection: CumulusGridImportSelection,
                           progress: @escaping @MainActor (BackendProgressUpdate) -> Void) async -> Bool {
        guard asset?.section == .boundaryConditions, spatialPresentations[selection.layerId] != nil,
              !isBusy else { return false }
        return await save(asset, cumulusImport: selection, cumulusProgress: progress)
    }
    func discardEdits() {
        guard !workspaceWriteLocked(), !isSaving, !isPerforming, !isTerrainInputImportRunning,
              planCompute?.isRunning != true, !hasPendingGeometryEdit,
              geometryMesh?.isSavingDiagnosticsPreferences != true,
              resultPlanSettings?.isBusy != true,
              let baseline else { return }
        let terrainDraftToDiscard = terrainInputImportDraftToken ?? terrainInputImportCleanupToken
        let terrainAssetToDiscard = asset
        geometryMesh?.discardDiagnosticsPreferences()
        resultPlanSettings?.discard()
        invalidateProjectContextRefresh(keepPending: true)
        invalidateSelection()
        let lineID = selectedBoundaryLineID, payloadIDs = selectedBoundaryPayloadIDs
        dateTimeInputDrafts = [:]
        unitNumberInputDrafts = [:]
        editRevision += 1
        terrainInputImportCleanupWarning = nil; terrainInputImportCleanupToken = nil
        terrainInputImportCleanupBatchToken = nil; terrainInputImportCleanupAfterSave = false
        install(baseline); error = nil
        if let terrainDraftToDiscard, let terrainAssetToDiscard {
            scheduleTerrainInputDraftCleanup(asset: terrainAssetToDiscard, token: terrainDraftToDiscard, reportFailure: true)
        }
        invalidateGeometryChildren()
        Task {
            await self.ensureGeometryTopologyLoaded()
            await self.ensureGeometryMeshLoaded()
            await self.ensureGeometryCulvertLoaded()
        }
        if boundaryLines != nil {
            selectBoundaryLine(lineID)
            for (line, payload) in payloadIDs { selectBoundaryPayload(payload, lineID: line) }
        }
        scheduleProjectContextRefresh()
    }
    private func scheduleTerrainInputDraftCleanup(asset: ProjectAsset, token: String, reportFailure: Bool) {
        guard let provider else { return }
        Task {
            do {
                let removed = try await provider.discardTerrainInputImport(asset, draftToken: token)
                guard removed else { throw ProjectFileError.invalid("The temporary terrain import files could not be removed.") }
            } catch {
                guard reportFailure, self.asset == asset else { return }
                terrainInputImportCleanupWarning = error.localizedDescription
                terrainInputImportCleanupToken = token
                terrainInputImportCleanupBatchToken = nil
                terrainInputImportCleanupAfterSave = false
                self.error = L10n.text("The temporary terrain import files could not be removed.")
            }
        }
    }
}
