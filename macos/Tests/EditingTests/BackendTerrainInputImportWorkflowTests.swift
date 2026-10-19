import Foundation
import Testing
@testable import HECRAS2025
@testable import RASWorkspaceCore

struct BackendTerrainInputImportWorkflowTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_TERRAIN_ACCEPTANCE_DIRECTORY"] != nil
        && ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil)) @MainActor
    func rawSourcePresetScalesOnceThroughActualStagingSaveAndReopen() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let fixture = try #require(ProcessInfo.processInfo.environment["HECRAS_TERRAIN_ACCEPTANCE_DIRECTORY"])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("terrain-usgs-defaults-" + UUID().uuidString)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: fixture), to: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let projectURL = folder.appendingPathComponent("地形输入.ras")
        let project = try ProjectDocument(contentsOf: projectURL)
        let provider = BackendModelProvider(client: BackendProcessClient(executableURL: URL(fileURLWithPath: executable)))
        provider.setProject(project)
        let asset = try #require(project.assets.first { $0.name == "地形编辑" })
        let editor = ModelEditorSession(provider: provider)
        await editor.load(asset, kind: .terrain)
        let collection = try #require(editor.sourceCollections[TerrainEditorContract.sourceField])
        let rawPath = try #require(collection.items.compactMap {
            collection.itemDetails[$0.id]?.terrainInfo
        }.first { $0.type == "Raster" }?.filename)
        let rawURL = URL(fileURLWithPath: rawPath)
        let rawBytes = try Data(contentsOf: rawURL)
        let hdfBytes = try Data(contentsOf: asset.url)
        let projectBytes = try Data(contentsOf: projectURL)
        let identity = editor.terrainInputImportIdentity
        let inspection = try await editor.inspectTerrainInputImport(files: [rawURL], expectedIdentity: identity)
        let source = try #require(inspection.sources.first { $0.isValid })
        // A source helper returns a Float scale. Feed that exact value into the
        // same per-file preset used by the USGS parent, without a second scale.
        let factor = Double(Float(3.280839895013123))
        let preset = TerrainInputImportInitialSettings(sourceRevision: source.revision,
            scaleFactor: factor, rounding: "ThirtySeconds")
        let selection = try preset.selection(for: source)
        let result = try #require(await editor.appendTerrainInputImport([selection], inspection: inspection,
            stitchTiles: true, expectedIdentity: identity))
        let operation = try #require(result.operations.first { $0.isStaged })
        let inputID = try #require(operation.outputInputID)
        let inputName = try #require(operation.outputName)
        let preview = try #require(try await editor.terrainMap(inputID: inputID).selectedRaster)
        // Retained TiffExportEngine wraps rounding before scale. This source
        // fixture is exactly 42, so ThirtySeconds preserves 42 before the
        // helper's Float scale is applied once.
        let expected = Double(Float(42) * Float(factor))
        #expect(abs(try #require(preview.minimum) - expected) < 0.00001)
        #expect(abs(try #require(preview.maximum) - expected) < 0.00001)
        #expect(try Data(contentsOf: asset.url) == hdfBytes)
        #expect(await editor.saveLoadedModel())
        let reopened = ModelEditorSession(provider: provider)
        await reopened.load(asset, kind: .terrain)
        let savedID = try #require(reopened.sourceCollections[TerrainEditorContract.sourceField]?.items.first {
            $0.title == inputName
        }?.id)
        let savedPreview = try #require(try await reopened.terrainMap(inputID: savedID).selectedRaster)
        #expect(abs(try #require(savedPreview.minimum) - expected) < 0.00001)
        #expect(try Data(contentsOf: rawURL) == rawBytes)
        #expect(try Data(contentsOf: projectURL) == projectBytes)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_TERRAIN_ACCEPTANCE_DIRECTORY"] != nil
        && ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil)) @MainActor
    func actualProviderStagesImportsThenNormalSavePersistsThemWithoutChangingProjectXMLOrSourceRaster() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let fixture = try #require(ProcessInfo.processInfo.environment["HECRAS_TERRAIN_ACCEPTANCE_DIRECTORY"])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("terrain-input-import-" + UUID().uuidString)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: fixture), to: folder)
        defer { try? FileManager.default.removeItem(at: folder) }

        let projectURL = folder.appendingPathComponent("地形输入.ras")
        let project = try ProjectDocument(contentsOf: projectURL)
        let provider = BackendModelProvider(client: BackendProcessClient(executableURL: URL(fileURLWithPath: executable)))
        provider.setProject(project)
        let asset = try #require(project.assets.first { $0.name == "地形编辑" })
        let editor = ModelEditorSession(provider: provider)
        await editor.load(asset, kind: .terrain)

        let sourceField = TerrainEditorContract.sourceField
        let originalCollection = try #require(editor.sourceCollections[sourceField])
        let rasterChoice = try #require(originalCollection.items.first {
            originalCollection.itemDetails[$0.id]?.terrainInfo?.type == "Raster"
        })
        let rasterPath = try #require(originalCollection.itemDetails[rasterChoice.id]?.terrainInfo?.filename)
        let rasterURL = URL(fileURLWithPath: rasterPath)
        #expect(FileManager.default.fileExists(atPath: rasterURL.path))
        let originalHDF = try Data(contentsOf: asset.url)
        let originalProjectXML = try Data(contentsOf: projectURL)
        let originalRaster = try Data(contentsOf: rasterURL)
        let originalRevision = editor.sourceFileRevision
        let originalIDs = Set(originalCollection.items.map(\.id))

        let identity = editor.terrainInputImportIdentity
        let inspection = try await editor.inspectTerrainInputImport(files: [rasterURL], expectedIdentity: identity)
        let inspected = try #require(inspection.sources.first { $0.path == rasterURL.path && $0.isValid })
        #expect(inspected.bandCount == 1 && inspected.width != nil && inspected.height != nil)
        #expect(!editor.modified)
        #expect(try Data(contentsOf: asset.url) == originalHDF)

        let selection = TerrainInputImportSelection(path: inspected.path, sourceRevision: inspected.revision,
            rounding: "None", unitConversion: "Default", customScaleFactor: nil)
        let appendResult = await editor.appendTerrainInputImport([selection], inspection: inspection,
            stitchTiles: true, expectedIdentity: identity)
        let appended = try #require(appendResult)
        #expect(appended.batchStatus == "Completed")
        #expect(appended.operations.count == 1)
        #expect(appended.operations[0].status == "Staged")
        let draftToken = try #require(editor.terrainInputImportDraftToken)
        #expect(draftToken.count == 32 && draftToken.allSatisfy(\.isHexDigit) && draftToken == draftToken.lowercased())
        #expect(editor.sourceFileRevision == originalRevision)
        #expect(try Data(contentsOf: asset.url) == originalHDF)
        #expect(try Data(contentsOf: projectURL) == originalProjectXML)

        let stagedCollection = try #require(editor.sourceCollections[sourceField])
        let imported = try #require(stagedCollection.items.first { !originalIDs.contains($0.id) })
        let importedName = imported.title
        let preview = try await editor.terrainMap(inputID: imported.id)
        #expect(preview.raster != nil)
        #expect(try Data(contentsOf: asset.url) == originalHDF)
        #expect(try Data(contentsOf: projectURL) == originalProjectXML)

        #expect(await editor.saveLoadedModel())
        #expect(editor.terrainInputImportDraftToken == nil)
        #expect(try Data(contentsOf: asset.url) != originalHDF)
        #expect(try Data(contentsOf: projectURL) == originalProjectXML)
        #expect(try Data(contentsOf: rasterURL) == originalRaster)

        let reopened = try await provider.load(asset, kind: .terrain)
        let reopenedCollection = try #require(reopened.sourceCollections[sourceField])
        #expect(reopenedCollection.items.count == originalCollection.items.count + 1)
        let reopenedImported = try #require(reopenedCollection.items.first { $0.title == importedName })
        #expect(reopenedCollection.itemDetails[reopenedImported.id]?.terrainInfo?.type == "Raster")
        #expect(reopened.terrainInputImportDraftToken == nil)
        let reopenedEditor = ModelEditorSession(provider: provider)
        await reopenedEditor.load(asset, kind: .terrain)
        let reopenedPreview = try await reopenedEditor.terrainMap(inputID: reopenedImported.id)
        #expect(reopenedPreview.raster != nil)
    }

}
