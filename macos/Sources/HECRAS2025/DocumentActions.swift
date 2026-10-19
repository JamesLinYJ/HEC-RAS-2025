import SwiftUI

struct WorkspaceDocumentActions {
    let canCloseTab: Bool
    let closeTab: () -> Void
    var openDocument: (() -> Void)? = nil
    var saveDocument: (() -> Void)? = nil
    var canSaveDocument: Bool? = nil
    var documentSaveTitle: String? = nil
}
private struct WorkspaceDocumentActionsKey: FocusedValueKey {
    typealias Value = WorkspaceDocumentActions
}
extension FocusedValues {
    var workspaceDocumentActions: WorkspaceDocumentActions? {
        get { self[WorkspaceDocumentActionsKey.self] }
        set { self[WorkspaceDocumentActionsKey.self] = newValue }
    }
}
