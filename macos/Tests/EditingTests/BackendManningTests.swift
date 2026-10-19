import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct BackendManningTests {
    private let mode = "ManningsNEditor/NValueLayer_Mode"
    private let association = "ClassificationLayerManningNEditor/NValueLayer_ClassificationLayer"
    private let description = "NValueCatalogSummary/Context_Description"
    private let constant = "ConstantManningsNEditor/NValueLayer_ConstantValue"
    private let table = "ClassificationLayerManningNEditor/InterpretationTable"

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_MANNING_ACCEPTANCE_DIRECTORY"] != nil)) @MainActor
    func sourceDefaultsAndClassificationChangesRemainDiscardableDrafts() async throws {
        let (folder, document, provider, asset) = try setup(); defer { try? FileManager.default.removeItem(at: folder) }
        let editor = ModelEditorSession(provider: provider); await editor.load(asset, kind: .surface)
        #expect(editor.error == nil && editor.availableOperations.contains(.setDefaultNValues))
        let xml = try Data(contentsOf: try #require(document.url))
        let original = try Data(contentsOf: asset.url), baselineDescription = editor.fields[description]
        let water = try #require(editor.rows[table]?.first { $0.values["Key"] == "Open Water" })
        editor.setCell(table: table, rowID: water.id, column: "Value", value: "0.123")
        editor.set(description, "NLCD 保留的中文元数据草稿")
        #expect(await editor.perform(.setDefaultNValues))
        #expect(editor.rows[table]?.first { $0.id == water.id }?.values["Value"] == "0.035")
        #expect(editor.modified && editor.fields[description] == "NLCD 保留的中文元数据草稿")
        #expect(try Data(contentsOf: asset.url) == original)
        let second = try #require(editor.choiceOptions[association]?.first { $0.title == "第二分类" })
        editor.set(association, second.id)
        #expect(await editor.perform(.refreshManning))
        #expect(editor.rows[table]?.contains { $0.values["Key"] == "森林" } == true)
        editor.set(association, "")
        #expect(await editor.perform(.refreshManning))
        #expect(editor.rows[table]?.isEmpty == true && editor.fields[association] == "")
        editor.discardEdits()
        #expect(!editor.modified && editor.fields[description] == baselineDescription)
        #expect(editor.rows[table]?.contains { $0.values["Key"] == "自定中文草地" } == true)
        #expect(try Data(contentsOf: asset.url) == original && Data(contentsOf: try #require(document.url)) == xml)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_MANNING_ACCEPTANCE_DIRECTORY"] != nil)) @MainActor
    func savedRowsModesAndNoneRoundTripThroughBundledSourceHost() async throws {
        let (folder, document, provider, asset) = try setup(); defer { try? FileManager.default.removeItem(at: folder) }
        let editor = ModelEditorSession(provider: provider); await editor.load(asset, kind: .surface)
        let xml = try Data(contentsOf: try #require(document.url))
        let custom = try #require(editor.rows[table]?.first { $0.values["Key"] == "自定中文草地" })
        editor.setCell(table: table, rowID: custom.id, column: "Value", value: "0.092")
        editor.set(description, "真实中文糙率保存")
        #expect(await editor.saveLoadedModel())
        let read = try await provider.load(asset, kind: .surface)
        #expect(read.rows[table]?.first { $0.id == editor.rows[table]?.first(where: { $0.values["Key"] == "自定中文草地" })?.id }?.values["Value"] == "0.092")
        #expect(read.fields[description] == "真实中文糙率保存")
        editor.set(mode, "Constant"); #expect(await editor.perform(.refreshManning))
        editor.set(constant, "0"); #expect(await editor.saveLoadedModel())
        let hidden = try await provider.load(asset, kind: .surface)
        #expect(hidden.fields[constant] == "0" && hidden.rows[table]?.contains { $0.values["Value"] == "0.092" } == true)
        editor.set(mode, "ClassificationLayer"); editor.set(association, "")
        #expect(await editor.perform(.refreshManning)); #expect(await editor.saveLoadedModel())
        let cleared = try await provider.load(asset, kind: .surface)
        #expect(cleared.fields[association] == "" && cleared.rows[table]?.isEmpty == true)
        #expect(try Data(contentsOf: try #require(document.url)) == xml)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_MANNING_ACCEPTANCE_DIRECTORY"] != nil)) @MainActor
    func classificationConflictsKeepDraftAndOriginalHDF() async throws {
        let (folder, _, provider, asset) = try setup(); defer { try? FileManager.default.removeItem(at: folder) }
        let editor = ModelEditorSession(provider: provider); await editor.load(asset, kind: .surface)
        let original = try Data(contentsOf: asset.url)
        let input = try #require(editor.choiceOptions[association]?.first { $0.title == "土地利用" })
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: input.id)); try handle.seekToEnd(); try handle.write(contentsOf: Data("changed classification".utf8)); try handle.close()
        editor.set(description, "外部变化时保留的草稿")
        #expect(await editor.saveLoadedModel() == false)
        #expect(editor.error != nil && editor.modified && editor.fields[description] == "外部变化时保留的草稿")
        #expect(try Data(contentsOf: asset.url) == original)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_MANNING_ACCEPTANCE_DIRECTORY"] != nil)) @MainActor
    func missingMappingIsPopulatedByExplicitNLCDWithoutAutosaving() async throws {
        let (folder, document, provider, _) = try setup(); defer { try? FileManager.default.removeItem(at: folder) }
        let asset = try #require(document.assets.first { $0.section == .surfaceLayers && $0.name == "空解释表" })
        let editor = ModelEditorSession(provider: provider); await editor.load(asset, kind: .surface)
        #expect(editor.rows[table]?.isEmpty == true && editor.availableOperations.contains(.setDefaultNValues))
        let original = try Data(contentsOf: asset.url)
        #expect(await editor.perform(.setDefaultNValues))
        #expect(editor.rows[table]?.count == 4 && editor.rows[table]?.first { $0.values["Key"] == "Open Water" }?.values["Value"] == "0.035")
        #expect(try editor.modified && Data(contentsOf: asset.url) == original)
        #expect(await editor.saveLoadedModel())
        let fresh = try await provider.load(asset, kind: .surface)
        #expect(fresh.rows[table]?.count == 4 && fresh.rows[table]?.first { $0.values["Key"] == "Open Water" }?.values["Value"] == "0.035")
    }
    @MainActor private func setup() throws -> (URL, ProjectDocument, BackendModelProvider, ProjectAsset) {
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let fixture = try #require(ProcessInfo.processInfo.environment["HECRAS_MANNING_ACCEPTANCE_DIRECTORY"])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("manning-" + UUID().uuidString)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: fixture), to: folder)
        let document = try ProjectDocument(contentsOf: folder.appendingPathComponent("糙率集成.ras"))
        let provider = BackendModelProvider(client: .init(executableURL: URL(fileURLWithPath: executable))); provider.setProject(document)
        let asset = try #require(document.assets.first { $0.section == .surfaceLayers && $0.name == "曼宁糙率" })
        return (folder, document, provider, asset)
    }
}
