import SwiftUI
import RASWorkspaceCore

enum ToolKind: String, CaseIterable, Identifiable, Sendable {
    case newGeometry = "New Geometry", newPlan = "New Plan", newBoundary = "New Boundary Condition"
    case newPayload = "New Payload", newShapefile = "New Shapefile"
    case terrainImport = "Import Terrain", rasterLayerImport = "Import Raster Layer"
    case classificationImport = "Import Classification", vectorImport = "Import Vector", vectorLayerImport = "Import Vector Layer"
    case nldImport = "NLD Importer", nsiImport = "NSI Importer", nfhlImport = "NFHL Importer", osmImport = "OpenStreetMap Importer"
    case griddedImport = "Import Gridded Data", spatialImport = "Import Spatial Boundary", initialConditions = "Attach Initial Conditions"
    case planExport = "Export Plan", rasterExport = "Export RGB Raster", depthExport = "Export Depth Shapefile"
    case reprojection = "Reprojection", topology = "Topology Settings", topologyRecipe = "Topology Recipe"
    case contours = "Contours", hillshade = "Hillshade", geoprocessing = "Geoprocessing Tool", planPicker = "Compare Result Plans"
    case rasterSymbology = "Raster Symbology", vectorSymbology = "Vector Symbology", vectorLabels = "Vector Labels"
    case crossSection = "Cross Section", arcPoints = "Arc Points", unitCalculator = "Unit Calculator", wilcock = "Wilcock Sediment Calculator"
    case rasterCalculator = "Raster Calculator"
    case tagCreate = "Create Tag", tagEdit = "Set Tag Value", tagFilter = "Tag Filter"
    case addAttribute = "Add Attribute Column", renameAttribute = "Rename Attribute Column"
    case backgroundMaps = "Background Maps", poiImport = "Import Points of Interest"
    case coreImport = "Import Model Layer", credentials = "Credentials", reportIssue = "Report Issue"
    case testingViewer = "Testing Projects", testingProjectUpload = "Upload Testing Project", testingGeometryUpload = "Upload Testing Geometry"
    case testingPOI = "Testing Points of Interest", testingRunner = "Testing Runner"
    var id: String { rawValue }
    @MainActor var localizedTitle: String { L10n.text(rawValue) }
    var requiresProject: Bool {
        switch self {
        case .credentials, .reportIssue, .reprojection, .wilcock: false
        default: true
        }
    }
    var group: String {
        switch self {
        case .newGeometry, .newPlan, .newBoundary, .newPayload, .newShapefile: "Create"
        case .terrainImport, .rasterLayerImport, .classificationImport, .vectorImport, .vectorLayerImport,
             .griddedImport, .spatialImport, .initialConditions, .poiImport, .coreImport, .nldImport, .nsiImport, .nfhlImport, .osmImport: "Import"
        case .planExport, .rasterExport, .depthExport: "Export"
        case .reprojection, .topology, .topologyRecipe, .contours, .hillshade, .rasterSymbology, .vectorSymbology, .vectorLabels, .backgroundMaps: "Map Tools"
        case .crossSection, .arcPoints, .unitCalculator, .wilcock, .rasterCalculator, .geoprocessing, .planPicker: "Analysis"
        case .tagCreate, .tagEdit, .tagFilter, .addAttribute, .renameAttribute: "Tags"
        case .credentials, .reportIssue: "Support"
        case .testingViewer, .testingProjectUpload, .testingGeometryUpload, .testingPOI, .testingRunner: "Testing"
        }
    }
    var schemas: [String] {
        switch self {
        case .newGeometry: ["NewGeometryDialog", "NewGeometryControl"]
        case .newPlan: ["NewPlanControl", "NewPlanDialog"]
        case .newBoundary: ["NewBoundaryConditionControl", "NewBoundaryConditionDialog"]
        case .newPayload: ["NewPayloadDialog", "NewPayloadPage"]
        case .newShapefile: ["NewShapefileDialog"]
        case .terrainImport: ["TerrainImporterDialog", "TerrainImporter", "LocalFilesImportSource", "USGSTerrainImportControl", "USGSFilterControl"]
        case .rasterLayerImport: ["RasterImporterDialog", "RasterImporter", "RasterSummaryProperties", "RasterFileProperties", "RasterStatProperties"]
        case .nldImport: ["NLDQuerierControl", "MapImporterControl"]
        case .nsiImport: ["NSIQuerierControl", "MapImporterControl"]
        case .nfhlImport: ["NFHLQuerierControl", "MapImporterControl"]
        case .osmImport: ["OSMQuerierControl", "MapImporterControl"]
        case .classificationImport: ["ClassificationVectorImporter"]
        case .vectorImport: ["ArcImportDialog"]
        case .vectorLayerImport: ["VectorImporterDialog", "VectorImporter"]
        case .griddedImport: ["GriddedDataImporter", "GriddedDataImporterSlider", "GriddedDataImporterTimeline", "CumulusImportSource"]
        case .spatialImport: ["SpatialBoundaryConditionRasterImporter"]
        case .initialConditions: ["AttachInitialConditionsDialog"]
        case .planExport: ["PlanExporterControl"]
        case .rasterExport: ["RgbTiffExporterControl"]
        case .depthExport: ["DepthShapeExporterDialog", "DepthShapeExporter"]
        case .reprojection: ["ReprojectionToolControl", "ProjectionSummary"]
        case .topology: ["TopologyProperties"]
        case .topologyRecipe: ["TopologyRecipeBuilder", "RecipeBuilder", "RecipeStepCard", "IngredientCard", "RecipeStepParameterBase", "RecipeStepParameterBoolean", "RecipeStepParameterDouble", "RecipeStepParameterInteger", "RecipeStepParameterNone"]
        case .geoprocessing: ["GeoprocessingToolControl"]
        case .planPicker: ["PlanPickerDialog"]
        case .contours: ["ContourSettingsGroup"]
        case .hillshade: ["HillshadeSettingsGroup"]
        case .rasterSymbology: ["RasterSymbologyEditor", "RasterSymbologySettingsGroup", "ColorPalettePicker", "ColorInfosEditor", "ColorInfoEditor", "RasterFileProperties", "RasterSummaryProperties", "RasterTerrainInputProperties"]
        case .vectorSymbology: ["VectorSymbologyOptionEditor"]
        case .vectorLabels: ["VectorTextEditor"]
        case .crossSection: ["CrossSectionEditorControl"]
        case .arcPoints: ["ArcPointsEditorDialog", "ArcEditor"]
        case .unitCalculator: ["UnitCalculatorPage", "UnitCalculatorButton", "UnitCalculator"]
        case .wilcock: ["WilcockMainControl", "WilcockBTMControl", "WilcockSBTMControl", "WilcockISBTMControl", "WilcockSTABControl", "WilcockSTATEControl"]
        case .rasterCalculator: ["RasterCalculatorEditor"]
        case .tagCreate: ["CreateTagControl"]
        case .tagEdit: ["SetTagValueControl"]
        case .tagFilter: ["TagFilterItemControl"]
        case .addAttribute: ["AddAttributeTableColumnControl"]
        case .renameAttribute: ["RenameAttributeTableColumnControl"]
        case .backgroundMaps: ["RasBackgroundMaps", "OSMStylePicker"]
        case .poiImport: ["PoiImporter"]
        case .coreImport: ["CoreLayerImportDialog"]
        case .credentials: ["CredentialsPage"]
        case .reportIssue: ["JiraBugReportForm", "JiraBugModelForm"]
        case .testingViewer: ["TestingProjectsViewerPage", "TestingProjectsViewer"]
        case .testingProjectUpload: ["TestingProjectUploaderPage", "TestingProjectUploader", "TestingPoiEditorPage", "TestingRunnerPage"]
        case .testingGeometryUpload: ["TestingGeometryUploader", "TestingGeometryUploaderPage"]
        case .testingPOI: ["TestingPoiEditorPage"]
        case .testingRunner: ["TestingRunner", "TestingRunnerPage"]
        }
    }
}

struct ToolRequest: Sendable {
    let kind: String
    let fields: [String: String]
    var inputFiles: [URL]
    let destination: URL?
    let images: [String: [ImageAttachment]]
    var context: DataToolContext? = nil
    var operation: DataToolOperation = .execute
    var selectedLayerIDs: Set<String> = []
    var coordinateRows: [ToolCoordinateRow] = []
    var rows: [String: [EditorRow]] = [:]
    var sourceItemID: String? = nil
    var triggeringField: String? = nil
    var interestPoints: [InterestPoint] = []
    var replaceDestination = false
    // Presentation validation never enters the retained source field map.
    var inputIssue: String? = nil
    var reportFromCrash = false
}
@MainActor
protocol ToolProvider {
    func setProject(_ document: ProjectDocument?, sessionID: UUID)
    func execute(_ request: ToolRequest) async throws
    func prepare(_ request: ToolRequest) async throws -> DataToolPresentation
    func perform(_ request: ToolRequest) async throws -> DataToolPresentation
    func searchProjections(_ query: String) async throws -> [ToolProjectionMatch]
    func execute(_ request: ToolRequest, progress: @escaping @MainActor (DataToolProgress) -> Void) async throws
}
extension ToolProvider {
    func setProject(_ document: ProjectDocument?, sessionID: UUID) {}
    func perform(_ request: ToolRequest) async throws -> DataToolPresentation { throw DataToolError.unavailable }
    func searchProjections(_ query: String) async throws -> [ToolProjectionMatch] { throw DataToolError.unavailable }
    func prepare(_ request: ToolRequest) async throws -> DataToolPresentation {
        throw DataToolError.unavailable
    }
    func execute(_ request: ToolRequest, progress: @escaping @MainActor (DataToolProgress) -> Void) async throws {
        try await execute(request)
    }
}

