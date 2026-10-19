import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct BackendPlanExportTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_PLAN_EXPORT_ACCEPTANCE_DIRECTORY"] != nil)) @MainActor
    func surfaceCatalogReadsActualHdfGroupsAndInvalidatesItsSession() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let fixture = try #require(ProcessInfo.processInfo.environment["HECRAS_PLAN_EXPORT_ACCEPTANCE_DIRECTORY"])
        let document = try ProjectDocument(contentsOf: URL(fileURLWithPath: fixture).appendingPathComponent("source/原工程.ras"))
        let provider = BackendModelProvider(client: .init(executableURL: URL(fileURLWithPath: executable)))
        let assets = document.assets.filter { $0.section == .surfaceLayers }, catalog = SurfaceCatalogSession()
        await catalog.load(assets, provider: provider)
        #expect(!catalog.busy && catalog.error == nil && catalog.entries.count == 2)
        let nvalues = try #require(assets.first { $0.name == "糙率" }), classification = try #require(assets.first { $0.name == "土地分类" })
        #expect(catalog.entries[nvalues.id]?.category == "NValues")
        #expect(catalog.entries[classification.id]?.category == "Classifications")
        catalog.invalidate()
        #expect(catalog.entries.isEmpty && !catalog.busy)
        await catalog.load(assets, provider: nil)
        #expect(catalog.entries.isEmpty && catalog.error == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_PLAN_EXPORT_ACCEPTANCE_DIRECTORY"] != nil)) @MainActor
    func actualExportAdoptsSourceDefaultsAndPublishesZipAndReopenableDirectoryWithoutSavingTheProject() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let fixture = try #require(ProcessInfo.processInfo.environment["HECRAS_PLAN_EXPORT_ACCEPTANCE_DIRECTORY"])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("plan-export-" + UUID().uuidString)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: fixture), to: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("source/原工程.ras")
        let original = try Data(contentsOf: path)
        let document = try ProjectDocument(contentsOf: path)
        document.description = "Swift 未保存的中文工程说明"
        var metadataDraft = "界面中尚未保存的工程说明 🌊"
        let plan = try #require(document.assets.first { $0.section == .plans && $0.name == "选择的方案" })
        let client = BackendProcessClient(executableURL: URL(fileURLWithPath: executable))
        let provider = BackendToolProvider(client: client), state = DataToolSession(), editor = ModelEditorSession()
        let sessionID = UUID(), context = DataToolContext(projectSessionID: UUID(), mapID: UUID(), assetID: plan.id, extent: nil)
        let matchingContext = DataToolContext(projectSessionID: sessionID, mapID: context.mapID, assetID: plan.id, extent: nil)
        provider.setProject(document, sessionID: sessionID)
        provider.projectXML = { document.editorXML(overridingDescription: metadataDraft) }
        var outputs: [URL] = [], running: [Bool] = []
        provider.onExported = { outputs.append($0) }; provider.onRunningChanged = { running.append($0) }
        editor.startDraft(.init(fields: ["PlanExporterControl/ExportTypeIndex": "0", "PlanExporterControl/ClipRasters": "false", "PlanExporterControl/ExternalConnectionIndex": "1"], rows: [:], samples: [:], canEdit: true, images: [:]))
        func request() -> ToolRequest { state.request(kind: .planExport, editor: editor, context: matchingContext) }
        #expect(request().destination == nil)
        provider.authorizeFolders = { _ in false }
        do { _ = try await provider.prepare(request()); Issue.record("Cancelled folder access must not start export inspection") }
        catch let error as BackendServiceError { #expect(error.code == "accessCancelled") }
        var authorized: [[URL]] = []
        provider.authorizeFolders = { authorized.append($0); return true }
        await state.prepare(request(), editor: editor, provider: provider, currentRequest: request)?.value
        #expect(authorized == [[folder.appendingPathComponent("external", isDirectory: true)]])
        #expect(state.error == nil && state.canExecute(request()))
        #expect(state.destination?.pathExtension == "zip")
        #expect(editor.fields["PlanExporterControl/Plan"] == plan.id)
        #expect(editor.fields["PlanExporterControl/ClipRasters"] == "false")
        #expect(editor.fields["PlanExporterControl/ExternalConnectionIndex"] == "1")
        #expect(editor.choiceOptions["PlanExporterControl/Plan"]?.count == 2)
        #expect(state.presentation.planExport?.requiredConnections.count == 2)
        var completed = 0
        await state.execute(request(), provider: provider) { completed += 1 }?.value
        #expect(state.error == nil, "\(state.error ?? "no error")")
        #expect(completed == 1 && outputs.count == 1)
        let zip = try Data(contentsOf: #require(outputs.first))
        #expect(Array(zip.prefix(2)) == [0x50, 0x4b])
        #expect(try Data(contentsOf: path) == original)
        #expect(document.description == "Swift 未保存的中文工程说明")
        editor.set("PlanExporterControl/ExportTypeIndex", "1"); state.destination = nil
        await state.prepare(request(), editor: editor, provider: provider, currentRequest: request)?.value
        #expect(state.canExecute(request()))
        #expect(state.destination?.pathExtension == "export")
        await state.execute(request(), provider: provider) { completed += 1 }?.value
        #expect(completed == 2 && outputs.count == 2 && running == [true, false, true, false])
        let exportFolder = try #require(outputs.last)
        let exported = try ProjectDocument(contentsOf: exportFolder.appendingPathComponent("原工程.ras"))
        #expect(exported.assets.filter { $0.section == .plans }.map(\.name) == ["选择的方案"])
        #expect(exported.description == metadataDraft && document.description != metadataDraft)
        #expect(exported.associations.contains { $0.name == plan.name && $0.fields["Geometry"] == "几何" && $0.fields["BoundaryCondition"] == "边界" })
        let copiedFile = try #require(exported.connections.first { $0.name == "文件连接" })
        let resolved = try copiedFile.resolve(relativeTo: exportFolder, mappings: [])
        #expect(resolved.path.hasPrefix(exportFolder.path + "/"))
        #expect(try String(contentsOf: resolved, encoding: .utf8) == "copy exact source bytes 🌊")
        let models = BackendModelProvider(client: client); models.setProject(exported)
        let actualPlan = try #require(exported.assets.first { $0.section == .plans })
        let actual = try await models.load(actualPlan, kind: .plan)
        #expect(actual.canEdit && actual.sourceRevision != nil)
        #expect(try Data(contentsOf: path) == original)
        state.destination = folder.appendingPathComponent("stale.zip"); editor.set("PlanExporterControl/ExportTypeIndex", "0")
        await state.prepare(request(), editor: editor, provider: provider, currentRequest: request)?.value
        metadataDraft = "来源草稿已更新"
        await state.execute(request(), provider: provider) { completed += 1 }?.value
        #expect(state.error != nil && completed == 2 && !FileManager.default.fileExists(atPath: state.destination!.path))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_PLAN_EXPORT_ACCEPTANCE_DIRECTORY"] != nil)) @MainActor
    func saveModelChangesUsesActualHdfPersistenceAndKeepsProjectMetadataUnsaved() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let fixture = try #require(ProcessInfo.processInfo.environment["HECRAS_PLAN_EXPORT_ACCEPTANCE_DIRECTORY"])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("save-model-only-" + UUID().uuidString)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: fixture), to: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let provider = BackendModelProvider(client: .init(executableURL: URL(fileURLWithPath: executable)))
        let suite = "plan-export-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WorkspaceStore(modelProvider: provider, recentHistoryStore: .init(defaults: defaults))
        store.createProject(name: "只保存模型", units: "SI", description: "原工程说明", directory: folder, projectionType: "Local", projectionValue: "SI")
        let document = try #require(store.document), path = try #require(document.url)
        let original = try Data(contentsOf: path)
        store.descriptionDraft = "仍未保存的工程草稿"
        let session = ModelEditorSession(provider: provider); store.registerEditor(session)
        let asset = ProjectAsset(url: folder.appendingPathComponent("source/Plans/选择的方案.h5"), section: .plans)
        await session.load(asset, kind: .plan)
        #expect(session.loaded)
        let field = "PlanSettingsPage/ViewModel_SelectedPlan_Description"
        session.set(field, "真实模型单独保存")
        #expect(store.hasUnsavedModelEdits)
        #expect(await store.saveModelEditsOnly())
        #expect(!session.modified && !store.hasUnsavedModelEdits && store.hasUnsavedChanges)
        #expect(store.descriptionDraft == "仍未保存的工程草稿" && document.description == "原工程说明")
        #expect(try Data(contentsOf: path) == original)
        let reloaded = try await provider.load(asset, kind: .plan)
        #expect(reloaded.fields[field] == "真实模型单独保存")
    }
}
