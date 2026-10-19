import SwiftUI

// Exhaustive routing keeps new source tools from silently falling back to an
// unrelated generic form. This covers tool entry points, not all original UI.
struct ToolRoute: View {
    @ObservedObject var store: WorkspaceStore
    let kind: ToolKind
    var body: some View {
        switch kind {
        case .testingViewer, .testingPOI, .testingRunner:
            ToolServiceDialog(isAvailable: store.testingProvider != nil) {
                TestingWorkspace(store: store, initialPage: kind)
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
        case .rasterSymbology: RasterSymbologyView(store: store)
        case .vectorSymbology: VectorSymbologyView(store: store)
        case .reprojection: ReprojectionWorkspace(store: store)
        case .wilcock: WilcockWorkspace(store: store)
        case .credentials: CredentialsSettingsView(store: store)
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
             .topology, .topologyRecipe, .arcPoints, .tagFilter:
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
        case .newGeometry, .newPlan, .newBoundary, .newShapefile,
             .rasterLayerImport, .vectorImport, .vectorLayerImport, .spatialImport,
             .planExport, .rasterExport, .depthExport, .geoprocessing, .vectorLabels,
             .crossSection, .unitCalculator, .addAttribute,
             .renameAttribute, .backgroundMaps, .poiImport, .coreImport, .reportIssue, .rasterCalculator:
            DataToolSheet(store: store, kind: kind).id(kind.id)
        }
    }
}
