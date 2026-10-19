import SwiftUI

/// The exact editor owns the model draft; the Store retains its operation
/// session so closing a sheet cannot discard an unresolved paired-file write.
@MainActor
struct BoundaryInitialConditionsEditorSheet: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var editor: ModelEditorSession
    let onReady: @MainActor () -> Void
    let onClose: @MainActor () -> Void
    @State private var workflow: BoundaryInitialConditionsSession?
    @State private var failure: String?

    var body: some View {
        Group {
            if let workflow {
                BoundaryInitialConditionsWorkspace(session: workflow,
                    chooseResult: { store.system.chooseInitialConditionsResult() }, onClose: onClose)
            } else {
                ContentUnavailableView {
                    Label(L10n.text("Attach Initial Conditions"), systemImage: "externaldrive.badge.questionmark")
                } description: {
                    Text(failure ?? L10n.text("Preparing the selected boundary condition…"))
                } actions: {
                    Button(L10n.text("Retry"), action: prepare)
                    Button(L10n.text("Close"), action: onClose)
                }
                .frame(minWidth: 600, minHeight: 360)
            }
        }
        .task(id: "\(store.projectSessionID.uuidString)|\(editor.modelAssetID ?? "")") { prepare() }
        .onDisappear { workflow?.close() }
    }

    private func prepare() {
        do {
            workflow = try store.boundaryInitialConditionsSession(for: editor)
            failure = nil
            onReady()
        } catch {
            workflow = nil
            failure = L10n.text(error.localizedDescription)
        }
    }
}
