import Foundation
import RASWorkspaceCore
import SwiftUI

struct ClassificationImportFile: Codable, Identifiable, Equatable, Sendable {
    let file: String
    let revision: String
    let kind: String
    var column: String?
    var name: String?
    var id: String { file }
}
struct ClassificationImportItem: Decodable, Identifiable, Sendable {
    let selection: ClassificationImportFile
    let columns: [String]
    let featureCount: Int
    let previewFeatureCount: Int
    let geoJson: String?
    let raster: SpatialGridPreview?
    let rows: Int
    let columnsCount: Int
    let bands: Int
    var id: String { selection.file }
    func preview() throws -> DataToolPreview {
        if let raster { return try raster.presentation(name: URL(fileURLWithPath: id).lastPathComponent) }
        if let geoJson {
            let layer = try MapVectorLayer(data: Data(geoJson.utf8), sourceURL: URL(fileURLWithPath: id))
            return .init(vectors: [.init(layer: layer, lineColor: "#007AFF", fillColor: "#4080FF55", lineWidth: 1)])
        }
        return .init()
    }
}
struct ClassificationImportInspection: Decodable, Sendable {
    let items: [ClassificationImportItem]
    let projection: String
}

struct ClassificationImportSheet: View {
    let initialFiles: [URL]
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var files: [URL] = []
    @State private var selections: [ClassificationImportFile] = []
    @State private var inspection: ClassificationImportInspection?
    @State private var selectedID: String?
    @State private var prepared: Data?
    @State private var preparing = false
    @State private var error: String?
    @State private var requestID = UUID()
    @State private var work: Task<Void, Never>?
    private var selected: ClassificationImportItem? { inspection?.items.first { $0.id == selectedID } }
    private var signature: Data? {
        struct Inputs: Encodable { let files: [String]; let selections: [ClassificationImportFile] }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(Inputs(files: files.map(\.path), selections: selections))
    }
    private var valid: Bool {
        session.provider != nil && session.canEdit && !preparing && !session.isBusy &&
            !selections.isEmpty && prepared != nil && prepared == signature
    }
    private var preview: DataToolPreview { (try? selected?.preview()) ?? .init() }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Import Classification Inputs", systemImage: "square.3.layers.3d").font(.title2.weight(.semibold))
                Spacer()
                Button("Cancel", role: .cancel) { work?.cancel(); dismiss() }.disabled(session.isSaving)
                Button("Import and Save Model") {
                    work = Task { if await session.importClassification(selections) { dismiss() } }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!valid)
            }.padding(16)
            Text("Import saves this classification model’s current edits together with the selected inputs.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.bottom, 12)
            Divider()
            HSplitView {
                VStack(spacing: 0) {
                    HStack {
                        Button("Add Files…") { add(store.system.chooseInputFiles()) }
                        Button("Remove") {
                            guard let selectedID else { return }
                            files.removeAll { $0.path == selectedID }; selections.removeAll { $0.id == selectedID }
                            self.selectedID = nil; prepared = nil; reload()
                        }.disabled(selectedID == nil)
                        Spacer()
                        Button("Check Inputs", action: reload).disabled(files.isEmpty || preparing || session.provider == nil)
                    }.padding(12)
                    List(files, id: \.path, selection: $selectedID) { file in
                        Label(file.lastPathComponent, systemImage: file.pathExtension.lowercased() == "shp" ? "point.topleft.down.to.point.bottomright.curvepath" : "square.grid.3x3").tag(file.path)
                    }.frame(minHeight: 150)
                    Form {
                        if let selected, let index = selections.firstIndex(where: { $0.id == selected.id }) {
                            Section("Import Settings") {
                                if selected.selection.kind == "Raster" {
                                    TextField("Name", text: Binding(get: { selections[index].name ?? "" }, set: { selections[index].name = $0 }))
                                    LabeledContent("Raster Size", value: "\(selected.columnsCount) × \(selected.rows)")
                                    Text("Classification import uses the source raster’s first band and discrete integer conversion.").font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Picker("Classification Column", selection: Binding(get: { selections[index].column ?? "" }, set: { selections[index].column = $0 })) {
                                        Text("None").tag("")
                                        ForEach(selected.columns, id: \.self) { Text($0).tag($0) }
                                    }
                                    LabeledContent("Polygons", value: String(selected.featureCount))
                                    if selected.previewFeatureCount < selected.featureCount {
                                        Text(L10n.format("Preview displays %d of %d polygons.", selected.previewFeatureCount, selected.featureCount)).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }.formStyle(.grouped).frame(minHeight: 200, maxHeight: 300)
                    if let error = error ?? session.error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled).padding(12)
                    } else if session.provider == nil {
                        Label("The original model adapter for this tool is unavailable.", systemImage: "externaldrive.badge.questionmark")
                            .font(.caption).foregroundStyle(.secondary).padding(12)
                    } else if prepared != signature {
                        Text("Check inputs after changing import settings.").font(.caption).foregroundStyle(.secondary).padding(12)
                    }
                }.frame(minWidth: 320, idealWidth: 380, maxWidth: 500)
                    .disabled(preparing || session.isSaving)
                DataToolPreviewView(preview: preview, loading: preparing, isCurrent: prepared == signature)
            }
        }.frame(minWidth: 980, idealWidth: 1080, minHeight: 660)
            .interactiveDismissDisabled(session.isSaving)
            .onAppear { add(initialFiles) }
            .onDisappear { requestID = UUID(); if !session.isSaving { work?.cancel() } }
    }
    private func add(_ urls: [URL]) {
        guard !urls.isEmpty, store.system.authorizeExternalFolders(Array(Set(urls.map { $0.deletingLastPathComponent() }))) else { return }
        for file in urls where !files.contains(file) { files.append(file) }
        reload()
    }
    private func reload() {
        work?.cancel(); let token = UUID(); requestID = token
        guard !files.isEmpty, session.provider != nil else { inspection = nil; selections = []; prepared = nil; preparing = false; return }
        preparing = true; error = nil; prepared = nil
        work = Task {
            do {
                let result = try await session.inspectClassification(files: files, selections: selections)
                guard !Task.isCancelled, requestID == token else { return }
                inspection = result; selections = result.items.map(\.selection)
                if !result.items.contains(where: { $0.id == selectedID }) { selectedID = result.items.first?.id }
                prepared = signature
            } catch {
                guard !Task.isCancelled, requestID == token else { return }
                self.error = L10n.text(error.localizedDescription)
            }
            if requestID == token { preparing = false }
        }
    }
}
