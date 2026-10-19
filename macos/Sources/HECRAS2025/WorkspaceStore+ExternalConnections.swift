import Foundation
import RASWorkspaceCore

@MainActor
extension WorkspaceStore {
    func renameExternalConnection(_ expected: ProjectConnection, to newName: String, projectID: UUID) throws {
        guard projectID == self.projectSessionID, !isOpeningProject, !isSavingAll,
              !isClosingTab, !isRunningProjectTool, let document else {
            throw ProjectFileError.invalid("The project is busy or has changed. Reopen the connection before renaming it.")
        }
        guard newName != expected.name else { return }
        try document.renameConnection(expected, to: newName)
        guard markExternalConnectionRenamed(projectID: projectID) else {
            if let renamed = document.connections.first(where: { $0.id == expected.id }) {
                try? document.renameConnection(renamed, to: expected.name)
            }
            throw ProjectFileError.invalid("The project changed before the connection rename could be applied.")
        }
    }

    @discardableResult
    func removeExternalConnectionAfterConfirmation(_ expected: ProjectConnection, projectID: UUID) -> Bool {
        guard projectID == self.projectSessionID else { return false }
        guard !isOpeningProject, !isSavingAll, !isClosingTab, !isRunningProjectTool else {
            errorMessage = L10n.text("Wait for the current operation to finish before removing a connection.")
            return false
        }
        guard let document else {
            errorMessage = L10n.text("The selected external connection no longer exists.")
            return false
        }
        guard document.connections.first(where: { $0.id == expected.id }) == expected else {
            errorMessage = L10n.text("The selected external connection no longer exists.")
            return false
        }
        removeConnection(expected)
        return true
    }
}
