import Foundation
import RASWorkspaceCore

/// Portable dispatcher for the retained `Action.CrossSection.Edit` resource.
/// The exported C# declares this action ID but does not retain a callable
/// dispatcher, so callers must supply the exact current source selection.
@MainActor
struct ClassicCrossSectionEditActionDispatcher {
    static let actionID = "Action.CrossSection.Edit"

    let windows: ClassicCrossSectionWindows

    init(windows: ClassicCrossSectionWindows = .shared) {
        self.windows = windows
    }

    /// Re-resolves the captured row from its original file revision before
    /// opening the linked window. This keeps menu/action dispatch bound to the
    /// same source row even when selection changes while the read is in flight.
    func dispatch(actionID: String, selection: ClassicCrossSectionSelection?,
                  projectSessionID: UUID, currentProjectSessionID: UUID,
                  provider: any ClassicCrossSectionProvider,
                  selectionIsCurrent: @MainActor () -> Bool) async throws -> ClassicCrossSectionWindowRoute? {
        guard actionID == Self.actionID,
              projectSessionID == currentProjectSessionID,
              let selection, selectionIsCurrent(), Self.hasValidIdentity(selection) else { return nil }

        let captured = selection.profile
        let refreshed = try await provider.profile(scopeID: selection.scopeID,
            source: selection.access.url, revision: captured.sourceRevision,
            contextToken: captured.contextToken, row: captured.row)

        guard !Task.isCancelled, selectionIsCurrent(),
              Self.sameProfileIdentity(refreshed, captured),
              UUID(uuidString: refreshed.scopeID) == selection.scopeID else { return nil }

        let resolved = ClassicCrossSectionSelection(profile: refreshed,
            access: selection.access, scopeID: selection.scopeID)
        return windows.open(projectSessionID: projectSessionID,
            selection: resolved, provider: provider)
    }

    static func isSameSelection(_ current: ClassicCrossSectionSelection?,
                               as captured: ClassicCrossSectionSelection) -> Bool {
        guard let current else { return false }
        return current.scopeID == captured.scopeID
            && current.access === captured.access
            && sameProfileIdentity(current.profile, captured.profile)
    }

    private static func hasValidIdentity(_ selection: ClassicCrossSectionSelection) -> Bool {
        let profile = selection.profile
        return UUID(uuidString: profile.scopeID) == selection.scopeID
            && SourceFilePaths.canonical(selection.access.url) == profile.sourcePath
            && profile.sourceRevision.count == 64
            && profile.contextToken.count == 64
            && profile.row.ordinal >= 0
            && profile.row.rowToken.count == 64
    }

    private static func sameProfileIdentity(_ lhs: ClassicCrossSectionProfile,
                                            _ rhs: ClassicCrossSectionProfile) -> Bool {
        lhs.scopeID == rhs.scopeID
            && lhs.sourcePath == rhs.sourcePath
            && lhs.sourceRevision == rhs.sourceRevision
            && lhs.contextToken == rhs.contextToken
            && lhs.row == rhs.row
    }
}
