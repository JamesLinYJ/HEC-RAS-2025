import Combine
import Foundation
import RASWorkspaceCore
import SwiftUI

struct TerrainInputImportInitialSettings: Sendable {
    let sourceRevision: String
    let scaleFactor: Double
    let rounding: String

    func selection(for source: TerrainInputImportSource) throws -> TerrainInputImportSelection {
        guard source.revision.caseInsensitiveCompare(sourceRevision) == .orderedSame,
              scaleFactor.isFinite, scaleFactor > 0,
              Float(scaleFactor).isFinite, Float(scaleFactor) > 0,
              rounding == "ThirtySeconds" else {
            throw ProjectFileError.invalid("The downloaded USGS source changed. Download it again before importing.")
        }
        return .init(path: source.path, sourceRevision: source.revision, rounding: rounding,
            unitConversion: "Custom", customScaleFactor: scaleFactor, sourceID: source.id)
    }

    func scaleText(locale: Locale) -> String {
        // Preserve the helper's actual scale, including all Float source bits.
        String(format: "%.17G", locale: locale, arguments: [scaleFactor])
    }
}

@MainActor
final class TerrainUSGSImportCleanupSession: ObservableObject {
    private struct Pending {
        let transfer: TerrainUSGSDownloadTransfer
        let provider: BackendModelProvider
    }
    @Published private(set) var warnings: [String: String] = [:]
    @Published private(set) var activeTokens: Set<String> = []
    private var pending: [String: Pending] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    func enqueue(_ transfer: TerrainUSGSDownloadTransfer, provider: BackendModelProvider,
                 after editor: ModelEditorSession) {
        let token = transfer.cleanupToken
        guard tasks[token] == nil else { return }
        pending[token] = Pending(transfer: transfer, provider: provider)
        activeTokens.insert(token)
        tasks[token] = Task {
            // Staging reads the raw TIFFs; never remove them during conversion.
            if editor.isTerrainInputImportRunning {
                for await running in editor.$isTerrainInputImportRunning.values {
                    if !running { break }
                }
            }
            do {
                let result = try await provider.cleanupTerrainUSGS(transfer)
                guard result.removed else {
                    throw ProjectFileError.invalid(result.warning ?? "The temporary USGS terrain files could not be removed.")
                }
                pending.removeValue(forKey: token)
                warnings.removeValue(forKey: token)
            } catch {
                warnings[token] = L10n.text(error.localizedDescription)
            }
            activeTokens.remove(token)
            tasks.removeValue(forKey: token)
        }
    }

    func retry(after editor: ModelEditorSession) {
        for item in Array(pending.values) {
            enqueue(item.transfer, provider: item.provider, after: editor)
        }
    }
}

struct TerrainUSGSCleanupStatus: View {
    @ObservedObject var cleanup: TerrainUSGSImportCleanupSession
    @ObservedObject var editor: ModelEditorSession

    var body: some View {
        if !cleanup.warnings.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(cleanup.warnings.keys.sorted(), id: \.self) { token in
                    Label(cleanup.warnings[token] ?? "", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).textSelection(.enabled)
                }
                Button(L10n.text("Retry Cleanup")) { cleanup.retry(after: editor) }
                    .disabled(!cleanup.activeTokens.isEmpty || editor.isTerrainInputImportRunning)
            }.font(.caption)
        }
    }
}

struct TerrainUSGSImportFlow: View {
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    let hintExtent: ViewportRequest?
    @Environment(\.dismiss) private var dismiss
    @State private var transfer: TerrainUSGSDownloadTransfer?
    @State private var projectSessionID: UUID

    init(session: ModelEditorSession, store: WorkspaceStore, hintExtent: ViewportRequest?) {
        self.session = session
        self.store = store
        self.hintExtent = hintExtent
        _projectSessionID = State(initialValue: store.projectSessionID)
    }

    var body: some View {
        Group {
            if let transfer {
                TerrainInputImportSheet(initialFiles: transfer.files.map(\.fileURL),
                    session: session, store: store,
                    initialSettings: Dictionary(uniqueKeysWithValues: transfer.files.map { file in
                        (file.filePath, TerrainInputImportInitialSettings(sourceRevision: file.sourceRevision,
                            scaleFactor: file.defaultScaleFactor, rounding: file.defaultRounding))
                    }), initialStitchTiles: transfer.stitchTiles,
                    ownedInitialFilePaths: Set(transfer.files.map { $0.fileURL.standardizedFileURL.path }))
            } else {
                VStack(spacing: 0) {
                    TerrainUSGSImportView(session: session, store: store, hintExtent: hintExtent,
                        onDownload: accept)
                    HStack {
                        Spacer()
                        Button("Cancel", role: .cancel) { dismiss() }
                    }.padding(12)
                }.frame(minWidth: 680, idealWidth: 800, minHeight: 420)
            }
        }
        .onChange(of: store.projectSessionID) { _, current in
            if current != projectSessionID { dismiss() }
        }
        .onDisappear {
            if let transfer, let provider = store.modelProvider as? BackendModelProvider {
                session.terrainUSGSImportCleanup.enqueue(transfer, provider: provider, after: session)
            }
        }
    }

    private func accept(_ incoming: TerrainUSGSDownloadTransfer) {
        guard let provider = store.modelProvider as? BackendModelProvider else { return }
        guard store.projectSessionID == projectSessionID, transfer == nil,
              session.modelAssetID.map({ SourceFilePaths.canonical(URL(fileURLWithPath: $0)) })
                == SourceFilePaths.canonical(URL(fileURLWithPath: incoming.assetPath)),
              Set(incoming.files.map(\.filePath)).count == incoming.files.count else {
            session.terrainUSGSImportCleanup.enqueue(incoming, provider: provider, after: session)
            return
        }
        transfer = incoming
    }
}
