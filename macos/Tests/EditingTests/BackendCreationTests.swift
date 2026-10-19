import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct BackendCreationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_CREATION_ACCEPTANCE_DIRECTORY"] != nil)) @MainActor
    func sourcePreparationPreservesInitialBoundaryDatesBeforeTheUserChangesThem() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let fixture = try #require(ProcessInfo.processInfo.environment["HECRAS_CREATION_ACCEPTANCE_DIRECTORY"])
        let document = try ProjectDocument(contentsOf: URL(fileURLWithPath: fixture).appendingPathComponent("新建验收.ras"))
        let provider = BackendCreationToolProvider(client: .init(executableURL: URL(fileURLWithPath: executable)))
        let state = DataToolSession(), editor = ModelEditorSession(), sessionID = UUID()
        let context = DataToolContext(projectSessionID: sessionID, mapID: UUID(), assetID: nil, extent: nil)
        provider.setProject(document, sessionID: sessionID)
        let defaults = CreationDefaults.fields(kind: .newBoundary, timeZone: .gmt)
        editor.startDraft(.init(fields: defaults, rows: [:], samples: [:], canEdit: true, images: [:]))
        editor.set("NewBoundaryConditionControl/BoundaryConditionName", "默认时段保留")
        func request() -> ToolRequest { state.request(kind: .newBoundary, editor: editor, context: context) }
        await state.prepare(request(), editor: editor, provider: provider, currentRequest: request)?.value
        #expect(state.error == nil && state.canExecute(request()))
        for (key, value) in defaults { #expect(editor.fields[key] == value) }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_CREATION_ACCEPTANCE_DIRECTORY"] != nil)) @MainActor
    func actualSourceCreationMergesAssociationsWithoutSavingOrReplacingTheProjectDraft() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let fixture = try #require(ProcessInfo.processInfo.environment["HECRAS_CREATION_ACCEPTANCE_DIRECTORY"])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("creation-service-" + UUID().uuidString)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: fixture), to: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("新建验收.ras")
        let original = try Data(contentsOf: path)
        let document = try ProjectDocument(contentsOf: path)
        document.description = "未保存中文草稿，创建后仍保留"
        let client = BackendProcessClient(executableURL: URL(fileURLWithPath: executable))
        let provider = BackendCreationToolProvider(client: client)
        let sessionID = UUID()
        let context = DataToolContext(projectSessionID: sessionID, mapID: UUID(), assetID: nil, extent: nil)
        provider.setProject(document, sessionID: sessionID)
        var running: [Bool] = [], created: [(ProjectAsset, Bool)] = []
        provider.onRunningChanged = { running.append($0) }
        provider.onCreated = { created.append(($0, $1)) }
        func request(_ kind: ToolKind, _ fields: [String: String]) -> ToolRequest {
            .init(kind: kind.id, fields: fields, inputFiles: [], destination: nil, images: [:], context: context)
        }
        var geometryFields = ["NewGeometryControl/GeometryName": "Swift中文几何"]
        let choices = try await provider.prepare(request(.newGeometry, geometryFields))
        #expect(choices.canExecute)
        let terrain = try #require(choices.editor.choiceOptions["NewGeometryControl/SelectedTerrain"]?.first)
        let nvalues = try #require(choices.editor.choiceOptions["NewGeometryControl/SelectedNValue"]?.first)
        geometryFields["NewGeometryControl/SelectedTerrain"] = terrain.id
        geometryFields["NewGeometryControl/SelectedNValue"] = nvalues.id
        let geometryRequest = request(.newGeometry, geometryFields)
        _ = try await provider.prepare(geometryRequest)
        try await provider.execute(geometryRequest)
        let geometry = try #require(created.last?.0)
        #expect(geometry.name == "Swift中文几何" && created.last?.1 == true)
        #expect(document.associations.contains { $0.name == geometry.name && $0.fields["Terrain"] == terrain.title && $0.fields["N_Values"] == nvalues.title })
        #expect(try Data(contentsOf: path) == original)
        #expect(document.description == "未保存中文草稿，创建后仍保留")
        #expect(document.editorXML.contains("UnknownCreationMetadata"))
        #expect(!(try await provider.prepare(geometryRequest)).canExecute)
        let boundaryRequest = request(.newBoundary, [
            "NewBoundaryConditionControl/BoundaryConditionName": "Swift中文边界",
            "NewBoundaryConditionControl/StartTime": "2026-10-15T00:00:00Z",
            "NewBoundaryConditionControl/EndTime": "2026-10-16T00:00:00Z"
        ])
        _ = try await provider.prepare(boundaryRequest)
        try await provider.execute(boundaryRequest)
        let boundary = try #require(created.last?.0)
        var planFields = [
            "NewPlanControl/PlanName": "Swift继承方案",
            "NewPlanControl/SelectedGeometry": geometry.id,
            "NewPlanControl/SelectedBoundaryCondition": boundary.id,
            "NewPlanControl/TimeWindowMode": "BoundaryCondition"
        ]
        let planRequest = request(.newPlan, planFields)
        let ready = try await provider.prepare(planRequest)
        #expect(ready.canExecute && ready.creation?.boundaryTimeWindows[boundary.id] != nil)
        try await provider.execute(planRequest)
        let plan = try #require(created.last?.0)
        let models = BackendModelProvider(client: client)
        models.setProject(document)
        let actual = try await models.load(plan, kind: .plan)
        #expect(actual.fields["PlanSettingsPage/ViewModel_SelectedPlan_TimeWindowMode"] == "BoundaryCondition")
        let start = try #require(actual.fields["PlanSettingsPage/ViewModel_SelectedPlan_ComputeStartTime"])
        #expect(start.contains("2026-10-15"))
        #expect(try Data(contentsOf: path) == original)
        try document.save()
        let reloaded = try ProjectDocument(contentsOf: path)
        #expect(reloaded.description == document.description)
        #expect(reloaded.editorXML.contains("UnknownCreationMetadata"))
        #expect(reloaded.associations.contains { $0.name == plan.name && $0.fields["Geometry"] == geometry.name && $0.fields["BoundaryCondition"] == boundary.name })
        // An edit through the actual model service after readiness must prevent
        // creation against a stale source. No successful synthetic provider.
        planFields["NewPlanControl/PlanName"] = "过期来源不能创建"
        let staleRequest = request(.newPlan, planFields)
        _ = try await provider.prepare(staleRequest)
        let before = try await models.load(boundary, kind: .boundaryCondition)
        _ = try await models.saveModel(boundary, changes: .init(fields: ["BoundaryConditionsSummary/BoundaryCondition_Description": "另一个源编辑"], rows: [:], images: [:], sourceRevision: before.sourceRevision))
        do { try await provider.execute(staleRequest); Issue.record("Stale selected source created a plan") }
        catch let error as BackendServiceError { #expect(error.code == "sourceChanged") }
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("Plans/过期来源不能创建.h5").path))
        #expect(running == [true, false, true, false, true, false, true, false])
        #expect(created.count == 3)
        #expect((try await provider.prepare(staleRequest)).canExecute)
        let staleContext = DataToolContext(projectSessionID: UUID(), mapID: context.mapID, assetID: nil, extent: nil)
        let wrong = ToolRequest(kind: ToolKind.newGeometry.id, fields: geometryFields, inputFiles: [], destination: nil, images: [:], context: staleContext)
        do { _ = try await provider.prepare(wrong); Issue.record("Another project reused creation context") }
        catch let error as BackendServiceError { #expect(error.code == "sourceChanged") }
    }
}
