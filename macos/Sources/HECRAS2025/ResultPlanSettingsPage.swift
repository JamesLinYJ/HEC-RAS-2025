import Foundation
import RASWorkspaceCore
import SwiftUI

/// Plan Settings hosted by an exact selected Result. The editor session is a
/// persistent child of the Result ModelEditorSession; page navigation does not
/// discard its pending Description or image additions.
struct ResultPlanSettingsPage: View {
    @ObservedObject var store: WorkspaceStore
    let result: ProjectAsset
    let expectedResultRevision: String
    let projectSessionID: UUID
    let sourceContextID: String
    @StateObject private var session: ResultPlanSettingsEditorSession

    init(store: WorkspaceStore, result: ProjectAsset, expectedResultRevision: String,
         projectSessionID: UUID, sourceContextID: String? = nil,
         session: ResultPlanSettingsEditorSession? = nil) {
        self.store = store
        self.result = result
        self.expectedResultRevision = expectedResultRevision
        self.projectSessionID = projectSessionID
        self.sourceContextID = sourceContextID ?? "\(projectSessionID.uuidString)|\(result.id)"
        _session = StateObject(wrappedValue: session ?? ResultPlanSettingsEditorSession(
            provider: BackendPlanSettingsEmbeddedResultProvider()))
    }

    private var owner: PlanSettingsResultOwner {
        PlanSettingsResultOwner(projectSessionID: projectSessionID,
            resultAssetID: result.id,
            resultPath: SourceFilePaths.canonical(result.url),
            resultRevision: expectedResultRevision,
            sourceContextID: sourceContextID)
    }

    private var capture: PlanSettingsResultCapture? {
        guard projectSessionID == store.projectSessionID,
              result.section == .results, result.isModelFile,
              store.assets.contains(where: {
                  $0.id == result.id && $0.section == .results && $0.isModelFile
                      && SourceFilePaths.canonical($0.url) == SourceFilePaths.canonical(result.url)
              }),
              expectedResultRevision.count == 64,
              let document = store.document, let projectPath = document.url,
              let projectRevision = document.sourceRevision else { return nil }
        let projectXML = document.editorXML(overridingDescription: store.descriptionDraft)
        return PlanSettingsResultCapture(owner: owner, resultName: result.name,
            assetsRevision: store.assetsRevision,
            projectPath: SourceFilePaths.canonical(projectPath),
            projectRevision: projectRevision, projectXML: projectXML)
    }

    private var refreshKey: String {
        capture?.identity ?? "unavailable|\(store.projectSessionID.uuidString)|\(sourceContextID)"
    }

    var body: some View {
        Form {
            ResultPlanSettingsEmbeddedEditorDetails(session: session, capture: capture)
        }
        .formStyle(.grouped)
        .task(id: refreshKey) {
            if let capture { await session.load(capture) }
        }
    }
}
