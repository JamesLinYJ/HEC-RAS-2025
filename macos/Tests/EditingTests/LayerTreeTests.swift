import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class DeferredTreeProvider: LayerTreeProvider {
    private var completion: CheckedContinuation<LayerTreeSnapshot, any Error>?
    private var started: CheckedContinuation<Void, Never>?
    func load(_ context: LayerTreeContext) async throws -> LayerTreeSnapshot {
        try await withCheckedThrowingContinuation { completion = $0; started?.resume(); started = nil }
    }
    func perform(_ action: LayerTreeAction, context: LayerTreeContext) async throws -> LayerTreeSnapshot { throw CocoaError(.featureUnsupported) }
    func waitForStart() async {
        if completion != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish(_ snapshot: LayerTreeSnapshot) { completion?.resume(returning: snapshot); completion = nil }
}

struct LayerTreeTests {
    @Test @MainActor
    func cancellingProjectFolderAccessKeepsTheCurrentProject() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.ras")
        try Data("<Project><Projection Type=\"Local\">SI</Projection><Description>保持当前项目</Description></Project>".utf8).write(to: first)
        let system = ClipboardFixtureServices(), workspace = WorkspaceStore(system: system)
        workspace.requestOpen(first)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while workspace.isOpeningProject && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let original = try #require(workspace.document)
        let originalSession = workspace.projectSessionID
        system.allowProjectAccess = false
        workspace.requestOpen(directory.appendingPathComponent("not-yet-authorized.ras"))
        #expect(workspace.document === original)
        #expect(workspace.projectSessionID == originalSession)
        #expect(workspace.descriptionDraft == "保持当前项目")
        #expect(workspace.errorMessage == nil)
    }
    @Test @MainActor
    func oldProjectCopyCannotReplaceClipboardAfterInvalidation() async throws {
        let provider = DeferredCopyTreeProvider(), session = LayerTreeSession(), system = ClipboardFixtureServices()
        let context = LayerTreeContext(projectSessionID: UUID(), projectURL: URL(fileURLWithPath: "/task-fixture/project.ras"), mapID: UUID(), mode: "Project", focusedGeometryIDs: [], focusedPlanIDs: [])
        await session.load(provider: provider, context: context)
        let copying = Task { await session.copyWholeLayer(system: system) }
        await provider.waitForCopyStart()
        session.invalidate(); provider.finishCopy(); await copying.value
        #expect(system.writes.isEmpty)
        #expect(!session.canCopyWholeLayer)
        #expect(!session.busy)
    }
    @Test @MainActor
    func projectReplacementRejectsLateTreeSnapshot() async throws {
        let provider = DeferredTreeProvider(), session = LayerTreeSession()
        let context = LayerTreeContext(projectSessionID: UUID(), projectURL: URL(fileURLWithPath: "/task-fixture/project.ras"), mapID: UUID(), mode: "Project", focusedGeometryIDs: [], focusedPlanIDs: [])
        let loading = Task { await session.load(provider: provider, context: context) }
        await provider.waitForStart()
        session.invalidate()
        provider.finish(LayerTreeSnapshot(roots: [LayerTreeNode(id: "old-folder", sourceClass: "FolderNode", name: "Old Project")]))
        await loading.value
        #expect(session.roots == nil)
        #expect(session.selectedID == nil)
        #expect(!session.busy)
    }
}

@MainActor
private final class DeferredCopyTreeProvider: LayerTreeProvider {
    private var completion: CheckedContinuation<[ClipboardItem], any Error>?
    private var started: CheckedContinuation<Void, Never>?
    func load(_ context: LayerTreeContext) async throws -> LayerTreeSnapshot {
        LayerTreeSnapshot(roots: [], canCopyWholeLayer: true)
    }
    func perform(_ action: LayerTreeAction, context: LayerTreeContext) async throws -> LayerTreeSnapshot { try await load(context) }
    func copyWholeLayer(context: LayerTreeContext) async throws -> [ClipboardItem] {
        try await withCheckedThrowingContinuation { completion = $0; started?.resume(); started = nil }
    }
    func waitForCopyStart() async { if completion == nil { await withCheckedContinuation { started = $0 } } }
    func finishCopy() {
        completion?.resume(returning: [ClipboardItem(representations: ["org.hecras.task.fixture": Data("old project".utf8)])]); completion = nil
    }
}

@MainActor
private final class ClipboardFixtureServices: WorkspaceSystemServices {
    var allowProjectAccess = true
    func authorizeProjectFolder(for input: URL) -> URL? { allowProjectAccess ? input : nil }
    var writes: [[ClipboardItem]] = []
    func writeClipboard(_ items: [ClipboardItem]) -> Bool { writes.append(items); return true }
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
