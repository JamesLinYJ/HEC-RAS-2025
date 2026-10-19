import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct BackendTerrainModificationWorkflowTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_TERRAIN_MODIFICATION_ACCEPTANCE_DIRECTORY"] != nil
        && ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil)) @MainActor
    func editedProfilesAndPropertyScopesSurviveSelectionSwitchesSaveAndReopen() async throws {
        let environment = ProcessInfo.processInfo.environment
        let fixture = try #require(environment["HECRAS_TERRAIN_MODIFICATION_ACCEPTANCE_DIRECTORY"])
        let executable = try #require(environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("terrain-continuous-edit-" + UUID().uuidString)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: fixture), to: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let projectURL = folder.appendingPathComponent("terrain tables.ras")
        let project = try ProjectDocument(contentsOf: projectURL)
        let provider = BackendModelProvider(client: BackendProcessClient(executableURL: URL(fileURLWithPath: executable)))
        provider.setProject(project)
        let asset = try #require(project.assets.first { $0.name == "Terrain tables" })
        let editor = ModelEditorSession(provider: provider)
        await editor.load(asset, kind: .terrain)
        let original = try Data(contentsOf: asset.url)
        let originalXML = try Data(contentsOf: projectURL)
        let source = TerrainEditorContract.sourceField
        let inputs = try #require(editor.sourceCollections[source])
        let channel = try #require(inputs.items.first { inputs.itemDetails[$0.id]?.terrainInfo?.type == "Channel" })
        let levee = try #require(inputs.items.first { inputs.itemDetails[$0.id]?.terrainInfo?.type == "Levee" })
        let channelTable = "ChannelModEditor/Features"
        let profileTable = "ChannelModEditor/Profile"
        let propertyTable = "LeveeModPropertiesEditor/PropertySets"
        let featureTable = "LeveeModsTable"
        #expect(await editor.perform(.selectSource(field: source, id: channel.id)))
        #expect(!editor.modified)
        let channelRow = try #require(editor.rows[channelTable]?.first)
        #expect(await editor.perform(.selectTableRows(table: channelTable, ids: [channelRow.id])))
        let profileRow = try #require(editor.rows[profileTable]?.first)
        editor.setCell(table: profileTable, rowID: profileRow.id, column: "Elevation", value: "55")
        #expect(await editor.perform(.selectSource(field: source, id: levee.id)))
        #expect(editor.modified)
        let property = try #require(editor.rows[propertyTable]?.first)
        #expect(await editor.perform(.selectTableRows(table: propertyTable, ids: [property.id])))
        let scope = "TerrainSelection/\(property.id)/LeveeModPropertiesDetailEditor/"
        editor.set(scope + "Name", "Edited property")
        editor.set(scope + "TopWidthString", "19.25")
        let leveeRow = try #require(editor.rows[featureTable]?.first)
        #expect(await editor.perform(.selectTableRows(table: featureTable, ids: [leveeRow.id])))
        let stagedProperty = try #require(editor.rows[propertyTable]?.first)
        #expect(stagedProperty.values["Name"] == "Edited property")
        #expect(await editor.perform(.selectSource(field: source, id: channel.id)))
        #expect(await editor.perform(.selectTableRows(table: channelTable, ids: [channelRow.id])))
        #expect(editor.rows[profileTable]?.first?.values["Elevation"] == "55")
        #expect(try Data(contentsOf: asset.url) == original)
        #expect(await editor.saveLoadedModel())
        #expect(editor.error == nil)
        #expect(try Data(contentsOf: projectURL) == originalXML)

        let reopened = ModelEditorSession(provider: provider)
        await reopened.load(asset, kind: .terrain)
        let saved = try #require(reopened.sourceCollections[source])
        let savedChannel = try #require(saved.items.first { $0.title == channel.title })
        let savedLevee = try #require(saved.items.first { $0.title == levee.title })
        #expect(await reopened.perform(.selectSource(field: source, id: savedChannel.id)))
        let savedChannelRow = try #require(reopened.rows[channelTable]?.first)
        #expect(await reopened.perform(.selectTableRows(table: channelTable, ids: [savedChannelRow.id])))
        #expect(reopened.rows[profileTable]?.first?.values["Elevation"] == "55")
        #expect(await reopened.perform(.selectSource(field: source, id: savedLevee.id)))
        let savedProperty = try #require(reopened.rows[propertyTable]?.first)
        #expect(savedProperty.values["Name"] == "Edited property")
        #expect(await reopened.perform(.selectTableRows(table: propertyTable, ids: [savedProperty.id])))
        let savedScope = "TerrainSelection/\(savedProperty.id)/LeveeModPropertiesDetailEditor/"
        #expect(reopened.fields[savedScope + "TopWidthString"] == "19.25")
        #expect(!reopened.modified)
    }
}
