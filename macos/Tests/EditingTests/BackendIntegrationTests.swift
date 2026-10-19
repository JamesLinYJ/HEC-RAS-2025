import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct BackendIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_EDITOR_ACCEPTANCE_DIRECTORY"] != nil))
    @MainActor func planEditorsUseTheRealBundledSourceBackendAndRejectStaleSaves() async throws {
        let environment = ProcessInfo.processInfo.environment
        let source = URL(fileURLWithPath: try #require(environment["HECRAS_EDITOR_ACCEPTANCE_DIRECTORY"]))
        let executable = URL(fileURLWithPath: try #require(environment["HECRAS_BACKEND_TEST_EXECUTABLE"]))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at: source, to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let projectURL = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first { $0.pathExtension == "ras" })
        let document = try ProjectDocument(contentsOf: projectURL)
        let asset = try #require(document.assets.first { $0.section == .plans })
        let client = BackendProcessClient(executableURL: executable)
        let provider = BackendModelProvider(client: client)
        provider.setProject(document)
        let first = ModelEditorSession(provider: provider), second = ModelEditorSession(provider: provider)
        await first.load(asset, kind: .plan); await second.load(asset, kind: .plan)
        #expect(first.loaded && first.canEdit && first.error == nil)
        #expect(first.fields["PlanSettingsPage/ViewModel_SelectedPlan_ComputeTimestep"] == "12.5")
        #expect(first.images["PlanSettingsPage/ViewModel_SelectedPlan_EmbeddedImages"]?.count == 1)
        let description = "PlanSettingsPage/ViewModel_SelectedPlan_Description"
        first.set(description, "SwiftUI 经 C# 服务保存的中文计划 🌊")
        #expect(first.fields["PlanCatalogSummary/Context_Description"] == "SwiftUI 经 C# 服务保存的中文计划 🌊")
        #expect(await first.saveLoadedModel())
        let independent = ModelEditorSession(provider: provider)
        await independent.load(asset, kind: .plan)
        #expect(independent.fields[description] == "SwiftUI 经 C# 服务保存的中文计划 🌊")
        #expect(first.fields["PlanCatalogSummary/Context_Layer_DateLastModified"] == independent.fields["PlanCatalogSummary/Context_Layer_DateLastModified"])
        second.set(description, "这个过期窗口不能覆盖已保存内容")
        #expect(!(await second.saveLoadedModel()))
        #expect(second.modified && second.error != nil)
        first.set("PlanComputeSettingsPage/ViewModel_SelectedPlan_CoreCount", "2")
        #expect(await first.saveLoadedModel())
        let readback = try await provider.load(asset, kind: .plan)
        #expect(readback.fields[description] == "SwiftUI 经 C# 服务保存的中文计划 🌊")
        #expect(readback.fields["PlanComputeSettingsPage/ViewModel_SelectedPlan_CoreCount"] == "2")
    }
}
