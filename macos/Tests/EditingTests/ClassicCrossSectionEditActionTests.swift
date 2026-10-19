import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct ClassicCrossSectionEditActionTests {
    @Test @MainActor
    func editActionRevalidatesAndOpensTheExactSelectedSourceRow() async throws {
        let (selection, provider) = fixture()
        let windows = ClassicCrossSectionWindows()
        let project = UUID()
        let dispatcher = ClassicCrossSectionEditActionDispatcher(windows: windows)

        let route = try #require(try await dispatcher.dispatch(
            actionID: ClassicCrossSectionEditActionDispatcher.actionID,
            selection: selection, projectSessionID: project, currentProjectSessionID: project,
            provider: provider,
            selectionIsCurrent: { ClassicCrossSectionEditActionDispatcher.isSameSelection(selection, as: selection) }))

        #expect(route.projectSessionID == project)
        #expect(windows.sessions[route.id]?.selection?.profile.sourcePath == selection.profile.sourcePath)
        #expect(windows.sessions[route.id]?.selection?.profile.sourceRevision == selection.profile.sourceRevision)
        #expect(windows.sessions[route.id]?.selection?.profile.contextToken == selection.profile.contextToken)
        #expect(windows.sessions[route.id]?.selection?.profile.row == selection.profile.row)
        windows.close(route.id)
    }

    @Test @MainActor
    func editActionDropsAReplyAfterSelectionOrProjectChanges() async throws {
        let (selection, _) = fixture()
        let provider = HeldCrossSectionProfile(selection.profile)
        let windows = ClassicCrossSectionWindows()
        let project = UUID()
        var currentSelection: ClassicCrossSectionSelection? = selection
        var currentProject = project
        let dispatcher = ClassicCrossSectionEditActionDispatcher(windows: windows)
        let operation = Task { @MainActor in
            try await dispatcher.dispatch(actionID: ClassicCrossSectionEditActionDispatcher.actionID,
                selection: selection, projectSessionID: project, currentProjectSessionID: currentProject,
                provider: provider,
                selectionIsCurrent: {
                    currentProject == project
                        && ClassicCrossSectionEditActionDispatcher.isSameSelection(currentSelection, as: selection)
                })
        }

        try await wait { await provider.hasPending }
        currentSelection = nil
        currentProject = UUID()
        await provider.release()

        #expect(try await operation.value == nil)
        #expect(windows.sessions.isEmpty)
    }

    @Test @MainActor
    func unsupportedActionAndMismatchedProjectDoNotOpenAWindow() async throws {
        let (selection, provider) = fixture()
        let windows = ClassicCrossSectionWindows()
        let dispatcher = ClassicCrossSectionEditActionDispatcher(windows: windows)
        let project = UUID()

        let wrongAction = try await dispatcher.dispatch(actionID: "Action.CrossSection.Delete",
            selection: selection, projectSessionID: project, currentProjectSessionID: project,
            provider: provider, selectionIsCurrent: { true })
        let wrongProject = try await dispatcher.dispatch(actionID: ClassicCrossSectionEditActionDispatcher.actionID,
            selection: selection, projectSessionID: project, currentProjectSessionID: UUID(),
            provider: provider, selectionIsCurrent: { true })

        #expect(wrongAction == nil)
        #expect(wrongProject == nil)
        #expect(windows.sessions.isEmpty)
    }

    @MainActor
    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await condition())
    }

    private func fixture() -> (ClassicCrossSectionSelection, any ClassicCrossSectionProvider) {
        let scope = UUID()
        let source = URL(fileURLWithPath: "/tmp/classic-edit-action.h5")
        let path = SourceFilePaths.canonical(source)
        let revision = String(repeating: "A", count: 64)
        let context = BackendClassicCrossSectionProvider.contextToken(
            scopeID: scope, path: path, revision: revision)
        let row = ClassicCrossSectionRow(ordinal: 7,
            rowToken: BackendClassicCrossSectionProvider.rowToken(context, 7),
            nodeName: "Selected section", riverName: "River", reachName: "Reach",
            riverStation: "7.0", profilePointCount: 1, usesOverride: false)
        let profile = ClassicCrossSectionProfile(scopeID: scope.uuidString, sourcePath: path,
            sourceRevision: revision, contextToken: context, row: row, hasProfile: true,
            points: [.init(ordinal: 0, station: 0, elevation: 1)], banks: [])
        return (ClassicCrossSectionSelection(profile: profile,
            access: ClassicCrossSectionAccess(url: source), scopeID: scope),
            StaticCrossSectionProfile(value: profile))
    }
}

private struct StaticCrossSectionProfile: ClassicCrossSectionProvider {
    let value: ClassicCrossSectionProfile

    func catalog(scopeID: UUID, source: URL, revision: String?, offset: Int) async throws -> ClassicCrossSectionCatalog {
        throw DataToolError.unavailable
    }

    func profile(scopeID: UUID, source: URL, revision: String, contextToken: String,
                 row: ClassicCrossSectionRow) async throws -> ClassicCrossSectionProfile {
        guard scopeID.uuidString.caseInsensitiveCompare(value.scopeID) == .orderedSame,
              SourceFilePaths.canonical(source) == value.sourcePath,
              revision.caseInsensitiveCompare(value.sourceRevision) == .orderedSame,
              contextToken == value.contextToken,
              row == value.row else {
            throw BackendServiceError(code: "sourceChanged",
                message: "The cross-section source changed. Reload and select the section again.")
        }
        return value
    }
}

private actor HeldCrossSectionProfile: ClassicCrossSectionProvider {
    private let value: ClassicCrossSectionProfile
    private var continuation: CheckedContinuation<ClassicCrossSectionProfile, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var hasPending = false

    init(_ value: ClassicCrossSectionProfile) { self.value = value }

    func catalog(scopeID: UUID, source: URL, revision: String?, offset: Int) async throws -> ClassicCrossSectionCatalog {
        throw DataToolError.unavailable
    }

    func profile(scopeID: UUID, source: URL, revision: String, contextToken: String,
                 row: ClassicCrossSectionRow) async throws -> ClassicCrossSectionProfile {
        guard scopeID.uuidString.caseInsensitiveCompare(value.scopeID) == .orderedSame,
              SourceFilePaths.canonical(source) == value.sourcePath,
              revision.caseInsensitiveCompare(value.sourceRevision) == .orderedSame,
              contextToken == value.contextToken,
              row == value.row else {
            throw BackendServiceError(code: "sourceChanged",
                message: "The cross-section source changed. Reload and select the section again.")
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            hasPending = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }

    func waitUntilRequested() async {
        if hasPending { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        let pending = continuation
        continuation = nil
        hasPending = false
        pending?.resume(returning: value)
    }
}
