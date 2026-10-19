import Foundation
import SwiftUI
import RASWorkspaceCore

// BackupCatalogSummary.xaml: native name/file/date summary and the original
// Save as New Geometry button. The source provider owns unique filename
// creation, copying and the returned selection of the new geometry.
struct BackupCatalogSummary: View {
    let node: LayerTreeNode
    let summary: BackupCatalogSummaryData
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var session: LayerTreeSession
    var body: some View {
        Label(node.name, systemImage: "clock.arrow.circlepath").font(.headline).textSelection(.enabled)
        CatalogFilePath(title: "Filename", path: summary.filename, store: store)
        LabeledContent("Date Created", value: summary.dateCreated.isEmpty ? "—" : summary.dateCreated).textSelection(.enabled)
        LabeledContent("Date Last Modified", value: summary.dateLastModified.isEmpty ? "—" : summary.dateLastModified).textSelection(.enabled)
        Button {
            Task {
                guard let restoredPath = await session.saveBackupAsNewGeometry(node.id) else { return }
                store.refreshAssets()
                let canonicalPath = SourceFilePaths.canonical(URL(fileURLWithPath: restoredPath))
                guard let asset = store.assets.first(where: {
                    $0.section == .geometries && SourceFilePaths.canonical($0.url) == canonicalPath
                }) else {
                    store.errorMessage = L10n.text("The restored Geometry could not be found in the project catalog.")
                    return
                }
                store.select(asset, clearTreeSelection: false)
            }
        } label: { Label("Save as New Geometry", systemImage: "arrow.clockwise") }
            .buttonStyle(.bordered)
            .disabled(session.busy || !summary.canSaveAsNewGeometry || store.isRunningProjectTool ||
                store.isSavingAll || store.isOpeningProject || store.isClosingTab)
        if session.busy { ProgressView().controlSize(.small) }
    }
}
