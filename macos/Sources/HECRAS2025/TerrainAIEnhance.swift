import Foundation
import RASWorkspaceCore
import SwiftUI

struct TerrainAIEnhanceControl: Encodable, Sendable {
    let type: String
    static let cancel = Self(type: "cancel")
}

struct TerrainAIEnhanceData: Decodable, Sendable {
    let state: String
    let outputPath: String?
    let cleanupToken: String?
    let assetPath: String
    let projectPath: String
    let sourceRevision: String
    let inputId: String?
    let extent: TerrainUSGSQueryExtent
    let mapID: String
    let mapWorkflowIdentity: String
    let outputRevision: String?
    let diagnostic: String?
}

private struct TerrainAIEnhanceRequest: Encodable, Sendable {
    let model: BackendModelProvider.ModelSaveRequest
    let mapExtent: TerrainUSGSQueryExtent
    let mapID: String
    let mapWorkflowIdentity: String
}

/// The user action captures one exact open map. Later tab/map activation
/// changes do not redirect this operation to a different map.
@MainActor
struct TerrainAIEnhanceCapture: Identifiable {
    let id = UUID()
    let editor: TerrainRasterExportCapture
    let editorIdentity: String
    let mapID: UUID
    let mapState: MapState
    let mapWorkflowIdentity: String
    let projectSessionID: UUID
    let projectPath: String
    let extent: TerrainUSGSQueryExtent

    static func make(session: ModelEditorSession, store: WorkspaceStore) -> Self? {
        guard session.canEdit, !session.isBusy, !session.loadingSelection,
              let editor = session.captureTerrainRasterExportContext(),
              let backend = store.modelProvider as? BackendModelProvider,
              let projectPath = backend.project?.url?.path, !projectPath.isEmpty else { return nil }

        // Capture lastActiveMapID exactly once, at the user's action.
        let mapID = store.lastActiveMapID
        guard let mapState = store.existingMapState(for: mapID),
              let viewport = mapState.currentExtent else { return nil }
        let extent = TerrainUSGSQueryExtent(viewport)
        guard extent.isFiniteAndOrdered else { return nil }
        return Self(editor: editor, editorIdentity: session.terrainInputImportIdentity,
            mapID: mapID, mapState: mapState,
            mapWorkflowIdentity: store.mapSourceWorkflowIdentity(mapID),
            projectSessionID: store.projectSessionID,
            projectPath: SourceFilePaths.canonical(URL(fileURLWithPath: projectPath)), extent: extent)
    }

    func isCurrent(session: ModelEditorSession, store: WorkspaceStore) -> Bool {
        guard store.projectSessionID == projectSessionID,
              store.assets.contains(where: { $0.id == editor.asset.id }),
              store.existingMapState(for: mapID) === mapState,
              store.mapSourceWorkflowIdentity(mapID) == mapWorkflowIdentity,
              mapState.currentExtent.map(TerrainUSGSQueryExtent.init) == extent,
              session.terrainInputImportIdentity == editorIdentity,
              session.isCurrentTerrainRasterExportContext(editor) else { return false }
        return true
    }

    var selectedInputID: String? {
        guard let value = editor.edits.fields[TerrainEditorContract.sourceField], !value.isEmpty else { return nil }
        return value
    }

}

@MainActor
extension BackendModelProvider {
    func startTerrainAIEnhance(capture: TerrainAIEnhanceCapture)
        throws -> BackendDuplexOperation<TerrainAIEnhanceControl, BackendProgressUpdate, TerrainAIEnhanceData> {
        guard capture.editor.asset.section == .terrains,
              capture.editor.edits.sourceRevision?.isEmpty == false,
              capture.extent.isFiniteAndOrdered,
              capture.mapWorkflowIdentity.isEmpty == false,
              let projectURL = project?.url,
              canonicalPath(projectURL.path) == capture.projectPath else {
            throw BackendServiceError(code: "invalidInput", message: "The captured terrain enhancement request is no longer available.")
        }
        let request = TerrainAIEnhanceRequest(
            model: try saveRequest(capture.editor.asset, changes: capture.editor.edits),
            mapExtent: capture.extent, mapID: capture.mapID.uuidString,
            mapWorkflowIdentity: capture.mapWorkflowIdentity)
        return try client.startDuplex("model.terrainAIEnhance", parameters: request,
            control: TerrainAIEnhanceControl.self, event: BackendProgressUpdate.self,
            as: TerrainAIEnhanceData.self)
    }

    private func canonicalPath(_ path: String) -> String {
        SourceFilePaths.canonical(URL(fileURLWithPath: path))
    }
}

@MainActor
final class TerrainAIEnhanceWorkflow: ObservableObject {
    @Published private(set) var progress: BackendProgressUpdate?
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published private(set) var isRunning = false
    @Published private(set) var isEnhancing = false
    @Published private(set) var isAppending = false
    @Published private(set) var isCancelling = false

    private let session: ModelEditorSession
    private let store: WorkspaceStore
    private let capture: TerrainAIEnhanceCapture
    private var operation: BackendDuplexOperation<TerrainAIEnhanceControl,
        BackendProgressUpdate, TerrainAIEnhanceData>?
    private var task: Task<Void, Never>?
    private var controlSequence: UInt64 = 0
    private var cleanupEnqueued = false
    private var cancelRequested = false

    init(session: ModelEditorSession, store: WorkspaceStore, capture: TerrainAIEnhanceCapture) {
        self.session = session
        self.store = store
        self.capture = capture
    }

    func start() {
        guard task == nil else { return }
        task = Task { @MainActor in await perform() }
    }

    func cancel() {
        guard isEnhancing, !isCancelling else { return }
        cancelRequested = true
        sendCancelIfPossible()
    }

    private func sendCancelIfPossible() {
        guard cancelRequested, !isCancelling, let operation else { return }
        controlSequence &+= 1
        do {
            try operation.sendControl(.cancel, sequence: controlSequence)
            isCancelling = true
        } catch {
            self.error = L10n.text(error.localizedDescription)
        }
    }

    func invalidateIfStale() {
        if isEnhancing && !capture.isCurrent(session: session, store: store) { cancel() }
    }

    private func perform() async {
        guard !isRunning else { return }
        isRunning = true
        isEnhancing = true
        isCancelling = false
        controlSequence = 0
        cleanupEnqueued = false
        cancelRequested = false
        progress = nil
        error = nil
        notice = nil
        defer {
            operation = nil
            isRunning = false
            isEnhancing = false
            isAppending = false
            isCancelling = false
            task = nil
        }

        guard capture.isCurrent(session: session, store: store),
              let backend = store.modelProvider as? BackendModelProvider else {
            error = L10n.text("The captured map or terrain source changed before enhancement started.")
            return
        }

        var response: TerrainAIEnhanceData?
        do {
            let operation = try backend.startTerrainAIEnhance(capture: capture)
            self.operation = operation
            sendCancelIfPossible()
            for try await update in operation.events {
                progress = update
                invalidateIfStale()
            }
            response = try await operation.value()
            self.operation = nil
            guard let response else { throw ProjectFileError.invalid("The terrain enhancement response is missing.") }
            guard response.state == "completed" else {
                if response.state == "cancelled" {
                    notice = L10n.text("Terrain enhancement was cancelled.")
                    return
                }
                throw ProjectFileError.invalid(response.diagnostic ?? "The terrain enhancement did not complete.")
            }
            if cancelRequested {
                enqueueCleanup(response, backend: backend)
                notice = L10n.text("Terrain enhancement was cancelled.")
                return
            }
            guard capture.isCurrent(session: session, store: store) else {
                enqueueCleanup(response, backend: backend)
                error = L10n.text("The map or terrain source changed during enhancement. No terrain input was added.")
                return
            }

            let transfer = try makeTransfer(response)
            isEnhancing = false
            isAppending = true
            let importIdentity = session.terrainInputImportIdentity
            let inspection = try await session.inspectTerrainInputImport(
                files: [URL(fileURLWithPath: transfer.files[0].filePath)], expectedIdentity: importIdentity)
            guard capture.isCurrent(session: session, store: store),
                  session.terrainInputImportIdentity == importIdentity else {
                enqueueCleanup(response, backend: backend)
                error = L10n.text("The map or terrain source changed before the composite could be staged.")
                return
            }
            guard inspection.sources.count == 1,
                  let source = inspection.sources.first, source.isValid,
                  canonicalPath(source.path) == canonicalPath(transfer.files[0].filePath),
                  source.revision.caseInsensitiveCompare(transfer.files[0].sourceRevision) == .orderedSame else {
                enqueueCleanup(response, backend: backend)
                throw ProjectFileError.invalid("The generated terrain composite no longer matches its inspected raster.")
            }

            let selection = TerrainInputImportSelection(path: source.path,
                sourceRevision: source.revision, rounding: "None", unitConversion: "None",
                customScaleFactor: nil, sourceID: source.id)
            guard capture.isCurrent(session: session, store: store),
                  session.terrainInputImportIdentity == importIdentity else {
                enqueueCleanup(response, backend: backend)
                error = L10n.text("The map or terrain source changed before the composite could be staged.")
                return
            }
            let appended = await session.appendTerrainInputImport([selection], inspection: inspection,
                stitchTiles: false, expectedIdentity: importIdentity)
            enqueueCleanup(response, backend: backend)
            guard let appended, appended.batchStatus == "Completed",
                  appended.mode == "Individual", appended.operations.count == 1,
                  appended.hasStagedOutputs, !appended.hasPendingOperations,
                  appended.failedOperations.isEmpty else {
                let diagnostic = appended?.operations.compactMap(\.diagnostic).first
                    ?? session.error
                    ?? "The composite was not added to the terrain draft."
                error = L10n.text(diagnostic)
                return
            }
            notice = L10n.text("The composite was added to the terrain draft. Save the Terrain editor to write it to the project.")
        } catch {
            if let response, response.state == "completed" {
                enqueueCleanup(response, backend: backend)
            }
            self.error = L10n.text(error.localizedDescription)
        }
    }

    private func makeTransfer(_ response: TerrainAIEnhanceData) throws -> TerrainUSGSDownloadTransfer {
        let expectedRevision = capture.editor.edits.sourceRevision ?? ""
        guard response.state == "completed", let path = response.outputPath,
              let token = response.cleanupToken, token.count == 32, token.allSatisfy(\.isHexDigit),
              let outputRevision = response.outputRevision, outputRevision.count == 64,
              outputRevision.allSatisfy(\.isHexDigit),
              response.sourceRevision.caseInsensitiveCompare(expectedRevision) == .orderedSame,
              canonicalPath(response.assetPath) == canonicalPath(capture.editor.asset.url.path),
              canonicalPath(response.projectPath) == capture.projectPath,
              response.inputId == capture.selectedInputID,
              response.extent == capture.extent,
              response.mapID.caseInsensitiveCompare(capture.mapID.uuidString) == .orderedSame,
              response.mapWorkflowIdentity == capture.mapWorkflowIdentity,
              URL(fileURLWithPath: path).pathExtension.lowercased() == "tif",
              FileManager.default.fileExists(atPath: path),
              ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0) > 0 else {
            throw ProjectFileError.invalid(response.diagnostic ?? "The terrain enhancement output does not match the captured map and Terrain source.")
        }
        let file = TerrainUSGSDownloadedFile(productId: "terrain-ai-enhancement", title: "AI Enhancement",
            filePath: path, sourceRevision: outputRevision, defaultScaleFactor: 1, defaultRounding: "None")
        return TerrainUSGSDownloadTransfer(cleanupToken: token, files: [file],
            assetPath: response.assetPath, projectPath: response.projectPath,
            sourceRevision: response.sourceRevision, inputId: response.inputId,
            extent: response.extent, stitchTiles: false)
    }

    private func enqueueCleanup(_ response: TerrainAIEnhanceData, backend: BackendModelProvider) {
        guard !cleanupEnqueued, let token = response.cleanupToken,
              token.count == 32, token.allSatisfy(\.isHexDigit),
              canonicalPath(response.assetPath) == canonicalPath(capture.editor.asset.url.path),
              response.sourceRevision.caseInsensitiveCompare(capture.editor.edits.sourceRevision ?? "") == .orderedSame,
              canonicalPath(response.projectPath) == capture.projectPath else { return }
        let transfer: TerrainUSGSDownloadTransfer
        if let valid = try? makeTransfer(response) {
            transfer = valid
        } else {
            // Cleanup uses only the service-owned token and captured model
            // paths. No file metadata is fabricated when the response itself
            // is malformed.
            transfer = TerrainUSGSDownloadTransfer(cleanupToken: token, files: [],
                assetPath: response.assetPath, projectPath: response.projectPath,
                sourceRevision: response.sourceRevision, inputId: response.inputId,
                extent: response.extent, stitchTiles: false)
        }
        session.terrainUSGSImportCleanup.enqueue(transfer, provider: backend, after: session)
        cleanupEnqueued = true
    }

    private func canonicalPath(_ path: String) -> String {
        SourceFilePaths.canonical(URL(fileURLWithPath: path))
    }
}

@MainActor
struct TerrainAIEnhanceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    @ObservedObject private var mapState: MapState
    let capture: TerrainAIEnhanceCapture
    @StateObject private var workflow: TerrainAIEnhanceWorkflow

    init(session: ModelEditorSession, store: WorkspaceStore, capture: TerrainAIEnhanceCapture) {
        self.session = session
        self.store = store
        _mapState = ObservedObject(wrappedValue: capture.mapState)
        self.capture = capture
        _workflow = StateObject(wrappedValue: TerrainAIEnhanceWorkflow(
            session: session, store: store, capture: capture))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            titleView
            extentView
            operationView
            noticeView
            errorView
            TerrainUSGSCleanupStatus(cleanup: session.terrainUSGSImportCleanup, editor: session)
            HStack {
                Spacer()
                Button(workflow.isEnhancing ? "Cancel" : "Close") {
                    if workflow.isEnhancing { workflow.cancel() }
                    else { dismiss() }
                }
                .disabled(workflow.isAppending || workflow.isCancelling)
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 600)
        .task { workflow.start() }
        .onChange(of: store.projectSessionID) { _, _ in workflow.invalidateIfStale() }
        .onChange(of: store.mapSourceWorkflowIdentity(capture.mapID)) { _, _ in workflow.invalidateIfStale() }
        .onChange(of: mapExtentIdentity) { _, _ in workflow.invalidateIfStale() }
        .onChange(of: session.terrainInputImportIdentity) { _, _ in workflow.invalidateIfStale() }
        .onDisappear { workflow.cancel() }
        .interactiveDismissDisabled(workflow.isRunning)
    }

    private var titleView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L10n.text("AI Enhance Terrain"), systemImage: "mountain.2.circle")
                .font(.title3.weight(.semibold))
            Text(L10n.text("USGS elevation products will be combined for this captured map extent and added as one editable terrain input."))
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var extentView: some View {
        LabeledContent(L10n.text("Map extent"), value: extentDescription)
            .textSelection(.enabled)
    }

    private var extentDescription: String {
        L10n.format("%g, %g to %g, %g", capture.extent.minX, capture.extent.minY,
            capture.extent.maxX, capture.extent.maxY)
    }

    @ViewBuilder
    private var operationView: some View {
        if workflow.isEnhancing {
            OperationProgressView(title: "Enhancing terrain…", message: progressMessage,
                fraction: workflow.progress?.fraction, cancelling: workflow.isCancelling,
                cancel: progressCancelAction)
        } else if workflow.isAppending {
            ProgressView(L10n.text("Adding the composite to the terrain draft…"))
        }
    }

    private var progressMessage: String {
        if let message = workflow.progress?.message, !message.isEmpty { return L10n.text(message) }
        if let taskName = workflow.progress?.taskName, !taskName.isEmpty { return L10n.text(taskName) }
        return L10n.text("Preparing USGS elevation data…")
    }

    private var progressCancelAction: (() -> Void)? {
        guard !workflow.isCancelling else { return nil }
        return { workflow.cancel() }
    }

    @ViewBuilder
    private var noticeView: some View {
        if let notice = workflow.notice {
            Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var errorView: some View {
        if let error = workflow.error {
            Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }

    private var mapExtentIdentity: String {
        guard let extent = mapState.currentExtent else { return "missing" }
        let value = TerrainUSGSQueryExtent(extent)
        let bitPatterns: [UInt64] = [value.minX.bitPattern, value.minY.bitPattern,
            value.maxX.bitPattern, value.maxY.bitPattern]
        return bitPatterns.map { String($0) }.joined(separator: ":")
    }
}
