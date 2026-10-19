import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct BackendResultDeletionWorkflowTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_RESULT_PROFILE_ACCEPTANCE_RESULT"] != nil)) @MainActor
    func validatedResultRemovalRetiresEditorsAndMapReferencesWithoutSavingTheProjectDraft() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let fixture = try #require(ProcessInfo.processInfo.environment["HECRAS_RESULT_PROFILE_ACCEPTANCE_RESULT"])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("result-removal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Results"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let projectURL = folder.appendingPathComponent("Removal.ras")
        let resultURL = folder.appendingPathComponent("Results/Unique filename.h5")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: fixture), to: resultURL)
        let project = try ProjectDocument(name: "Removal", units: "SI")
        try project.save(to: projectURL)
        let originalProject = try Data(contentsOf: projectURL)
        let resultBytes = try Data(contentsOf: resultURL)
        let client = BackendProcessClient(executableURL: URL(fileURLWithPath: executable))
        let inspectorProvider = BackendResultInspectorProvider(client: client)
        let inspected = try await inspectorProvider.inspect(resultPath: resultURL, projectPath: projectURL,
            projectXML: project.editorXML, revision: nil)
        // Map nodes use the validated Result name, independently of its
        // embedded Plan identity or a presentation label.
        let visualURL = folder.appendingPathComponent("Removal.vis")
        let escaped = inspected.name.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;")
        try Data("<Ras><Maps><Map Name='Map' Type='Project'><Tree><Nodes><Node Type='Result' Name=\"\(escaped)\"/><Node Type='Geometry' Name=\"\(escaped)\"/><Node Type='Result' Name='Keep'/></Nodes></Tree></Map></Maps><Views/><Unknown Keep='yes'/></Ras>".utf8).write(to: visualURL)
        let system = ResultRemovalFixtureServices(recoveryFolder: folder.appendingPathComponent("Recovered"))
        let provider = BackendModelProvider(client: client)
        let store = WorkspaceStore(system: system, modelProvider: provider)
        store.requestOpen(projectURL)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while store.isOpeningProject && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!store.isOpeningProject)
        let asset = try #require(store.assets.first { $0.section == .results })
        let selectedIdentity = asset.id
        let editor = store.primaryEditorSession(.result)
        await editor.load(asset, kind: .result)
        #expect(editor.loaded && editor.error == nil)
        store.openEditor(.result, assetID: asset.id)
        store.select(asset)
        store.descriptionDraft = "Keep this unsaved 中文 description"
        #expect(!store.beginResultDeletion(assetID: asset.id, projectSessionID: UUID()))
        let projectSession = store.projectSessionID
        #expect(store.beginResultDeletion(assetID: asset.id, projectSessionID: projectSession))
        #expect(store.isRunningProjectTool)
        #expect(!store.beginResultDeletion(assetID: asset.id, projectSessionID: projectSession))
        #expect(!store.save())
        #expect(throws: (any Error).self) {
            try store.completeResultDeletion(assetID: asset.id, sourceName: inspected.name, projectSessionID: projectSession)
        }
        let preparation = try await inspectorProvider.prepareDelete(resultPath: resultURL, projectPath: projectURL,
            projectXML: try #require(store.document).editorXML(overridingDescription: store.descriptionDraft), revision: inspected.revision)
        try system.trash(URL(fileURLWithPath: preparation.resultPath))
        #expect(asset.id == selectedIdentity)
        try store.completeResultDeletion(assetID: asset.id, sourceName: preparation.name, projectSessionID: projectSession)
        store.endResultDeletion(projectSessionID: projectSession)
        #expect(!store.isRunningProjectTool)
        #expect(editor.modelAssetID == nil && !editor.loaded)
        #expect(store.selectedAssetID == nil && store.assets.allSatisfy { $0.section != .results })
        #expect(!store.openEditors.contains(.result) && store.editorAssetRequests[.result] == nil)
        #expect(store.descriptionDraft == "Keep this unsaved 中文 description")
        #expect(try Data(contentsOf: projectURL) == originalProject)
        #expect(try Data(contentsOf: system.recoveryFolder.appendingPathComponent(resultURL.lastPathComponent)) == resultBytes)
        let savedMaps = try XMLDocument(data: Data(contentsOf: visualURL))
        let resultNodes = try savedMaps.nodes(forXPath: "//Node[@Type='Result']").compactMap { $0 as? XMLElement }
        #expect(resultNodes.map { $0.attribute(forName: "Name")?.stringValue } == ["Keep"])
        let geometryNodes = try savedMaps.nodes(forXPath: "//Node[@Type='Geometry']").compactMap { $0 as? XMLElement }
        #expect(geometryNodes.first?.attribute(forName: "Name")?.stringValue == inspected.name)
        #expect(try savedMaps.nodes(forXPath: "/Ras/Unknown[@Keep='yes']").count == 1)
    }
}

/// The test moves only its disposable HDF into a recovery folder. Actual macOS
/// Trash interaction remains a separate native acceptance check.
@MainActor
private final class ResultRemovalFixtureServices: WorkspaceSystemServices {
    let recoveryFolder: URL
    init(recoveryFolder: URL) { self.recoveryFolder = recoveryFolder }
    func trash(_ url: URL) throws {
        try FileManager.default.createDirectory(at: recoveryFolder, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: recoveryFolder.appendingPathComponent(url.lastPathComponent))
    }
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
