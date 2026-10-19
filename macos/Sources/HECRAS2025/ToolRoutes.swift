import SwiftUI

// Exhaustive routing keeps new source tools from silently falling back to an
// unrelated generic form. This covers tool entry points, not all original UI.
struct ToolRoute: View {
    @ObservedObject var store: WorkspaceStore
    let kind: ToolKind
    var body: some View {
        switch kind {
        case .testingViewer, .testingPOI, .testingRunner, .poiImport:
            ToolServiceDialog(isAvailable: store.testingProvider != nil) {
                TestingWorkspace(store: store, initialPage: kind == .poiImport ? .testingPOI : kind)
            }
        case .testingProjectUpload, .testingGeometryUpload:
            ToolServiceDialog(isAvailable: store.testingUploadProvider != nil) {
                TestingUploader(store: store, kind: kind)
            }
        case .planPicker:
            if let client = store.runtimeInfoClient {
                ResultPlanComparisonTool(store: store, client: client)
            } else {
                ToolServiceDialog(isAvailable: false) {
                    ContentUnavailableView(L10n.text("Compare Result Plans"), systemImage: "square.stack.3d.up")
                        .frame(minWidth: 500, minHeight: 390)
                }
            }
        case .addAttribute, .renameAttribute:
            GeometryTopologyMetadataColumnToolRoute(store: store, kind: kind, context: store.activeAttributeToolContext)
        case .rasterLayerImport: RasterLayerImportView(store: store)
        case .vectorLayerImport: VectorLayerImportRouteView(store: store, initialMapID: store.lastActiveMapID)
        case .rasterSymbology: RasterSymbologyView(store: store)
        case .rasterExport: RasterRGBExportToolView(store: store)
        case .depthExport: DepthShapefileExportToolView(store: store)
        case .newShapefile: NewShapefileRoute(store: store, mapID: store.lastActiveMapID)
        case .rasterCalculator:
            let mapID = store.lastActiveMapID
            RasterCalculatorWorkspace(store: store, mapID: mapID,
                viewport: { store.existingMapState(for: mapID)?.resultViewport })
        case .vectorSymbology, .vectorLabels: VectorSymbologyView(store: store)
        case .reprojection: ReprojectionWorkspace(store: store)
        case .wilcock: WilcockWorkspace(store: store)
        case .credentials: CredentialsSettingsView(store: store)
        case .coreImport: CoreLayerReferenceManagerView(store: store)
        case .nldImport:
            ToolServiceDialog(isAvailable: store.featureQueryProvider != nil) {
                FeatureQueryView(store: store, kind: .nld)
            }
        case .nsiImport:
            ToolServiceDialog(isAvailable: store.featureQueryProvider != nil) {
                FeatureQueryView(store: store, kind: .nsi)
            }
        case .nfhlImport:
            ToolServiceDialog(isAvailable: store.featureQueryProvider != nil) {
                FeatureQueryView(store: store, kind: .nfhl)
            }
        case .osmImport:
            ToolServiceDialog(isAvailable: store.featureQueryProvider != nil) {
                FeatureQueryView(store: store, kind: .osm)
            }
        case .newPayload: PayloadCreationRoute(store: store, session: store.primaryEditorSession(.boundaryCondition))
        case .terrainImport, .classificationImport, .initialConditions, .tagCreate, .tagEdit,
             .topology, .topologyRecipe, .arcPoints, .tagFilter, .vectorImport, .spatialImport:
            TypedEditorToolRoute(store: store, action: kind)
        case .griddedImport:
            if store.activeSpatialImportLayerID != nil {
                // The per-layer Cumulus command is a separate source service.
                // A local-file importer cannot satisfy that provider request.
                DataToolSheet(store: store, kind: kind).id(kind.id)
            } else {
                TypedEditorToolRoute(store: store, action: kind)
            }
        case .contours, .hillshade:
            TypedRasterStyleToolRoute(store: store, action: kind, mapID: store.lastActiveMapID)
        case .newGeometry, .newPlan, .newBoundary,
             .planExport, .geoprocessing,
             .crossSection, .unitCalculator, .backgroundMaps, .reportIssue:
            DataToolSheet(store: store, kind: kind).id(kind.id)
        }
    }
}
