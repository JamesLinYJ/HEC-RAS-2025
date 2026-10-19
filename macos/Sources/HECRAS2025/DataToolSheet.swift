import SwiftUI

// Dedicated source arrangements replace the former single generic tool form.
struct DataToolSheet: View {
    @ObservedObject var store: WorkspaceStore
    let kind: ToolKind
    @StateObject private var state = DataToolSession()
    @StateObject private var editor = ModelEditorSession()
    @State private var initialized = false
    @State private var importingTileIDs: Set<String> = []
    @State private var geoprocessingRunning = false
    @State private var cumulusImportIsRunning = false
    @State private var context: DataToolContext
    init(store: WorkspaceStore, kind: ToolKind) {
        self.store = store; self.kind = kind
        _context = State(initialValue: .init(projectSessionID: store.projectSessionID, mapID: store.lastActiveMapID,
            assetID: store.selectedAssetID, extent: store.activeMapState.currentExtent, attributeTable: store.activeAttributeToolContext, featureID: store.selectedFeatureID,
            spatialLayerID: store.activeSpatialImportLayerID))
    }
    private var request: ToolRequest {
        var value = state.request(kind: kind, editor: editor, context: context)
        if kind == .terrainImport { value = terrainRequest(value) }
        if kind == .griddedImport { value = griddedRequest(value) }
        return value
    }
    private var title: String {
        if kind == .reportIssue && state.presentation.support?.showsModelForm == true { return L10n.text("Send Your Model") }
        if kind == .depthExport { return L10n.text("Contour Export") }
        return kind.localizedTitle
    }
    private var isMapTool: Bool { [.terrainImport, .rasterLayerImport, .classificationImport, .vectorImport, .vectorLayerImport, .griddedImport, .depthExport, .rasterExport, .backgroundMaps, .poiImport, .wilcock, .crossSection, .arcPoints, .rasterCalculator, .geoprocessing, .topologyRecipe].contains(kind) }
    private var creationTool: Bool { [.newGeometry, .newPlan, .newBoundary, .newShapefile].contains(kind) }
    private var calculator: Bool { kind == .unitCalculator || kind == .wilcock || kind == .rasterCalculator }
    // Availability follows the actual routed provider. Typed ClassicGeometry
    // reads own their lifecycle outside the generic ToolProvider contract.
    private var toolAdapterAvailable: Bool {
        if kind == .geoprocessing, store.modelProvider is BackendModelProvider { return true }
        if usesCumulusGriddedRoute, let assetID = context.assetID {
            return store.spatialImportEditorSession(assetID: assetID) != nil
        }
        if kind == .backgroundMaps { return true }
        if kind == .crossSection, store.modelProvider is BackendModelProvider { return true }
        guard let provider = store.toolProvider else { return false }
        guard provider is BackendToolProvider else { return true }
        return [.newGeometry, .newPlan, .newBoundary, .planExport, .unitCalculator, .reportIssue].contains(kind)
    }
    private var isModelUploadForm: Bool {
        kind == .reportIssue && state.presentation.support?.showsModelForm == true
    }
    private var usesCumulusGriddedRoute: Bool {
        kind == .griddedImport && context.assetID != nil && context.spatialLayerID != nil
    }
    private var titleSymbol: String {
        if creationTool { return "plus.square" }
        if calculator { return "function" }
        if kind == .credentials { return "person.crop.circle" }
        if kind == .reportIssue { return "ladybug" }
        if [.topology, .contours, .hillshade, .vectorLabels].contains(kind) { return "slider.horizontal.3" }
        if kind == .crossSection || kind == .arcPoints { return "chart.xyaxis.line" }
        return kind.group == "Export" ? "square.and.arrow.up" : "square.and.arrow.down"
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label { Text(verbatim: title) } icon: { Image(systemName: titleSymbol) }.font(.title2)
                Spacer()
                if [.newGeometry, .newPlan, .newBoundary, .planExport, .reportIssue].contains(kind) {
                    Button("Refresh", systemImage: "arrow.clockwise") { prepare(.inspect) }
                        .disabled(state.busy || !toolAdapterAvailable)
                }
                if [.terrainImport, .rasterLayerImport, .classificationImport, .vectorImport, .vectorLayerImport, .griddedImport, .spatialImport, .rasterExport, .depthExport].contains(kind) {
                    Button("Update Preview") { prepare(.preview) }.disabled(state.busy || !toolAdapterAvailable)
                }
            }.padding(20)
            Divider()
            content.disabled(state.running || (kind == .backgroundMaps && !isSameProject))
            if kind == .backgroundMaps {
                EmptyView()
            } else if isModelUploadForm,
               state.presentation.support?.modelUploadImplemented != true {
                ToolServiceUnavailableNotice()
            } else if !toolAdapterAvailable {
                ToolServiceUnavailableNotice()
            }
            if !state.presentation.message.isEmpty {
                Text(state.presentation.message).font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.vertical, 8)
            }
            if state.running {
                OperationProgressView(title: "Processing…", message: state.progress?.message ?? "", fraction: state.progress?.fraction)
                    .padding(.horizontal, 18).padding(.bottom, 12)
            }
            if let error = state.error { Text(error).foregroundStyle(.red).textSelection(.enabled).padding(.horizontal, 18).padding(.bottom, 12) }
            Divider()
            footer
        }
        .frame(minWidth: isMapTool || kind == .reprojection ? 820 : 600, idealWidth: isMapTool || kind == .reprojection ? 1040 : 720,
            maxWidth: 1450, minHeight: kind == .unitCalculator ? 300 : 490,
            idealHeight: kind == .unitCalculator ? 330 : isMapTool || kind == .reprojection ? 730 : 610, maxHeight: 1050)
        .onAppear {
            guard !initialized else { return }
            var defaults = CreationDefaults.fields(kind: kind)
            if kind == .reportIssue {
                defaults["JiraBugReportForm/Report_Description"] = L10n.text(BugReportLimits.defaultDescription)
                state.reportFromCrash = store.reportIssueFromCrash
            }
            editor.startDraft(.init(fields: defaults, rows: [:], samples: [:], canEdit: true, images: [:])); initialized = true
            if kind == .planExport {
                editor.set("PlanExporterControl/ExportTypeIndex", "0")
                editor.set("PlanExporterControl/ExternalConnectionIndex", "0")
                editor.set("PlanExporterControl/ClipRasters", "true")
                editor.set("PlanExporterControl/EnableResample", "false")
                editor.set("PlanExporterControl/ResampleCellsize", "10")
            }
            if kind == .rasterExport { editor.set("RgbTiffExporterControl/RegionIndex", "0") }
            if kind == .terrainImport { editor.set("ImportSource", "Local Files") }
            if kind == .griddedImport { editor.set("ImportSource", "Local Files") }
            if kind == .griddedImport {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
                let today = calendar.startOfDay(for: Date())
                let startKey = "CumulusImportSource/CumulusStartDate"
                let endKey = "CumulusImportSource/CumulusEndDate"
                if editor.fields[startKey] == nil || editor.fields[endKey] == nil {
                    let end = calendar.date(byAdding: .day, value: -1, to: today) ?? today
                    let start = calendar.date(byAdding: .day, value: -3, to: today) ?? today
                    let formatter = ISO8601DateFormatter()
                    if editor.fields[startKey] == nil { editor.set(startKey, formatter.string(from: start)) }
                    if editor.fields[endKey] == nil { editor.set(endKey, formatter.string(from: end)) }
                }
            }
            if kind == .reprojection {
                editor.set("ReprojectionToolControl/ViewModel_SourceProjectionOption", "Project")
                editor.set("ReprojectionToolControl/ViewModel_DestProjectionOption", "Project")
            }
            if kind == .rasterLayerImport {
                editor.set("RasterImporter/TargetProjection", store.document?.projectionValue ?? "")
            }
            if kind == .vectorLayerImport {
                editor.set("VectorImporter/TargetProjection", store.document?.projectionValue ?? "")
            }
            if kind == .tagCreate { editor.set("CreateTagControl/ViewModel_NewTagType", "String") }
            if kind == .addAttribute { editor.set("AddAttributeTableColumnControl/ViewModel_NewColumnType", "String") }
            if kind == .tagFilter {
                editor.set("TagFilterItemControl/FilterItem_Type", "Tag")
                editor.set("TagFilterItemControl/FilterItem_Operator", "IsNotBlank")
            }
        }
        .task(id: state.signature(request)) {
            if kind == .backgroundMaps { return }
            if kind == .geoprocessing || usesCumulusGriddedRoute { return }
            // The typed ClassicGeometry browser owns its read/cancel lifecycle.
            guard !(kind == .crossSection && store.modelProvider is BackendModelProvider) else { return }
            guard initialized, toolAdapterAvailable, !state.running, !state.isCurrent(request), isSameProject else { return }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            prepare(kind == .reprojection ? .reproject : calculator ? .calculate : .inspect)
        }
        .onDisappear { state.stopPreparation() }
        .onChange(of: store.hasUnsavedModelEdits) { _, modified in
            if kind == .planExport, !modified, initialized, !state.busy { prepare(.inspect) }
        }
        .onChange(of: state.inputFiles) { _, files in
            editor.resetToolRows()
            if kind == .initialConditions {
                editor.set("AttachInitialConditionsDialog/_vm_Filename", files.first?.path ?? "")
            }
            if kind == .rasterLayerImport {
                editor.set("RasterImporter/GDALFile", files.first?.path ?? "")
            }
            if kind == .vectorLayerImport {
                editor.set("VectorImporter/ShapeFilePath", files.first?.path ?? "")
            }
        }
        .onChange(of: store.projectSessionID) { _, _ in
            state.stopPreparation(); state.error = L10n.text("The project changed. Reopen this tool for the current project.")
        }
        .interactiveDismissDisabled(state.running || geoprocessingRunning
            || (usesCumulusGriddedRoute && cumulusImportIsRunning))
    }
    @ViewBuilder private var content: some View {
        switch kind {
        case .credentials:
            CredentialsContent(store: store, state: state, editor: editor, clear: { perform(.clearCredentials, nil) })
        case .reportIssue:
            BugReportContent(store: store, state: state, editor: editor)
        case .topology, .contours, .hillshade, .vectorLabels:
            MapStyleContent(store: store, kind: kind, state: state, editor: editor, perform: perform)
        case .topologyRecipe:
            TopologyRecipeBuilderView(store: store, editor: editor, canForceSet: toolAdapterAvailable, forceSet: { execute(.execute) })
        case .geoprocessing:
            GeoprocessingPolylineToolView(store: store, mapID: context.mapID,
                projectSessionID: context.projectSessionID, isRunning: $geoprocessingRunning)
        case .crossSection:
            if store.modelProvider is BackendModelProvider { ClassicCrossSectionBrowser(store: store) }
            else { CrossSectionContent(state: state) }
        case .arcPoints:
            ArcPointsContent(store: store, state: state, editor: editor)
        case .newGeometry, .newPlan, .newBoundary, .newShapefile:
            CreationToolContent(store: store, kind: kind, state: state, editor: editor)
        case .unitCalculator:
            UnitCalculatorContent(store: store, state: state, editor: editor)
        case .wilcock:
            WilcockContent(store: store, state: state, editor: editor, perform: perform)
        case .rasterCalculator:
            RasterCalculatorContent(store: store, state: state, editor: editor, current: state.isCurrent(request), prepare: { prepare(.preview) }, perform: perform)
        case .poiImport:
            PointImportContent(store: store, state: state, importFile: importPoints)
        case .planExport, .rasterExport, .depthExport:
            ExportToolContent(store: store, kind: kind, state: state, editor: editor, current: state.isCurrent(request))
        case .terrainImport:
            TerrainImportContent(store: store, state: state, editor: editor, importingTileIDs: $importingTileIDs,
                current: state.isCurrent(request))
        case .rasterLayerImport:
            RasterLayerImportContent(store: store, state: state, editor: editor, current: state.isCurrent(request))
        case .vectorImport:
            VectorImportContent(store: store, state: state, editor: editor, current: state.isCurrent(request))
        case .vectorLayerImport:
            VectorLayerImportContent(store: store, state: state, editor: editor, current: state.isCurrent(request))
        case .classificationImport:
            ClassificationImportContent(store: store, state: state, editor: editor, current: state.isCurrent(request))
        case .backgroundMaps:
            BackgroundMapContent(store: store, state: state, editor: editor, mapID: context.mapID)
        case .tagCreate, .tagEdit, .tagFilter, .addAttribute, .renameAttribute:
            MetadataToolContent(store: store, kind: kind, state: state, editor: editor, context: context,
                currentRequest: { request }, perform: perform)
        case .griddedImport:
            if let assetID = context.assetID, let layerID = context.spatialLayerID {
                if let session = store.spatialImportEditorSession(assetID: assetID) {
                    CumulusGriddedImportRoute(store: store, session: session, assetID: assetID,
                        layerID: layerID, mapID: context.mapID, initialExtent: context.extent,
                        isImportingChanged: { cumulusImportIsRunning = $0 })
                } else {
                    ContentUnavailableView(L10n.text("Spatial import editor unavailable"),
                        systemImage: "square.stack.3d.up.slash",
                        description: Text(L10n.text("Reopen the gridded import from its owning boundary condition.")))
                }
            } else {
                TypedEditorToolRoute(store: store, action: .griddedImport)
            }
        case .spatialImport:
            SpatialImportContent(store: store, state: state, editor: editor)
        case .coreImport, .initialConditions:
            FileAttachmentContent(store: store, kind: kind, state: state, editor: editor)
        case .reprojection:
            ReprojectionContent(store: store, state: state, editor: editor, current: state.isCurrent(request),
                toolAdapterAvailable: toolAdapterAvailable, reproject: { prepare(.reproject) })
        default: EmptyView()
        }
    }
    private var footer: some View {
        if kind == .geoprocessing || usesCumulusGriddedRoute { return AnyView(EmptyView()) }
        return AnyView(HStack {
            if toolAdapterAvailable && state.preparing { ProgressView().controlSize(.small); Text("Loading…").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button(kind == .reprojection || calculator || kind == .crossSection ? "Close" : kind == .credentials ? "Back" : "Cancel", role: .cancel) {
                if state.running { state.cancelExecution() }
                else { state.stopPreparation(); store.activeTool = nil }
            }.keyboardShortcut(.cancelAction).disabled(state.running && !state.presentation.canCancel)
            if kind == .coreImport {
                Button("Add Reference") { execute(.addReference) }.disabled(!canExecute)
                Button("Import File") { execute(.copyFile) }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction).disabled(!canExecute)
            } else if kind != .reprojection && !calculator && kind != .crossSection && kind != .backgroundMaps {
                Button(LocalizedStringKey(primaryTitle)) {
                    if kind == .tagEdit { perform(.assignTag, nil) }
                    else if kind == .credentials { perform(.login, nil) }
                    else if kind == .topology { perform(.applyTopologyFactor, nil) }
                    else { execute(.execute) }
                }
                    .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction).disabled(!canExecute)
            }
        }.padding(16))
    }
    private var isSameProject: Bool { context.projectSessionID == store.projectSessionID }
    private var primaryTitle: String {
        switch kind {
        case .credentials: "Login"
        case .reportIssue: "Submit"
        case .topology, .topologyRecipe, .contours, .hillshade, .vectorLabels, .arcPoints: "Apply"
        case .geoprocessing: "Run"
        case .newGeometry, .newPlan, .newBoundary, .newShapefile: "Create"
        case .tagCreate, .addAttribute: "Create"
        case .renameAttribute: "Rename"
        case .tagEdit: "Assign Tag"
        case .tagFilter: "Apply"
        case .initialConditions: "Attach"
        default: kind.group == "Export" ? "Export" : "Import"
        }
    }
    private var canExecute: Bool {
        guard isSameProject, toolAdapterAvailable, !state.busy, request.inputIssue == nil, state.isCurrent(request) else { return false }
        // No active IGeoprocessingTool is currently routed into this sheet.
        // Keep Run visible but disabled until the route can supply one.
        if kind == .geoprocessing { return false }
        if kind == .planExport && (store.hasUnsavedModelEdits || store.isSavingAll) { return false }
        if kind == .credentials { return state.presentation.support?.canLogin == true }
        guard state.presentation.canExecute else { return false }
        if kind == .reportIssue {
            if state.presentation.support?.showsModelForm == true { return state.presentation.support?.modelUploadImplemented == true }
            return BugReportLimits.valid(fields: editor.fields)
        }
        if kind == .arcPoints && context.featureID == nil { return false }
        if [.rasterLayerImport, .vectorLayerImport].contains(kind), request.inputFiles.isEmpty { return false }
        if [.planExport, .rasterExport, .depthExport].contains(kind) { return request.destination != nil }
        if [.addAttribute, .renameAttribute].contains(kind), context.attributeTable == nil { return false }
        if kind == .newShapefile, request.destination == nil { return false }
        if kind == .newPlan,
           (editor.fields["NewPlanControl/SelectedGeometry"] ?? "").isEmpty || (editor.fields["NewPlanControl/SelectedBoundaryCondition"] ?? "").isEmpty { return false }
        if let name = nameField { return !(editor.fields[name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return true
    }
    private var nameField: String? {
        switch kind {
        case .newGeometry: "NewGeometryControl/GeometryName"
        case .newPlan: "NewPlanControl/PlanName"
        case .newBoundary: "NewBoundaryConditionControl/BoundaryConditionName"
        case .newShapefile: "NewShapefileDialog/ViewModel_FileName"
        case .tagCreate: "CreateTagControl/ViewModel_NewTagName"
        case .addAttribute: "AddAttributeTableColumnControl/ViewModel_NewColumnName"
        case .renameAttribute: "RenameAttributeTableColumnControl/ViewModel_NewColumnName"
        default: nil
        }
    }
    private func importPoints(_ file: URL) {
        guard isSameProject, toolAdapterAvailable else { return }
        var value = request; value.operation = .importPoints; value.inputFiles = [file]
        state.perform(value, editor: editor, provider: store.toolProvider, currentRequest: { request })
    }
    private func perform(_ operation: DataToolOperation, _ itemID: String?) {
        guard isSameProject, toolAdapterAvailable else { return }
        var value = request; value.operation = operation; value.sourceItemID = itemID
        state.perform(value, editor: editor, provider: store.toolProvider, currentRequest: { request },
            sourceWins: operation == .assignTag || operation == .assignRecentTag
                ? ["SetTagValueControl/ViewModel_SelectedTagDefinition", "SetTagValueControl/ViewModel_Value", "SetTagValueControl/ViewModel_BoolValue"]
                : operation == .clearCredentials ? ["CredentialsPage/Key", "CredentialsPage/Secret"] : []) { _ in
            if isSameProject { store.refreshAssets() }
        }
    }
    private func prepare(_ operation: DataToolOperation) {
        guard isSameProject, toolAdapterAvailable else { return }
        var value = request; value.operation = operation
        state.prepare(value, editor: editor, provider: store.toolProvider, currentRequest: { request })
    }
    private func setDownloadExtent(_ extent: ViewportRequest?) {
        context = DataToolContext(projectSessionID: context.projectSessionID, mapID: context.mapID,
            assetID: context.assetID, extent: extent, attributeTable: context.attributeTable,
            featureID: context.featureID, spatialLayerID: context.spatialLayerID)
    }
    private func execute(_ operation: DataToolOperation) {
        guard canExecute else { return }
        var value = request; value.operation = operation
        state.execute(value, provider: store.toolProvider) {
            guard isSameProject else { return }
            store.refreshAssets()
            if store.activeTool == kind { store.activeTool = nil }
        }
    }
    private func terrainRequest(_ value: ToolRequest) -> ToolRequest {
        var fields = value.fields
        fields["ImportingTileIDs"] = importingTileIDs.sorted().joined(separator: "\n")
        return ToolRequest(kind: value.kind, fields: fields,
            inputFiles: fields["ImportSource"] == "USGS" ? [] : value.inputFiles,
            destination: value.destination, images: value.images, context: value.context,
            operation: value.operation, selectedLayerIDs: value.selectedLayerIDs, coordinateRows: value.coordinateRows, rows: value.rows,
            inputIssue: value.inputIssue)
    }
    private func griddedRequest(_ value: ToolRequest) -> ToolRequest {
        var fields = value.fields
        for id in ["ProductCoverageText", "DownloadAreaText", "HasDownloadArea", "CumulusConnection",
                   "CumulusConnectionStatus", "CumulusLoadingGrids", "CanChangeCumulusEnvironment"] {
            fields["CumulusImportSource/" + id] = nil
        }
        return ToolRequest(kind: value.kind, fields: fields,
            inputFiles: value.inputFiles, destination: value.destination, images: value.images,
            context: value.context, operation: value.operation, selectedLayerIDs: value.selectedLayerIDs,
            coordinateRows: value.coordinateRows, rows: value.rows, sourceItemID: value.sourceItemID,
            triggeringField: value.triggeringField, interestPoints: value.interestPoints,
            replaceDestination: value.replaceDestination, inputIssue: value.inputIssue)
    }
}

enum GeoprocessingInputKind: String, CaseIterable, Identifiable {
    case text, integer, double, boolean, enumeration
    case points, polylines, polygons, complexPolygon
    case integerRaster, floatRaster, doubleRaster, extent
    var id: String { rawValue }
    var title: String {
        switch self {
        case .text: "Text"
        case .integer: "Integer"
        case .double: "Number"
        case .boolean: "Boolean"
        case .enumeration: "Choice"
        case .points: "Points"
        case .polylines: "Polylines"
        case .polygons: "Polygons"
        case .complexPolygon: "Complex Polygon"
        case .integerRaster: "Integer Raster"
        case .floatRaster: "Float Raster"
        case .doubleRaster: "Double Raster"
        case .extent: "Extent"
        }
    }
    var requiresMapSelection: Bool {
        [.points, .polylines, .polygons, .complexPolygon, .integerRaster, .floatRaster, .doubleRaster, .extent].contains(self)
    }
}

struct GeoprocessingInputDefinition: Identifiable {
    let id: String
    let title: String
    let kind: GeoprocessingInputKind
    var choices: [EditorChoice] = []
    var defaultValue = ""
    var description = ""
}

struct GeoprocessingOutputDefinition: Identifiable {
    let id: String
    let title: String
    let kind: GeoprocessingInputKind
}

/// Input/output descriptions are supplied by a selected IGeoprocessingTool.
/// Keeping the rendering independent of the runtime adapter preserves the
/// complete typed form when that metadata bridge is connected.
struct GeoprocessingToolContent: View {
    @ObservedObject var state: DataToolSession
    @ObservedObject var editor: ModelEditorSession
    let current: Bool
    let toolAdapterAvailable: Bool
    let toolName: String?
    let inputs: [GeoprocessingInputDefinition]
    let outputs: [GeoprocessingOutputDefinition]
    @State private var values: [String: String] = [:]
    var body: some View {
        HSplitView {
            Form {
                Section("Geoprocessing Tool") {
                    LabeledContent("Tool", value: toolName ?? "No tool selected")
                    if toolName == nil {
                        Text("Open this form from a map-layer processing action to load its tool and parameters.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Section("Inputs") {
                    if inputs.isEmpty {
                        ContentUnavailableView("No Geoprocessing Tool Selected", systemImage: "point.3.connected.trianglepath.dotted",
                            description: Text("Open this form from a map-layer processing action to load that tool’s inputs."))
                            .frame(minHeight: 150)
                    } else {
                        ForEach(inputs) { input in
                            GeoprocessingInputField(definition: input, value: Binding(get: {
                                values[input.id] ?? input.defaultValue
                            }, set: { values[input.id] = $0 }))
                        }
                    }
                }
                Section("Outputs") {
                    if outputs.isEmpty {
                        Text("Output layers and handlers are provided by the selected geoprocessing tool.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(outputs) { output in
                            LabeledContent(LocalizedStringKey(output.title), value: output.kind.title)
                        }
                    }
                }
                if !toolAdapterAvailable {
                    Label("The geoprocessing runtime adapter is unavailable.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !state.presentation.message.isEmpty {
                    Label(state.presentation.message, systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if state.running { ProgressView("Running Geoprocessing Tool…") }
                if let error = state.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled) }
            }.formStyle(.grouped).frame(minWidth: 330, idealWidth: 430, maxWidth: 560)
            DataToolPreviewView(preview: state.presentation.preview, loading: state.preparing, isCurrent: current)
        }
    }
}

private struct GeoprocessingInputField: View {
    let definition: GeoprocessingInputDefinition
    @Binding var value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            switch definition.kind {
            case .boolean:
                Toggle(LocalizedStringKey(definition.title), isOn: Binding(get: { value.lowercased() == "true" }, set: { value = String($0) }))
            case .enumeration:
                Picker(LocalizedStringKey(definition.title), selection: $value) {
                    ForEach(definition.choices) { choice in Text(LocalizedStringKey(choice.title)).tag(choice.id) }
                }
            case .points, .polylines, .polygons, .complexPolygon:
                LabeledContent(LocalizedStringKey(definition.title), value: "Current Map Selection")
                Label(LocalizedStringKey(definition.kind.title + " inputs require a map selection."), systemImage: "cursorarrow.rays")
                    .font(.caption).foregroundStyle(.secondary)
            case .integerRaster, .floatRaster, .doubleRaster:
                LabeledContent(LocalizedStringKey(definition.title), value: "Selected Raster")
                Label(LocalizedStringKey(definition.kind.title + " inputs require a raster selection."), systemImage: "square.grid.3x3")
                    .font(.caption).foregroundStyle(.secondary)
            case .extent:
                LabeledContent(LocalizedStringKey(definition.title), value: "Current Map Extent")
            case .text, .integer, .double:
                TextField(LocalizedStringKey(definition.title), text: $value)
                    .textFieldStyle(.roundedBorder).monospacedDigit()
                if definition.kind == .integer, !value.isEmpty, Int32(value) == nil {
                    Text("Enter a 32-bit integer.").font(.caption).foregroundStyle(.red)
                }
                if definition.kind == .double, !value.isEmpty, Double(value)?.isFinite != true {
                    Text("Enter a finite number.").font(.caption).foregroundStyle(.red)
                }
            }
            if !definition.description.isEmpty { Text(LocalizedStringKey(definition.description)).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
