import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct BackendSurfaceCreationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_CREATION_ACCEPTANCE_DIRECTORY"] != nil)) @MainActor
    func allThreeSurfaceKindsCreateReopenAndPreserveTheProjectDraft() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let fixture = try #require(ProcessInfo.processInfo.environment["HECRAS_CREATION_ACCEPTANCE_DIRECTORY"])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("surface-creation-" + UUID().uuidString)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: fixture), to: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let projectURL = folder.appendingPathComponent("新建验收.ras")
        let originalProject = try Data(contentsOf: projectURL)
        let project = try ProjectDocument(contentsOf: projectURL)
        project.description = "未保存的地形、分类和糙率草稿"
        let client = BackendProcessClient(executableURL: URL(fileURLWithPath: executable))
        let creation = BackendSurfaceCreationProvider(client: client)
        let models = BackendModelProvider(client: client)
        models.setProject(project)
        for kind in SurfaceCreationKind.allCases {
            var request = SurfaceCreationRequest(kind: kind, projectPath: projectURL.path,
                projectXml: project.editorXML, name: "Swift 中文 " + kind.defaultName)
            let ready = try await creation.inspect(request)
            #expect(ready.canExecute && ready.validationMessage == nil)
            request.revision = ready.revision
            let result = try await creation.create(request)
            #expect(result.name == request.name && result.section == kind.section.rawValue)
            #expect(result.group == nil && result.associations.isEmpty)
            try project.reloadAssets()
            let asset = try #require(project.assets.first { $0.url.standardizedFileURL.path == result.assetPath })
            #expect(asset.section == kind.section)
            let snapshot = try await models.load(asset, kind: kind.editorKind)
            #expect(snapshot.canEdit && snapshot.sourceRevision != nil)
            #expect(!(try await creation.inspect(request)).canExecute)
            #expect(project.description == "未保存的地形、分类和糙率草稿")
            #expect(project.editorXML.contains("UnknownCreationMetadata"))
            #expect(try Data(contentsOf: projectURL) == originalProject)
        }
    }
}
