import Foundation
import CoreGraphics
import RASWorkspaceCore
import SwiftUI

struct TerrainImportContent: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var state: DataToolSession
    @ObservedObject var editor: ModelEditorSession
    @Binding var importingTileIDs: Set<String>
    let current: Bool
    private var source: Binding<String> { Binding(get: { editor.fields["ImportSource"] ?? "Local Files" }, set: { editor.set("ImportSource", $0) }) }
    private var selectedLayer: DataToolLayer? { state.presentation.layers.first { $0.id == state.selectedSettingsLayerID } }
    var body: some View {
        VStack(spacing: 0) {
            Picker("Import Source", selection: source) { Text("Local Files").tag("Local Files"); Text("USGS").tag("USGS") }
                .pickerStyle(.segmented).padding(12)
            if source.wrappedValue == "USGS" {
                VSplitView {
                    TerrainDownloadsView(store: store, importingIDs: $importingTileIDs).frame(minHeight: 300)
                    SourceForm(page: .form("Import Settings", "USGSTerrainImportControl", "USGSFilterControl"), session: editor, store: store)
                        .frame(minHeight: 170, idealHeight: 210, maxHeight: 300)
                }
            } else {
                HSplitView {
                    VSplitView {
                        VStack(spacing: 0) {
                            DataFileList(state: state, store: store, changed: {})
                            Divider()
                            DataLayerList(title: "Terrain Layers", state: state)
                        }.frame(minHeight: 210)
                        Form {
                            Section("Global Settings") {
                                DataToolField(schema: "TerrainImporter", id: "AutoStitch", editor: editor, store: store)
                                DataToolField(schema: "LocalFilesImportSource", id: "SelectedSubdataset", editor: editor, store: store)
                            }
                            if let layer = selectedLayer, let scope = layer.scope {
                                Section("Selected Terrain Layer") {
                                    Text(layer.name).textSelection(.enabled)
                                    DataToolField(schema: "TerrainImporter", id: "Rounding", scope: scope, editor: editor, store: store)
                                    DataToolField(schema: "TerrainImporter", id: "DesiredUnitConversion", scope: scope, editor: editor, store: store)
                                    LabeledContent("Scale Factor", value: editor.fields[scope + "/TerrainImporter/ScaleFactor"] ?? "—")
                                }
                            }
                            sourceProperties
                        }.formStyle(.grouped).frame(minHeight: 230)
                    }.frame(minWidth: 300, idealWidth: 350, maxWidth: 480)
                    DataToolPreviewView(preview: state.presentation.preview, loading: state.preparing, isCurrent: current)
                }
            }
        }
    }
    @ViewBuilder private var sourceProperties: some View {
        if let layer = selectedLayer, let scope = layer.scope {
            RasterPropertiesDisclosure(schemaID: "RasterSummaryProperties", scope: scope, editor: editor)
            RasterPropertiesDisclosure(schemaID: "RasterFileProperties", scope: scope, editor: editor)
            RasterPropertiesDisclosure(schemaID: "RasterStatProperties", scope: scope, editor: editor)
        }
    }
}

struct VectorImportContent: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var state: DataToolSession
    @ObservedObject var editor: ModelEditorSession
    let current: Bool
    var body: some View {
        HSplitView {
            VSplitView {
                VStack(spacing: 0) {
                    DataFileList(state: state, store: store, changed: {})
                    Divider(); DataLayerList(title: "Importing Layers", state: state)
                }.frame(minHeight: 230)
                Form {
                    Section("Import Options") {
                        field("SelectedOption")
                        Text(editor.fields["ArcImportDialog/SelectedOption"] == "NoMerge"
                            ? L10n.text("Import without merging; overlapping arcs can be merged later.")
                            : L10n.text("Merge intersecting and overlapping arcs into the existing geometry."))
                            .font(.caption).foregroundStyle(.secondary)
                        field("MetadataMergeOption")
                        field("MergeContiguousArcs"); field("RemoveExternalArcs")
                    }
                }.formStyle(.grouped).frame(minHeight: 230)
            }.frame(minWidth: 300, idealWidth: 360, maxWidth: 500)
            DataToolPreviewView(preview: state.presentation.preview, loading: state.preparing, isCurrent: current)
        }
    }
    private func field(_ id: String) -> some View { DataToolField(schema: "ArcImportDialog", id: id, editor: editor, store: store) }
}

/// RasterFileProperties, RasterSummaryProperties and RasterStatProperties are
/// expandable, read-only responsive-context panels in the source importer.
struct RasterPropertiesDisclosure: View {
    let schemaID: String
    let scope: String
    @ObservedObject var editor: ModelEditorSession
    var overviewCount: Int? = nil
    var overviews: [String]? = nil
    @State private var expanded = true
    private var schema: SourceEditorSchema? { SourceEditorLibrary.shared.schema(schemaID) }
    private var title: String { schema?.title ?? (schemaID == "RasterStatProperties" ? "Raster Statistics" : schemaID) }
    private var extraFields: [RasterPropertyRow] {
        switch schemaID {
        case "RasterFileProperties": [.init(title: "Band Count", fieldID: "BandCount")]
        case "RasterStatProperties": [
            .init(title: "Minimum", fieldID: "MinString"), .init(title: "Maximum", fieldID: "MaxString"),
            .init(title: "Mean", fieldID: "MeanString"), .init(title: "Standard Deviation", fieldID: "StandardDeviationString")
        ]
        default: []
        }
    }
    var body: some View {
        DisclosureGroup(LocalizedStringKey(title), isExpanded: $expanded) {
            if let schema {
                ForEach(schema.fields) { field in
                    LabeledContent(LocalizedStringKey(field.title), value: editor.fields[field.inScope(scope).storageID] ?? "—")
                        .textSelection(.enabled)
                }
            }
            ForEach(extraFields) { field in
                LabeledContent(LocalizedStringKey(field.title), value: value(field.fieldID)).textSelection(.enabled)
            }
            if overviewCount != nil || overviews != nil {
                RasterOverviewsDisclosure(overviewCount: overviewCount, overviews: overviews)
            }
        }
    }
    private func value(_ id: String) -> String {
        editor.fields[scope + "/" + schemaID + "/" + id]
            ?? editor.fields[schemaID + "/" + id]
            ?? "—"
    }
}

/// Shows dimensions reported by the active raster inspector. A missing or
/// inconsistent snapshot stays unavailable rather than implying that the
/// raster has no overviews.
struct RasterOverviewsDisclosure: View {
    let overviewCount: Int?
    let overviews: [String]?
    @State private var expanded = true

    private var hasConsistentSnapshot: Bool {
        guard let overviewCount, let overviews else { return false }
        return overviewCount >= 0 && overviewCount == overviews.count
            && overviews.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        DisclosureGroup(LocalizedStringKey("Raster Overviews"), isExpanded: $expanded) {
            if hasConsistentSnapshot, let overviewCount, let overviews {
                if overviewCount == 0 {
                    Text("No raster overviews are available.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    LabeledContent("Overview Count", value: overviewCount.formatted())
                    ForEach(Array(overviews.enumerated()), id: \.offset) { index, dimensions in
                        LabeledContent {
                            Text(dimensions).textSelection(.enabled)
                        } label: {
                            HStack(spacing: 4) {
                                Text("Overview")
                                Text((index + 1).formatted()).monospacedDigit()
                            }
                        }
                    }
                }
            } else {
                Text("Raster overview details are unavailable.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct RasterPropertyRow: Identifiable {
    let title: String
    let fieldID: String
    var id: String { fieldID }
}

struct RasterLayerImportContent: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var state: DataToolSession
    @ObservedObject var editor: ModelEditorSession
    let current: Bool
    @StateObject private var propertySession = RasterImportContextPropertiesSession()
    private var selectedLayer: DataToolLayer? { state.presentation.layers.first { $0.id == state.selectedSettingsLayerID } }
    var body: some View {
        HSplitView {
            VSplitView {
                ImportSourceFilePicker(title: "Raster File", prompt: "Choose Raster…", store: store, state: state,
                    detail: "Choose a GDAL-readable raster file. One file is imported at a time.")
                    .frame(minHeight: 110, idealHeight: 145, maxHeight: 190)
                DataLayerList(title: "Raster Layers", state: state).frame(minHeight: 130, idealHeight: 180)
                Form {
                    RasterImportContextPropertiesView(session: propertySession,
                        filePaths: Array(state.inputFiles.prefix(1)).map(\.path),
                        compareProjectionWKT: nil)
                        .disabled(state.busy)
                    Section("Import As Reference") {
                        RasterImporterProjectionPicker(store: store, editor: editor, fieldID: "RasterImporter/TargetProjection")
                        if editor.fields["RasterImporter/CanRenderPreview"] == "false" {
                            Label("This raster is too large for an in-dialog preview.", systemImage: "info.circle")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let layer = selectedLayer, let scope = layer.scope {
                        Text(layer.name).font(.headline)
                        RasterPropertiesDisclosure(schemaID: "RasterSummaryProperties", scope: scope, editor: editor)
                        RasterPropertiesDisclosure(schemaID: "RasterFileProperties", scope: scope, editor: editor)
                        RasterPropertiesDisclosure(schemaID: "RasterStatProperties", scope: scope, editor: editor)
                    } else {
                        Section("Raster Properties") {
                            Text("Select a raster to view its summary, file details, and statistics.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.formStyle(.grouped).frame(minHeight: 260)
            }.frame(minWidth: 310, idealWidth: 390, maxWidth: 500)
            DataToolPreviewView(preview: state.presentation.preview, loading: state.preparing, isCurrent: current)
        }
    }
}

struct VectorLayerImportContent: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var state: DataToolSession
    @ObservedObject var editor: ModelEditorSession
    let current: Bool
    private var selectedLayer: DataToolLayer? { state.presentation.layers.first { $0.id == state.selectedSettingsLayerID } }
    private var selectedFile: URL? { state.inputFiles.first }
    var body: some View {
        HSplitView {
            VSplitView {
                ImportSourceFilePicker(title: "Shapefile", prompt: "Choose Shapefile…", store: store, state: state,
                    detail: "Choose a .shp file with its projection sidecar (.prj).")
                    .frame(minHeight: 120, idealHeight: 150, maxHeight: 220)
                DataLayerList(title: "Imported Layers", state: state).frame(minHeight: 130)
                Form {
                    Section("Target Projection") {
                        RasterImporterProjectionPicker(store: store, editor: editor, fieldID: "VectorImporter/TargetProjection")
                    }
                    Section("Supported Geometry") {
                        Label("Polyline and polygon shapefiles", systemImage: "point.3.connected.trianglepath.dotted")
                        if let selectedFile {
                            let isShapefile = selectedFile.pathExtension.lowercased() == "shp"
                            LabeledContent("File Type", value: isShapefile ? "Shapefile" : selectedFile.pathExtension.uppercased())
                            Label(isShapefile ? "Projection and geometry validation requires the vector importer." : "Choose a .shp file.",
                                systemImage: isShapefile ? "hourglass" : "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(isShapefile ? Color.secondary : Color.orange)
                        } else {
                            Text("Select a shapefile to validate its geometry and projection.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let layer = selectedLayer {
                        LabeledContent("Selected Layer", value: layer.name)
                        if !layer.detail.isEmpty { Text(layer.detail).font(.caption).foregroundStyle(.secondary) }
                    }
                }.formStyle(.grouped).frame(minHeight: 300)
            }.frame(minWidth: 310, idealWidth: 400, maxWidth: 510)
            DataToolPreviewView(preview: state.presentation.preview, loading: state.preparing, isCurrent: current)
        }
    }
}

struct ImportSourceFilePicker: View {
    let title: String
    let prompt: String
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var state: DataToolSession
    let detail: String
    private var file: URL? { state.inputFiles.first }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(LocalizedStringKey(title), systemImage: "doc.badge.plus").font(.headline)
                Spacer()
                Button(LocalizedStringKey(prompt), systemImage: "folder") {
                    state.inputFiles = Array(store.system.chooseInputFiles().filter(\.isFileURL).prefix(1))
                }
                .disabled(state.busy)
            }
            if let file {
                HStack {
                    Image(systemName: "doc").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.lastPathComponent).lineLimit(1).help(file.path)
                        Text(file.path).font(.caption2).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                    }
                    Spacer(minLength: 8)
                    Button { state.inputFiles = [] } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).help("Remove File")
                }
            } else {
                Text(LocalizedStringKey(detail)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .dropDestination(for: URL.self) { files, _ in
            guard !state.busy, let file = files.first(where: \.isFileURL) else { return false }
            state.inputFiles = [file]
            return true
        }
    }
}

struct RasterImporterProjectionPicker: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var editor: ModelEditorSession
    let fieldID: String
    @State private var mode = "Project"
    @State private var searching = false
    @State private var error: String?
    private var definition: String {
        editor.fields[fieldID] ?? store.document?.projectionValue ?? ""
    }
    private var projection: Binding<String> {
        Binding(get: { definition }, set: { editor.set(fieldID, $0) })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Target Projection", selection: $mode) {
                Text("Project Projection").tag("Project")
                Text("Custom Projection").tag("Custom")
            }.pickerStyle(.segmented)
                .onChange(of: mode) { _, value in
                    if value == "Project" { editor.set(fieldID, store.document?.projectionValue ?? "") }
                }
            if mode == "Project" {
                LabeledContent("Project Projection", value: store.document.map { L10n.text($0.projectionType) + ($0.projectionValue.isEmpty ? "" : " · " + $0.projectionValue) } ?? "—")
                    .textSelection(.enabled)
            } else {
                TextField("EPSG code or projection definition", text: projection, axis: .vertical).lineLimit(2...4)
                HStack {
                    Button("Search EPSG…") { searching = true }.disabled(store.projectionProvider == nil)
                    Button("Read PRJ File…") { readProjectionFile() }
                    Spacer()
                }
                .sheet(isPresented: $searching) {
                    ProjectionSearchView(provider: store.projectionProvider) { match in
                        editor.set(fieldID, String(match.code)); searching = false
                    }
                }
                .dropDestination(for: URL.self) { files, _ in
                    guard let file = files.first, file.isFileURL, file.pathExtension.lowercased() == "prj" else { return false }
                    readProjection(file)
                    return error == nil
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
        }
        .onAppear { if editor.fields[fieldID] == nil { editor.set(fieldID, store.document?.projectionValue ?? "") } }
    }
    private func readProjectionFile() {
        guard let file = store.system.chooseProjectionFile() else { return }
        readProjection(file)
    }
    private func readProjection(_ file: URL) {
        do { editor.set(fieldID, try String(contentsOf: file, encoding: .utf8)); error = nil }
        catch { self.error = error.localizedDescription }
    }
}

struct GriddedImportContent: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var state: DataToolSession
    @ObservedObject var editor: ModelEditorSession
    let current: Bool
    let toolAdapterAvailable: Bool
    let downloadExtent: ViewportRequest?
    let setDownloadExtent: (ViewportRequest?) -> Void
    let retryCumulusConnection: () -> Void
    let prepare: (DataToolOperation) -> Void
    @State private var source = "Local Files"
    @State private var showTimeline = true
    private let schema = "GriddedDataImporter"
    private var currentDate: Date? { editor.fields["GriddedDataImporter/Timeline_CurrentTime"].flatMap { ISO8601DateFormatter().date(from: $0) } }
    var body: some View {
        HSplitView {
            ScrollView {
                VStack(spacing: 0) {
                    Picker("Import Source", selection: $source) {
                        Text("Local Files").tag("Local Files")
                        Text("Cumulus").tag("Cumulus")
                    }
                    .pickerStyle(.segmented).padding(12)
                    if source == "Cumulus" {
                        VStack(spacing: 0) {
                            Form {
                            Section("Cumulus") {
                                ForEach(["SelectedCumulusEnvironment", "SelectedCumulusProduct", "CumulusStartDate", "CumulusEndDate"], id: \.self) { id in
                                    DataToolField(schema: "CumulusImportSource", id: id, editor: editor, store: store)
                                }
                                Button("Load Grids") {
                                    editor.set("ImportSource", "Cumulus")
                                    prepare(.query)
                                }
                                .disabled(state.busy || !toolAdapterAvailable)
                                if !toolAdapterAvailable {
                                    Label(L10n.text("The original model adapter for this tool is unavailable."), systemImage: "info.circle")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Section("Cumulus Connection") {
                                LabeledContent("Connection Status", value: cumulusValue("CumulusConnectionStatus"))
                                Button("Retry Connection", systemImage: "arrow.clockwise", action: retryCumulusConnection)
                                    .disabled(state.busy || !toolAdapterAvailable)
                                Toggle("Loading Grids", isOn: .constant(cumulusValue("CumulusLoadingGrids") == "true"))
                                    .disabled(true)
                                LabeledContent("Product Coverage", value: cumulusValue("ProductCoverageText"))
                                    .textSelection(.enabled)
                            }
                            }.formStyle(.grouped).frame(minHeight: 210, idealHeight: 250, maxHeight: 310)
                            CumulusDownloadAreaEditor(store: store, extent: downloadExtent, setExtent: setDownloadExtent)
                                .frame(minHeight: 260, idealHeight: 290, maxHeight: 360)
                        }
                    } else { DataFileList(state: state, store: store, changed: {}) }
                    Form {
                        Section("Loaded Data") {
                            readOnly("Start Time", "Timeline_StartTime"); readOnly("End Time", "Timeline_EndTime")
                            readOnly("Timesteps", "TotalTimesteps")
                            LabeledContent("Files", value: state.inputFiles.count.formatted())
                        }
                        Section("Import Options") {
                            LabeledContent("Precipitation File Units", value: editor.fields[schema + "/RawUnits"] ?? "—")
                            field("SelectedPrecipDataType"); field("SelectedLength"); field("AutoGenerateSelection")
                            Button("Generate Preview") { prepare(.preview) }.disabled(state.busy || !toolAdapterAvailable)
                        }
                        Section("Overlapping Timesteps") {
                            Button("Latest Issue Time") { prepare(.selectLatest) }
                            Button("Earliest Issue Time") { prepare(.selectEarliest) }
                        }.disabled(state.busy || !toolAdapterAvailable || state.presentation.timeSteps.isEmpty)
                    }.formStyle(.grouped).frame(minHeight: 510)
                }
            }.frame(minWidth: 300, idealWidth: 350, maxWidth: 470)
            DataToolPreviewView(preview: state.presentation.preview, loading: state.preparing, isCurrent: current)
                .safeAreaInset(edge: .bottom) { timeline.padding(14) }
        }.onChange(of: source) { _, value in editor.set("ImportSource", value) }
    }
    private var timeline: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Current Timestep").font(.headline)
                Spacer()
                Button { showTimeline.toggle() } label: { Image(systemName: showTimeline ? "chevron.down" : "chevron.up") }.buttonStyle(.borderless).help("Toggle Timeline")
            }
            if showTimeline {
                Picker("Current Timestep", selection: Binding(get: {
                    currentDate.flatMap { date in state.presentation.timeSteps.first { $0.date == date }?.id } ?? ""
                }, set: { id in
                    if let value = state.presentation.timeSteps.first(where: { $0.id == id }) { setTime(value.date) }
                })) {
                    Text("None").tag("")
                    ForEach(state.presentation.timeSteps) { step in Text(step.title).tag(step.id) }
                }.labelsHidden()
                Slider(value: Binding(get: {
                    guard let date = currentDate, let first = state.presentation.timeSteps.first?.date, let last = state.presentation.timeSteps.last?.date,
                          last > first else { return 0 }
                    return min(1, max(0, date.timeIntervalSince(first) / last.timeIntervalSince(first)))
                }, set: { value in
                    let steps = state.presentation.timeSteps
                    guard let first = steps.first?.date, let last = steps.last?.date else { return }
                    let time = first.addingTimeInterval(last.timeIntervalSince(first) * value)
                    if let step = steps.min(by: { abs($0.date.timeIntervalSince(time)) < abs($1.date.timeIntervalSince(time)) }) { setTime(step.date) }
                }), in: 0...1) { Text("Timeline") }.disabled(state.presentation.timeSteps.count < 2)
                HStack {
                    if let first = state.presentation.timeSteps.first { Text(first.title) }
                    Spacer()
                    if let last = state.presentation.timeSteps.last { Text(last.title) }
                }.font(.caption).foregroundStyle(.secondary)
            }
        }.padding(16).glassEffect(.regular, in: .rect(cornerRadius: 18)).disabled(state.running)
    }
    private func setTime(_ date: Date) { editor.set(schema + "/Timeline_CurrentTime", ISO8601DateFormatter().string(from: date)) }
    private func field(_ id: String) -> some View { DataToolField(schema: schema, id: id, editor: editor, store: store) }
    private func cumulusValue(_ id: String) -> String {
        editor.fields["CumulusImportSource/" + id] ?? "—"
    }
    private func readOnly(_ title: String, _ id: String) -> some View { LabeledContent(LocalizedStringKey(title), value: editor.fields[schema + "/" + id] ?? "—") }
}

private struct CumulusAreaCoordinates {
    var minX = ""
    var minY = ""
    var maxX = ""
    var maxY = ""
}

/// A source-independent map editing surface for the Cumulus AOI. Pointer
/// coordinates are converted through the active map viewport and stored in
/// project coordinates; drawing does not require a Cumulus service.
struct CumulusDownloadAreaEditor: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject private var mapState: MapState
    let extent: ViewportRequest?
    let setExtent: (ViewportRequest?) -> Void
    @State private var isDrawing = false
    @State private var dragExtent: ViewportRequest?
    @State private var coordinates = CumulusAreaCoordinates()
    @State private var coordinateError: String?

    private var vectorLayers: [MapVectorLayer] {
        mapState.visibleVectors(store.mapLayers)
    }
    private var rasterLayers: [MapRasterLayer] {
        mapState.rasters(store.rasterLayers).filter { !mapState.hiddenLayers.contains($0.id) }
    }

    init(store: WorkspaceStore, extent: ViewportRequest?, setExtent: @escaping (ViewportRequest?) -> Void) {
        self.store = store
        self.extent = extent
        self.setExtent = setExtent
        _mapState = ObservedObject(wrappedValue: store.activeMapState)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Download Area", systemImage: "crop.rotate")
                    .font(.headline)
                Spacer()
                Button(isDrawing ? "Cancel Drawing" : "Draw Download Area", systemImage: isDrawing ? "xmark" : "rectangle.dashed") {
                    isDrawing.toggle()
                    dragExtent = nil
                }
                .disabled(mapState.currentExtent == nil)
            }

            GeometryReader { geometry in
                let viewport = mapState.currentExtent
                let transform = viewport.flatMap { CumulusExtentMapTransform(extent: $0, size: geometry.size) }
                ZStack {
                    Canvas { context, size in
                        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.secondary.opacity(0.035)))
                        guard let viewport, let transform else {
                            drawGrid(in: &context, size: size)
                            return
                        }

                        drawGrid(in: &context, size: size)
                        for layer in rasterLayers {
                            guard let image = Self.image(for: layer) else { continue }
                            let topLeft = transform.screen(.init(x: layer.lowerLeft.x, y: layer.upperRight.y))
                            let bottomRight = transform.screen(.init(x: layer.upperRight.x, y: layer.lowerLeft.y))
                            context.draw(Image(decorative: image, scale: 1), in: CGRect(
                                x: topLeft.x, y: topLeft.y,
                                width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y
                            ).standardized)
                        }
                        for (index, layer) in vectorLayers.enumerated() {
                            let color = VectorStyle.color(index)
                            for feature in layer.features {
                                let path = transform.path(feature)
                                if feature.kind == .polygon { context.fill(path, with: .color(color.opacity(0.14)), style: FillStyle(eoFill: true)) }
                                if feature.kind == .point {
                                    for point in feature.paths.flatMap({ $0 }) {
                                        let p = transform.screen(point)
                                        context.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(color))
                                    }
                                }
                                context.stroke(path, with: .color(color.opacity(0.9)), lineWidth: feature.kind == .point ? 1 : 1.4)
                            }
                        }
                        let selected = dragExtent ?? extent
                        if let selected {
                            let rect = transform.rectangle(for: selected)
                            let path = Path(rect)
                            context.fill(path, with: .color(.orange.opacity(0.18)))
                            context.stroke(path, with: .color(.orange), style: StrokeStyle(lineWidth: 2, dash: [7, 4]))
                        }
                        let viewportRect = transform.rectangle(for: viewport)
                        context.stroke(Path(viewportRect), with: .color(Color.secondary.opacity(0.55)), lineWidth: 1)
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            guard isDrawing, let transform else { return }
                            dragExtent = Self.makeExtent(transform.world(value.startLocation), transform.world(value.location))
                        }
                        .onEnded { value in
                            guard isDrawing, let transform,
                                  let selected = Self.makeExtent(transform.world(value.startLocation), transform.world(value.location)) else { return }
                            setExtent(selected)
                            syncCoordinates(selected)
                            dragExtent = nil
                            isDrawing = false
                        })
                    if isDrawing {
                        Text("Drag on the map to draw a rectangular download area.")
                            .font(.caption).padding(7).workspaceGlass()
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .allowsHitTesting(false)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.secondary.opacity(0.25)))
            }
            .frame(height: 180)

            if let viewport = mapState.currentExtent {
                Text("Viewport  X: \(Self.number(viewport.lowerLeft.x)) … \(Self.number(viewport.upperRight.x))   Y: \(Self.number(viewport.lowerLeft.y)) … \(Self.number(viewport.upperRight.y))")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary).textSelection(.enabled)
            } else {
                Text("The active map viewport is unavailable.").font(.caption).foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
                GridRow {
                    TextField("Minimum X", text: $coordinates.minX).textFieldStyle(.roundedBorder)
                    TextField("Minimum Y", text: $coordinates.minY).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    TextField("Maximum X", text: $coordinates.maxX).textFieldStyle(.roundedBorder)
                    TextField("Maximum Y", text: $coordinates.maxY).textFieldStyle(.roundedBorder)
                }
            }
            HStack {
                Button("Use Current Map Extent") {
                    setExtent(mapState.currentExtent)
                    syncCoordinates(mapState.currentExtent)
                    coordinateError = nil
                }.disabled(mapState.currentExtent == nil)
                Button("Apply Coordinates", action: applyCoordinates)
                    .disabled(!hasValidCoordinates)
                Button("Clear Download Area", role: .destructive) {
                    setExtent(nil); syncCoordinates(nil); coordinateError = nil
                }.disabled(extent == nil)
            }
            if let coordinateError { Text(coordinateError).font(.caption).foregroundStyle(.red) }
            else if let extent { Text("Selected Area  X: \(Self.number(extent.lowerLeft.x)) … \(Self.number(extent.upperRight.x))   Y: \(Self.number(extent.lowerLeft.y)) … \(Self.number(extent.upperRight.y))").font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            else { Text("No download area is set; the source will use the full product coverage.").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.2)))
        .onAppear { syncCoordinates(extent) }
        .onChange(of: extent?.id) { _, _ in syncCoordinates(extent) }
    }

    private var parsedExtent: ViewportRequest? {
        guard let x1 = Double(coordinates.minX), let y1 = Double(coordinates.minY),
              let x2 = Double(coordinates.maxX), let y2 = Double(coordinates.maxY),
              [x1, y1, x2, y2].allSatisfy(\.isFinite) else { return nil }
        return Self.makeExtent(.init(x: x1, y: y1), .init(x: x2, y: y2))
    }
    private var hasValidCoordinates: Bool { parsedExtent.map { _ in true } ?? false }

    private func applyCoordinates() {
        guard let selected = parsedExtent else {
            coordinateError = L10n.text("Enter finite coordinates with a nonzero width and height.")
            return
        }
        setExtent(selected); syncCoordinates(selected); coordinateError = nil
    }

    private func syncCoordinates(_ value: ViewportRequest?) {
        guard let value else { coordinates = .init(); return }
        coordinates = .init(minX: Self.number(value.lowerLeft.x), minY: Self.number(value.lowerLeft.y),
            maxX: Self.number(value.upperRight.x), maxY: Self.number(value.upperRight.y))
    }

    private func drawGrid(in context: inout GraphicsContext, size: CGSize) {
        var grid = Path()
        for index in 1..<5 {
            let ratio = CGFloat(index) / 5
            grid.move(to: CGPoint(x: size.width * ratio, y: 0)); grid.addLine(to: CGPoint(x: size.width * ratio, y: size.height))
            grid.move(to: CGPoint(x: 0, y: size.height * ratio)); grid.addLine(to: CGPoint(x: size.width, y: size.height * ratio))
        }
        context.stroke(grid, with: .color(Color.secondary.opacity(0.16)), lineWidth: 0.5)
    }

    private static func makeExtent(_ first: MapPoint, _ second: MapPoint) -> ViewportRequest? {
        let lower = MapPoint(x: min(first.x, second.x), y: min(first.y, second.y))
        let upper = MapPoint(x: max(first.x, second.x), y: max(first.y, second.y))
        guard [lower.x, lower.y, upper.x, upper.y].allSatisfy(\.isFinite), upper.x > lower.x, upper.y > lower.y else { return nil }
        return ViewportRequest(lowerLeft: lower, upperRight: upper, animated: false, padding: 0)
    }

    private static func number(_ value: Double) -> String { String(value) }

    private static func image(for layer: MapRasterLayer) -> CGImage? {
        guard let provider = CGDataProvider(data: layer.rgba as CFData), let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: layer.width, height: layer.height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: layer.width * 4, space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

private struct CumulusExtentMapTransform {
    let extent: ViewportRequest
    let scale: CGFloat
    let origin: CGPoint
    init?(extent: ViewportRequest, size: CGSize) {
        self.extent = extent
        let width = CGFloat(extent.upperRight.x - extent.lowerLeft.x)
        let height = CGFloat(extent.upperRight.y - extent.lowerLeft.y)
        guard extent.isFiniteAndOrdered, width > 0, height > 0, size.width > 0, size.height > 0 else { return nil }
        scale = min((size.width - 20) / width, (size.height - 20) / height)
        guard scale.isFinite, scale > 0 else { return nil }
        let renderedWidth = width * scale, renderedHeight = height * scale
        origin = CGPoint(x: (size.width - renderedWidth) / 2, y: (size.height - renderedHeight) / 2)
    }
    func screen(_ point: MapPoint) -> CGPoint {
        CGPoint(x: origin.x + CGFloat(point.x - extent.lowerLeft.x) * scale,
                y: origin.y + CGFloat(extent.upperRight.y - point.y) * scale)
    }
    func world(_ point: CGPoint) -> MapPoint {
        MapPoint(x: extent.lowerLeft.x + Double((point.x - origin.x) / scale),
                 y: extent.upperRight.y - Double((point.y - origin.y) / scale))
    }
    func rectangle(for value: ViewportRequest) -> CGRect {
        let lower = screen(value.lowerLeft), upper = screen(value.upperRight)
        return CGRect(x: lower.x, y: upper.y, width: upper.x - lower.x, height: lower.y - upper.y).standardized
    }
    func path(_ feature: MapFeature) -> Path {
        var path = Path()
        for points in feature.paths {
            guard let first = points.first else { continue }
            if feature.kind == .point { let point = screen(first); path.addEllipse(in: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)); continue }
            path.move(to: screen(first))
            for point in points.dropFirst() { path.addLine(to: screen(point)) }
            if feature.kind == .polygon { path.closeSubpath() }
        }
        return path
    }
}

struct SpatialImportContent: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var state: DataToolSession
    @ObservedObject var editor: ModelEditorSession
    private let schema = "SpatialBoundaryConditionRasterImporter"
    var body: some View {
        VStack(spacing: 0) {
            DataFileList(state: state, store: store, changed: {})
            Form {
                Section("Import Options") {
                    ForEach(["SelectedDataType", "SelectedDataUnits", "SelectedTimeBehavior"], id: \.self) { id in
                        DataToolField(schema: schema, id: id, editor: editor, store: store)
                    }
                    LabeledContent("Time Shift", value: editor.fields[schema + "/TimeShift"] ?? "—")
                }
            }.formStyle(.grouped).frame(height: 225)
            DataToolBandTable(editor: editor, store: store, tableID: schema)
        }
    }
}

struct DataToolBandTable: View {
    @ObservedObject var editor: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    let tableID: String
    @State private var showsExpressionFilter = false
    @StateObject private var expressionFilter = TableExpressionFilterSession()
    private var columns: [SourceTableColumn] { editor.tablePresentations[tableID]?.columns.filter { $0.visible != false } ?? [] }
    private var filterCapture: TableFilterCapture {
        .init(owner: store.projectSessionID.uuidString + "|" + editor.id.uuidString + "|" + tableID,
            columns: (editor.tablePresentations[tableID]?.columns ?? columns).map {
                .init(id: $0.id, name: $0.title, sourceType: $0.sourceType, filterable: $0.filterable != false)
            }, rows: (editor.rows[tableID] ?? []).map { .init(id: $0.id, values: $0.values) })
    }
    private var visibleRows: [EditorRow] {
        (editor.rows[tableID] ?? []).filter { !showsExpressionFilter || (expressionFilter.matchingRowIDs?.contains($0.id) ?? true) }
    }
    var body: some View {
        VStack(spacing: 0) {
            Toggle("Filter Expression", isOn: $showsExpressionFilter).toggleStyle(.checkbox)
                .frame(maxWidth: .infinity, alignment: .trailing).padding(8)
            if showsExpressionFilter { TableExpressionFilterBar(session: expressionFilter, capture: filterCapture) }
            Table(visibleRows) {
                TableColumnForEach(columns) { column in
                    TableColumn(column.titleIsUserData == true ? column.title : L10n.text(column.title)) { (row: EditorRow) in
                        TableCell(column: column, rowID: row.id, tableID: tableID, session: editor, store: store)
                    }.width(min: 60, ideal: column.width ?? 140)
                }
            }.overlay {
                if columns.isEmpty { ContentUnavailableView("No raster bands loaded", systemImage: "tablecells") }
            }.frame(minHeight: 180)
        }
    }
}

struct FileAttachmentContent: View {
    @ObservedObject var store: WorkspaceStore
    let kind: ToolKind
    @ObservedObject var state: DataToolSession
    @ObservedObject var editor: ModelEditorSession
    var body: some View {
        VStack(spacing: 0) {
            DataFileList(state: state, store: store, changed: {
                if kind == .initialConditions, let file = state.inputFiles.first { editor.set("AttachInitialConditionsDialog/_vm_Filename", file.path) }
            }, multiple: false)
            Form {
                if kind == .coreImport {
                    Section("File Details") {
                        detail("Filename", "CoreLayer_Filename"); detail("Name", "CoreLayer_Name")
                        detail("Size", "PrettyFileSize"); detail("Description", "CoreLayer_Description")
                    }
                } else {
                    Section("Initial Conditions") {
                        DataToolField(schema: "AttachInitialConditionsDialog", id: "_vm_Filename", editor: editor, store: store)
                        DataToolField(schema: "AttachInitialConditionsDialog", id: "_vm_Timestamp", editor: editor, store: store)
                    }
                }
            }.formStyle(.grouped)
        }
    }
    private func detail(_ title: String, _ id: String) -> some View {
        LabeledContent(LocalizedStringKey(title), value: editor.fields["CoreLayerImportDialog/" + id] ?? "—").textSelection(.enabled)
    }
}
