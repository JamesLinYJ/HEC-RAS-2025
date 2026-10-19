import SwiftUI

// PlanExporterControl, RgbTiffExporterControl and DepthShapeExporter retain
// their distinct destination, settings, preview and progress arrangements.
struct ExportToolContent: View {
    @ObservedObject var store: WorkspaceStore
    let kind: ToolKind
    @ObservedObject var state: DataToolSession
    @ObservedObject var editor: ModelEditorSession
    let current: Bool
    private var schema: String { kind == .planExport ? "PlanExporterControl" : kind == .rasterExport ? "RgbTiffExporterControl" : "DepthShapeExporter" }
    private var outputField: String { schema + (kind == .depthExport ? "/ShapefileVm_ShapefileName" : "/OutputPath") }
    private var zipped: Bool { editor.fields["PlanExporterControl/ExportTypeIndex"] != "1" }
    private var selectedPlan: String { editor.fields["PlanExporterControl/Plan"] ?? "" }
    var body: some View {
        if kind == .planExport { planForm }
        else {
            HSplitView {
                Form {
                    Section("Export Destination") { destination }
                    Section("Export Options") {
                        if kind == .rasterExport {
                            Picker("Region", selection: text("RgbTiffExporterControl/RegionIndex", fallback: "0")) {
                                Text("Current View").tag("0"); Text("Full Layer Extent").tag("1")
                            }
                            field("CellSize")
                            LabeledContent("Output Dimensions", value: editor.fields["RgbTiffExporterControl/DimensionsText"] ?? "—")
                            LabeledContent("Estimated File Size", value: editor.fields["RgbTiffExporterControl/EstimatedSizeText"] ?? "—")
                        } else {
                            field("CellSize"); field("SimplifyDistance"); field("ShowPreview")
                        }
                    }
                }.formStyle(.grouped).frame(minWidth: 290, idealWidth: 350, maxWidth: 470)
                DataToolPreviewView(preview: state.presentation.preview, loading: state.preparing, isCurrent: current)
                    .frame(minWidth: 350, minHeight: 350)
            }
        }
    }
    private var planForm: some View {
        Form {
            Section("Plan") {
                Picker("Plan", selection: Binding(get: { selectedPlan }, set: { value in
                    editor.set("PlanExporterControl/Plan", value); clearDestination()
                })) {
                    Text("None").tag("")
                    ForEach(editor.choiceOptions["PlanExporterControl/Plan"] ?? []) { choice in Text(choice.title).tag(choice.id) }
                }
                if store.hasUnsavedModelEdits {
                    Text("Save model edits before exporting. Unsaved project associations are included.").foregroundStyle(.orange)
                    Button("Save Model Changes") { Task { _ = await store.saveModelEditsOnly() } }.disabled(store.isSavingAll || state.busy)
                }
            }
            Section("Export Destination") {
                Picker("Export Type", selection: text("PlanExporterControl/ExportTypeIndex", fallback: "0")) {
                    Text("ZIP file").tag("0"); Text("Directory").tag("1")
                }.onChange(of: zipped) { _, _ in clearDestination() }
                destination
            }
            Section("Export Options") {
                field("ClipRasters"); field("EnableResample")
                if editor.fields["PlanExporterControl/EnableResample"] == "true" { field("ResampleCellsize") }
                Picker("External Connections", selection: text("PlanExporterControl/ExternalConnectionIndex", fallback: "0")) {
                    Text("Reference by absolute path").tag("0"); Text("Copy to project").tag("1")
                }
            }
            Section("Model Repository Upload") {
                field("EnableUpload").disabled(!zipped || !state.presentation.uploadAvailable)
                if !zipped {
                    Text(L10n.text("Model repository upload requires a ZIP export."))
                        .font(.caption).foregroundStyle(.secondary)
                } else if !state.presentation.uploadAvailable {
                    Text(L10n.text("Configure and authenticate developer S3 credentials in Settings before uploading a plan ZIP."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if zipped && editor.fields["PlanExporterControl/EnableUpload"] == "true" {
                    field("ModelId")
                    Text(L10n.text("Enter a model ID before uploading the plan ZIP."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let source = state.presentation.planExport {
                if let message = source.validationMessage { Section { Text(message).textSelection(.enabled).foregroundStyle(.orange) } }
                Section("Included Source Files") {
                    DisclosureGroup(L10n.format("%d files", source.sourceFiles.count)) {
                        ForEach(source.sourceFiles, id: \.path) { file in Text(file.path).font(.caption).textSelection(.enabled) }
                    }
                    if !source.requiredConnections.isEmpty {
                        LabeledContent("External Connections", value: source.requiredConnections.joined(separator: ", "))
                    }
                }
            }
        }.formStyle(.grouped)
    }
    private var destination: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent(kind == .planExport && !zipped ? "Output Location" : "Output File") {
                Text(selectedDestination?.path ?? "—")
                    .textSelection(.enabled).lineLimit(3).frame(maxWidth: .infinity, alignment: .trailing)
            }
            HStack {
                Spacer()
                Button("Browse…", action: chooseDestination)
                Button("Open Containing Folder") {
                    if let url = selectedDestination { store.system.reveal(url) }
                }.disabled(selectedDestination == nil)
            }
        }
    }
    private var selectedDestination: URL? {
        if kind == .planExport { return state.destination }
        if let url = state.destination { return url }
        guard let value = editor.fields[outputField], !value.isEmpty else { return nil }
        return URL(fileURLWithPath: value)
    }
    private func chooseDestination() {
        let existing = selectedDestination?.lastPathComponent
        let value: URL?
        if kind == .planExport && !zipped {
            let planName = (editor.choiceOptions["PlanExporterControl/Plan"] ?? []).first { $0.id == selectedPlan }?.title ?? "Export"
            value = store.system.chooseExportDestination(name: existing ?? planName + ".export", extensions: [], title: "Export Folder")
        }
        else {
            let ext = kind == .planExport ? "zip" : kind == .rasterExport ? "tif" : "shp"
            value = store.system.chooseExportDestination(name: existing ?? "Export." + ext,
                extensions: kind == .rasterExport ? ["tif", "tiff"] : [ext], title: kind.localizedTitle)
        }
        if let value {
            state.destination = value; editor.set(outputField, value.path)
            state.destinationMayReplace = kind == .planExport && zipped && FileManager.default.fileExists(atPath: value.path)
        }
    }
    private func clearDestination() { state.destination = nil; state.destinationMayReplace = false }
    private func text(_ key: String, fallback: String) -> Binding<String> {
        Binding(get: { editor.fields[key] ?? fallback }, set: { editor.set(key, $0) })
    }
    private func field(_ id: String) -> some View { DataToolField(schema: schema, id: id, editor: editor, store: store) }
}
