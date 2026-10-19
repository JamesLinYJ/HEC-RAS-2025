import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class ProjectFileServices: WorkspaceSystemServices {
    var denyAuthorization = false
    func authorizeProjectFolder(for input: URL) -> URL? { denyAuthorization ? nil : input }
    func chooseProject() -> URL? { nil }
    func chooseProjectDestination(name: String) -> URL? { nil }
    func chooseFolder(title: String) -> URL? { nil }
    func chooseVectorLayer() -> URL? { nil }
    func chooseConnectionFile() -> URL? { nil }
    func chooseInputFiles() -> [URL] { [] }
    func chooseImageFiles() -> [URL] { [] }
    func chooseProjectionFile() -> URL? { nil }
    func reveal(_ url: URL) {}
    func copy(_ text: String) {}
    func openWebsite(_ url: URL) {}
}

@MainActor
private final class LibraryOpeningProvider: ProjectLibraryProvider {
    var projects: [LibraryProject] = []
    var synthetic: [LibraryProject] = [.init(id: "source-synthetic", title: "Source Synthetic", description: "", publishDate: nil, tags: [])]
    var calls: [(String, Bool)] = []
    var progress: (@MainActor (Job) -> Void)?
    private var completion: CheckedContinuation<URL, any Error>?
    private var waiter: CheckedContinuation<Void, Never>?
    func examples() async throws -> [LibraryProject] { projects }
    func syntheticProjects() async throws -> [LibraryProject] { synthetic }
    func openProject(_ project: LibraryProject, synthetic: Bool) async throws -> URL { throw CancellationError() }
    func openProject(_ project: LibraryProject, synthetic: Bool, progress: @escaping @MainActor (Job) -> Void) async throws -> URL {
        calls.append((project.id, synthetic)); self.progress = progress
        return try await withCheckedThrowingContinuation { continuation in completion = continuation; waiter?.resume(); waiter = nil }
    }
    func waitUntilStarted() async { if completion == nil { await withCheckedContinuation { waiter = $0 } } }
    func finish(_ result: Result<URL, any Error>) { completion?.resume(with: result); completion = nil }
}

@MainActor
private final class TaskActionProvider: JobProvider {
    var cancellations: [String] = []
    var removals: [String] = []
    private var completion: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func cancel(_ id: String) async throws {
        cancellations.append(id)
        await withCheckedContinuation { completion = $0; waiter?.resume(); waiter = nil }
    }
    func remove(_ id: String) async throws { removals.append(id) }
    func waitUntilStarted() async { if completion == nil { await withCheckedContinuation { waiter = $0 } } }
    func finish() { completion?.resume(); completion = nil }
}

struct ProjectOpeningTests {
    private func project(_ folder: URL, name: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name + ".ras")
        try Data("<Project><Description>on disk</Description><Unknown Preserve='yes'/></Project>".utf8).write(to: url)
        return url
    }
    @MainActor private func waitForOpening(_ store: WorkspaceStore) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while store.isOpeningProject && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!store.isOpeningProject)
    }
    @Test @MainActor func renamedExternalConnectionUsesNormalProjectSavePath() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let projectURL = folder.appendingPathComponent("Connections.ras")
        let xml = """
        <Project Vendor="preserve"><Connections>
          <Connection Name="Original" Type="File" VendorConnection="preserve">
            <AbsolutePath>/unused/source.tif</AbsolutePath><Custom>Keep this node</Custom>
          </Connection>
        </Connections><UnknownProjectData>Keep project data</UnknownProjectData></Project>
        """
        try Data(xml.utf8).write(to: projectURL)

        let store = WorkspaceStore(system: ProjectFileServices())
        store.requestOpen(projectURL)
        try await waitForOpening(store)
        let projectSessionID = store.projectSessionID
        let original = try #require(store.document?.connections.first)
        try store.renameExternalConnection(original, to: "Renamed", projectID: projectSessionID)

        #expect(store.document?.connections.first?.id == original.id)
        #expect(store.document?.connections.first?.name == "Renamed")
        #expect(store.isModified)
        #expect(store.save())
        #expect(!store.isModified)

        let reopened = try ProjectDocument(contentsOf: projectURL)
        #expect(reopened.connections.map(\.name) == ["Renamed"])
        let savedXML = try XMLDocument(data: Data(contentsOf: projectURL))
        #expect(savedXML.rootElement()?.attribute(forName: "Vendor")?.stringValue == "preserve")
        #expect(savedXML.rootElement()?.elements(forName: "Connections").first?.elements(forName: "Connection").first?.attribute(forName: "VendorConnection")?.stringValue == "preserve")
        #expect(savedXML.rootElement()?.elements(forName: "Connections").first?.elements(forName: "Connection").first?.elements(forName: "Custom").first?.stringValue == "Keep this node")
        #expect(savedXML.rootElement()?.elements(forName: "UnknownProjectData").first?.stringValue == "Keep project data")
    }
    @Test @MainActor func cancellationAndSupersededReadsCannotInstallOldProjects() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try project(folder, name: "first"), second = try project(folder, name: "second")
        let store = WorkspaceStore(system: ProjectFileServices())
        store.requestOpen(first); #expect(store.isOpeningProject)
        store.cancelProjectOpening(); #expect(!store.isOpeningProject && store.document == nil)
        store.requestOpen(first); store.requestOpen(second)
        try await waitForOpening(store)
        #expect(store.document?.url == second)
        let xml = try XMLDocument(xmlString: try #require(store.document?.editorXML))
        #expect(xml.rootElement()?.elements(forName: "Unknown").first?.attribute(forName: "Preserve")?.stringValue == "yes")
        #expect(store.messages.filter { $0.operation == L10n.text("Open Project") && !$0.isError }.count == 1)
    }
    @Test @MainActor func failedReadRetainsCurrentProjectAndLaterDraftGetsConfirmation() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try project(folder, name: "first"), second = try project(folder, name: "second")
        let store = WorkspaceStore(system: ProjectFileServices())
        store.requestOpen(first); try await waitForOpening(store)
        let session = store.projectSessionID
        store.requestOpen(folder.appendingPathComponent("missing.ras")); try await waitForOpening(store)
        #expect(store.document?.url == first && store.projectSessionID == session)
        store.errorMessage = nil
        store.requestOpen(second)
        store.descriptionDraft = "typed in a detached editor while loading"
        try await waitForOpening(store)
        #expect(store.document?.url == first && store.showDiscardConfirmation)
        store.cancelReplacement()
        #expect(store.descriptionDraft == "typed in a detached editor while loading")
    }
    @Test @MainActor func librarySelectionSeparatesExampleAndSyntheticIdentities() async throws {
        let provider = LibraryOpeningProvider(), state = ProjectLibrarySession()
        await state.load(provider: provider)
        let local = try #require(state.synthetic.first)
        provider.projects = [.init(id: local.id, title: "Example with the same identifier", description: "", publishDate: nil, tags: [])]
        await state.load(provider: provider)
        let example = LibraryProjectSelection(origin: .example, projectID: local.id)
        let synthetic = LibraryProjectSelection(origin: .synthetic, projectID: local.id)
        #expect(state.project(example)?.title == "Example with the same identifier")
        #expect(state.project(synthetic)?.title == local.title)
        let opening = Task { await state.open(synthetic, provider: provider) }
        await provider.waitUntilStarted()
        #expect(provider.calls.count == 1 && provider.calls[0].1)
        provider.finish(.success(URL(fileURLWithPath: "/fixture/example.ras")))
        #expect(await opening.value != nil)
    }
    @Test @MainActor func migrationRetainsLiveDraftAndConfirmsReplacementAfterSheetDismissal() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let current = try project(folder, name: "current")
        let converted = try project(folder, name: "converted")
        let legacy = folder.appendingPathComponent("legacy.prj")
        try Data("Proj Title=Legacy\nCurrent Plan=\nDefault Exp/Contr=0.3,0.1\nSI Units\n".utf8).write(to: legacy)
        let store = WorkspaceStore(system: ProjectFileServices())
        store.requestOpen(current)
        try await waitForOpening(store)
        store.descriptionDraft = "keep this live draft through conversion"
        let identity = store.projectSessionID

        store.requestOpen(legacy)
        #expect(store.projectMigration?.sourceURL == legacy)
        #expect(store.projectMigration?.authorizedSourceDirectory.resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path)
        #expect(store.document?.url == current && store.projectSessionID == identity)
        #expect(!store.isOpeningProject && !store.showDiscardConfirmation)
        #expect(store.descriptionDraft == "keep this live draft through conversion")

        store.requestOpen(converted)
        #expect(!store.isOpeningProject && store.document?.url == current)
        store.requestClose()
        store.requestNewProject()
        #expect(!store.showDiscardConfirmation && !store.showNewProject)
        #expect(store.document?.url == current && store.descriptionDraft == "keep this live draft through conversion")
        store.completeProjectMigration(converted)
        #expect(store.projectMigration == nil && !store.isOpeningProject)
        store.finishProjectMigrationPresentation()
        #expect(store.showDiscardConfirmation && store.document?.url == current)
        store.cancelReplacement()
        #expect(store.descriptionDraft == "keep this live draft through conversion")
        store.finishProjectMigrationPresentation()
        #expect(!store.showDiscardConfirmation && !store.isOpeningProject)

        store.requestOpen(converted)
        store.discardAndContinue()
        try await waitForOpening(store)
        #expect(store.document?.url == converted)
        #expect(store.descriptionDraft == "on disk")
        #expect(try String(contentsOf: legacy, encoding: .utf8).hasPrefix("Proj Title=Legacy"))
    }
    @Test @MainActor func cancelledMigrationAndDeniedFolderAccessLeaveWorkspaceUntouched() {
        let services = ProjectFileServices()
        let store = WorkspaceStore(system: services)
        let legacy = URL(fileURLWithPath: "/migration-fixtures/source.PRJ")
        services.denyAuthorization = true
        store.requestOpen(legacy)
        #expect(store.projectMigration == nil && store.document == nil)
        services.denyAuthorization = false
        store.requestOpen(legacy)
        #expect(store.projectMigration?.sourceURL == legacy)
        store.projectMigration = nil
        store.finishProjectMigrationPresentation()
        #expect(store.document == nil && !store.isOpeningProject && !store.showDiscardConfirmation)
    }
    @Test @MainActor func leavingLibraryKeepsNonCancellableOpenButSuppressesLateProgress() async throws {
        let provider = LibraryOpeningProvider(), state = ProjectLibrarySession()
        provider.projects = [.init(id: "one", title: "One", description: "", publishDate: nil, tags: [])]
        await state.load(provider: provider)
        let opening = Task { await state.open(.init(origin: .example, projectID: "one"), provider: provider) }
        await provider.waitUntilStarted()
        state.invalidate()
        provider.progress?(.init(id: "job", name: "late", progress: 99, message: "stale", isComplete: false, taskSucceeded: false, isCancelling: false, timeTaken: nil, isCancellable: false))
        #expect(state.opening != nil && state.currentJob == nil)
        let completedURL = URL(fileURLWithPath: "/fixture/example.ras")
        provider.finish(.success(completedURL))
        #expect(await opening.value == completedURL)
        #expect(state.currentJob == nil && state.opening == nil)
    }
    @Test @MainActor func libraryFailureReturnsToDetailAndDuplicateIDsAreRejected() async throws {
        let provider = LibraryOpeningProvider(), state = ProjectLibrarySession()
        let project = LibraryProject(id: "one", title: "One", description: "", publishDate: nil, tags: [])
        provider.projects = [project]; await state.load(provider: provider)
        let selected = LibraryProjectSelection(origin: .example, projectID: "one")
        let opening = Task { await state.open(selected, provider: provider) }
        await provider.waitUntilStarted(); provider.finish(.failure(CocoaError(.fileReadNoPermission)))
        #expect(await opening.value == nil)
        #expect(state.opening == nil && state.error != nil && state.project(selected)?.id == "one")
        provider.projects = [project, project]; await state.load(provider: provider)
        #expect(state.error != nil && state.examples.count == 1)
    }
    @Test @MainActor func libraryProjectOpensOnlyAfterSheetDismissal() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try project(folder, name: "library")
        let store = WorkspaceStore(system: ProjectFileServices())
        store.showProjectLibrary = true; store.requestOpenFromLibrary(url)
        #expect(!store.showProjectLibrary && !store.isOpeningProject && store.document == nil)
        store.finishLibraryPresentation(); #expect(store.isOpeningProject)
        try await waitForOpening(store); #expect(store.document?.url == url)
        store.finishLibraryPresentation(); #expect(!store.isOpeningProject)
    }
    @Test @MainActor func taskCommandsRespectSourceDeletionAndDoNotSendDuplicateCancellation() async {
        let provider = TaskActionProvider()
        let workspace = WorkspaceStore(system: ProjectFileServices(), jobProvider: provider)
        let running = Job(id: "one", name: "One", progress: .nan, message: "", isComplete: false, taskSucceeded: false, isCancelling: false, timeTaken: .infinity)
        workspace.jobs = [running]
        #expect(running.fraction == nil && running.validDuration == nil)
        await workspace.removeJob(running.id)
        #expect(provider.removals.isEmpty)
        let cancellation = Task { await workspace.cancelJob(running.id) }
        await provider.waitUntilStarted()
        await workspace.cancelJob(running.id)
        #expect(provider.cancellations == [running.id])
        #expect(workspace.pendingJobActions == [running.id])
        provider.finish(); await cancellation.value
        #expect(workspace.pendingJobActions.isEmpty)
        // A source parent can permit deletion while a job is still running.
        var removable = running; removable.canDelete = true
        workspace.jobs = [removable]
        await workspace.removeJob(running.id)
        #expect(provider.removals == [running.id])
    }
}
