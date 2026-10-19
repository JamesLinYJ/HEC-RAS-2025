import Foundation
import RASWorkspaceCore
import SwiftUI

struct TerrainRasterExportCapture: Sendable {
    let id: String
    let editorID: UUID
    let asset: ProjectAsset
    let edits: EditorEdits
}

struct TerrainRasterExportControl: Encodable, Sendable {
    let type: String
    static let cancel = Self(type: "cancel")
}

struct TerrainRasterExportResult: Decodable, Sendable {
    let state: String
    let outputPath: String?
    let sourcePath: String
    let sourceRevision: String
    let cleanupWarning: String?
}

@MainActor
extension BackendModelProvider {
    func startTerrainRasterExport(
        capture: TerrainRasterExportCapture,
        cellSize: Double
    ) throws -> BackendDuplexOperation<TerrainRasterExportControl, BackendProgressUpdate, TerrainRasterExportResult> {
        guard capture.asset.section == .terrains,
              capture.edits.sourceRevision?.isEmpty == false,
              project?.url != nil,
              cellSize.isFinite, cellSize > 0 else {
            throw BackendServiceError(code: "invalidInput", message: "The selected Terrain export request is incomplete.")
        }
        struct Request: Encodable, Sendable {
            let model: ModelSaveRequest
            let cellSize: Double
        }
        let model = try saveRequest(capture.asset, changes: capture.edits)
        let request = Request(model: model, cellSize: cellSize)
        return try client.startDuplex("terrain.raster.export", parameters: request,
            control: TerrainRasterExportControl.self, event: BackendProgressUpdate.self,
            as: TerrainRasterExportResult.self)
    }
}

@MainActor
final class TerrainRasterExportSession: ObservableObject {
    @Published private(set) var progress: BackendProgressUpdate?
    @Published private(set) var result: TerrainRasterExportResult?
    @Published private(set) var error: String?
    @Published private(set) var isRunning = false
    @Published private(set) var isCancelling = false

    private var operation: BackendDuplexOperation<TerrainRasterExportControl,
        BackendProgressUpdate, TerrainRasterExportResult>?
    private var controlSequence: UInt64 = 0

    func export(using provider: BackendModelProvider, capture: TerrainRasterExportCapture,
                cellSize: Double) async {
        guard !isRunning else { return }
        isRunning = true
        progress = nil
        result = nil
        error = nil
        isCancelling = false
        controlSequence = 0
        defer {
            operation = nil
            isRunning = false
            isCancelling = false
        }
        do {
            let operation = try provider.startTerrainRasterExport(capture: capture, cellSize: cellSize)
            self.operation = operation
            for try await update in operation.events {
                progress = update
            }
            result = try await operation.value()
        } catch {
            self.error = L10n.text(error.localizedDescription)
        }
    }

    func cancel() {
        guard isRunning, !isCancelling, let operation else { return }
        controlSequence &+= 1
        do {
            try operation.sendControl(.cancel, sequence: controlSequence)
            isCancelling = true
        } catch {
            self.error = L10n.text(error.localizedDescription)
        }
    }

    func presentFailure(_ message: String) {
        error = L10n.text(message)
    }
}

struct TerrainRasterExportSheet: View {
    @ObservedObject var store: WorkspaceStore
    let asset: ProjectAsset
    let catalogNode: LayerTreeNode

    @Environment(\.dismiss) private var dismiss
    @State private var editor: ModelEditorSession?
    @StateObject private var workflow = TerrainRasterExportSession()
    @State private var capture: TerrainRasterExportCapture?
    @State private var projectSessionID: UUID
    @State private var registeredEditor = false
    @State private var isPreparing = true
    @State private var validationMessage: String?
    @State private var cleanupAfterRun = false

    init(store: WorkspaceStore, asset: ProjectAsset, catalogNode: LayerTreeNode) {
        self.store = store
        self.asset = asset
        self.catalogNode = catalogNode
        _projectSessionID = State(initialValue: store.projectSessionID)
    }

    var body: some View {
        Group {
            if let editor, let capture {
                TerrainRasterExportForm(store: store, asset: asset, editor: editor,
                    capture: capture, projectSessionID: projectSessionID, workflow: workflow,
                    onFinished: unregisterOwnedEditor)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Label("Export Raster", systemImage: "square.and.arrow.up.on.square")
                        .font(.title3.weight(.semibold))
                    if isPreparing {
                        ProgressView("Loading Terrain source…")
                    } else {
                        Text(L10n.text(validationMessage ?? "The selected Terrain could not be loaded for export."))
                            .foregroundStyle(.red).textSelection(.enabled)
                        HStack {
                            Spacer()
                            Button("Close", role: .cancel) { dismiss() }
                        }
                    }
                }
                .padding(22)
                .frame(minWidth: 440, idealWidth: 500)
            }
        }
        .task { await prepareSource() }
        .interactiveDismissDisabled(workflow.isRunning)
        .onChange(of: store.projectSessionID) { _, newValue in
            guard newValue != projectSessionID else { return }
            workflow.cancel()
        }
        .onChange(of: workflow.isRunning) { _, running in
            if !running, cleanupAfterRun { unregisterOwnedEditor() }
        }
        .onDisappear {
            if workflow.isRunning {
                cleanupAfterRun = true
                workflow.cancel()
            } else {
                unregisterOwnedEditor()
            }
        }
    }

    @MainActor
    private func prepareSource() async {
        guard editor == nil, store.projectSessionID == projectSessionID,
              asset.section == .terrains,
              store.assets.contains(asset), catalogNode.sourceClass == "ObservableTerrain",
              catalogNode.assetID == asset.id else {
            isPreparing = false
            validationMessage = "The selected Terrain source is no longer available."
            return
        }
        do {
            let selected: ModelEditorSession
            if let existing = try store.terrainRasterExportEditor(for: asset) {
                selected = existing
            } else {
                selected = ModelEditorSession(provider: store.modelProvider)
                store.registerEditor(selected)
                registeredEditor = true
                await selected.load(asset, kind: .terrain)
            }
            guard store.projectSessionID == projectSessionID,
                  store.assets.contains(asset), selected.modelAssetID == asset.id,
                  selected.loaded, !selected.isBusy,
                  let capture = selected.captureTerrainRasterExportContext() else {
                self.editor = selected
                isPreparing = false
                validationMessage = selected.error ?? "Wait for the selected Terrain editor to finish loading before export."
                unregisterOwnedEditor()
                return
            }
            editor = selected
            self.capture = capture
            isPreparing = false
        } catch {
            isPreparing = false
            validationMessage = error.localizedDescription
        }
    }

    @MainActor
    private func unregisterOwnedEditor() {
        if registeredEditor {
            if let editor { store.unregisterEditor(editor) }
            registeredEditor = false
        }
    }
}

private struct TerrainRasterExportForm: View {
    @ObservedObject var store: WorkspaceStore
    let asset: ProjectAsset
    @ObservedObject var editor: ModelEditorSession
    let capture: TerrainRasterExportCapture
    let projectSessionID: UUID
    @ObservedObject var workflow: TerrainRasterExportSession
    let onFinished: @MainActor () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var cellSize = "5"
    @State private var validationMessage: String?
    @State private var leaseID: UUID?

    private var backend: BackendModelProvider? { store.modelProvider as? BackendModelProvider }
    private var parsedCellSize: Double? {
        let formatter = NumberFormatter()
        formatter.locale = store.interfaceLocale
        formatter.numberStyle = .decimal
        guard let number = formatter.number(from: cellSize) else { return nil }
        let value = number.doubleValue
        return value.isFinite && value > 0 ? value : nil
    }
    private var completedOutput: URL? {
        guard let result = workflow.result, result.state == "completed",
              result.sourceRevision.caseInsensitiveCompare(capture.edits.sourceRevision ?? "") == .orderedSame,
              SourceFilePaths.canonical(URL(fileURLWithPath: result.sourcePath))
                == SourceFilePaths.canonical(asset.url),
              let path = result.outputPath, !path.isEmpty,
              URL(fileURLWithPath: path).pathExtension.lowercased() == "tif",
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Export Raster", systemImage: "square.and.arrow.up.on.square")
                .font(.title3.weight(.semibold))
            Text(L10n.text("Exports the selected Terrain as a single-band TIFF raster."))
                .foregroundStyle(.secondary)
            LabeledContent("Terrain", value: asset.name)
            TextField("Cell Size?", text: $cellSize)
                .disabled(workflow.isRunning)
            if let validationMessage {
                Text(L10n.text(validationMessage)).foregroundStyle(.red)
            }
            if workflow.isRunning {
                OperationProgressView(title: "Exporting terrain raster…",
                    message: L10n.text(workflow.progress?.message
                        ?? workflow.progress?.taskName ?? "Preparing raster export…"),
                    fraction: workflow.progress?.fraction,
                    cancelling: workflow.isCancelling,
                    cancel: workflow.isCancelling ? nil : { workflow.cancel() })
            }
            if let error = workflow.error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            if let warning = workflow.result?.cleanupWarning {
                Text(L10n.text(warning)).foregroundStyle(.orange).textSelection(.enabled)
            }
            if let output = completedOutput {
                LabeledContent("Exported TIFF", value: output.path).textSelection(.enabled)
                Button("Reveal in Finder") { store.system.reveal(output) }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    if workflow.isRunning { workflow.cancel() }
                    else { dismiss() }
                }
                .disabled(workflow.isCancelling)
                Button("Export") { Task { await startExport() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(workflow.isRunning || parsedCellSize == nil || backend == nil)
                if !workflow.isRunning && workflow.result != nil {
                    Button("Done") { dismiss() }
                }
            }
        }
        .padding(22)
        .frame(minWidth: 440, idealWidth: 500)
        .onChange(of: workflow.result?.state) { _, state in
            guard state == "completed", let output = completedOutput,
                  store.projectSessionID == projectSessionID,
                  editor.isCurrentTerrainRasterExportContext(capture) else { return }
            store.system.reveal(output)
        }
        .onDisappear {
            if workflow.isRunning { workflow.cancel() }
            else { releaseLease() }
        }
    }

    @MainActor
    private func startExport() async {
        guard let backend, let cellSize = parsedCellSize else {
            validationMessage = "The cell size must be a positive finite number."
            return
        }
        guard store.projectSessionID == projectSessionID,
              store.assets.contains(asset), editor.isCurrentTerrainRasterExportContext(capture),
              SourceFilePaths.canonical(capture.asset.url) == SourceFilePaths.canonical(asset.url),
              let lease = store.beginTerrainRasterExport(
                projectSessionID: projectSessionID, captureID: capture.id) else {
            validationMessage = "The selected Terrain changed or another project operation is running."
            return
        }
        leaseID = lease
        await workflow.export(using: backend, capture: capture, cellSize: cellSize)
        releaseLease()
        onFinished()
        if let result = workflow.result, result.state == "cancelled", result.cleanupWarning == nil {
            validationMessage = "The terrain raster export was cancelled."
        } else if workflow.result?.state == "completed", completedOutput == nil {
            workflow.presentFailure("The export did not return a readable TIFF for the captured source revision.")
        }
    }

    @MainActor
    private func releaseLease() {
        guard let leaseID else { return }
        store.endTerrainRasterExport(leaseID)
        self.leaseID = nil
    }
}

struct CatalogTerrainRasterExportPresentation: Identifiable {
    let asset: ProjectAsset
    let node: LayerTreeNode
    var id: String { node.id }
}
