import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct TerrainRasterExportWorkflowTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_TERRAIN_ACCEPTANCE_DIRECTORY"] != nil
        && ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil))
    @MainActor
    func exactTerrainEditorDraftExportsRealTiffAndZoomsCurrentMapToInputExtent() async throws {
        let environment = ProcessInfo.processInfo.environment
        let fixture = URL(fileURLWithPath: try #require(environment["HECRAS_TERRAIN_ACCEPTANCE_DIRECTORY"]))
        let backendURL = URL(fileURLWithPath: try #require(environment["HECRAS_BACKEND_TEST_EXECUTABLE"]))
        try #require(FileManager.default.isExecutableFile(atPath: backendURL.path))

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("terrain-raster-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: fixture, to: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let projectURL = root.appendingPathComponent("地形输入.ras")
        let projectBytes = try Data(contentsOf: projectURL)
        let provider = BackendModelProvider(client: BackendProcessClient(executableURL: backendURL))
        let store = WorkspaceStore(
            system: SourceWorkflowFixtureServices(recoveryFolder: root.appendingPathComponent("Recovery")),
            modelProvider: provider)
        store.requestOpen(projectURL)
        try await waitUntil("Terrain project open") {
            store.document?.url?.standardizedFileURL == projectURL.standardizedFileURL
                && !store.isOpeningProject && !store.assets.isEmpty
        }
        #expect(store.errorMessage == nil)

        let asset = try #require(store.assets.first { $0.section == .terrains && $0.isModelFile })
        let sourceBytes = try Data(contentsOf: asset.url)
        let editor = ModelEditorSession(provider: provider)
        store.registerEditor(editor)
        await editor.load(asset, kind: .terrain)
        #expect(editor.loaded && !editor.isBusy)
        #expect(try store.terrainRasterExportEditor(for: asset) === editor)
        let capture = try #require(editor.captureTerrainRasterExportContext())
        #expect(capture.editorID == editor.id && capture.asset == asset)
        #expect(editor.isCurrentTerrainRasterExportContext(capture))

        let collection = try #require(editor.sourceCollections[TerrainEditorContract.sourceField])
        let inputExtents = collection.items.compactMap { item -> (EditorChoice, TerrainInputValidExtent)? in
            guard let extent = collection.itemDetails[item.id]?.terrainInfo?.validExtent,
                  extent.isFiniteAndOrdered else { return nil }
            return (item, extent)
        }
        let (input, extent) = try #require(inputExtents.first)

        await store.reloadMapLayersAndWait()
        #expect(await store.createMapDocument(kind: .project))
        let mapID = store.lastActiveMapID
        let mapIdentity = store.mapWorkflowIdentity(mapID)
        let mapState = store.mapState(for: mapID)
        let originalLowerLeft = mapState.viewport?.lowerLeft
        let originalUpperRight = mapState.viewport?.upperRight
        #expect(!store.zoomTerrainInputToMap(session: editor, inputID: input.id,
            sourceRevision: "stale-source-revision", extent: extent, mapID: mapID,
            expectedProjectSessionID: store.projectSessionID, expectedMapIdentity: mapIdentity))
        #expect(mapState.viewport?.lowerLeft == originalLowerLeft)
        #expect(mapState.viewport?.upperRight == originalUpperRight)
        #expect(store.zoomTerrainInputToMap(session: editor, inputID: input.id,
            sourceRevision: try #require(editor.sourceFileRevision), extent: extent, mapID: mapID,
            expectedProjectSessionID: store.projectSessionID, expectedMapIdentity: mapIdentity))
        #expect(mapState.viewport?.lowerLeft == MapPoint(x: extent.minX, y: extent.minY))
        #expect(mapState.viewport?.upperRight == MapPoint(x: extent.maxX, y: extent.maxY))

        let fullTerrainPreview = try #require(try await editor.terrainMap(inputID: nil).raster)
        let expectedOutputWidth = max(Int(((fullTerrainPreview.maxX - fullTerrainPreview.minX) / 5)
            .rounded(.toNearestOrEven)), 1)
        let expectedOutputHeight = max(Int(((fullTerrainPreview.maxY - fullTerrainPreview.minY) / 5)
            .rounded(.toNearestOrEven)), 1)

        let lease = try #require(store.beginTerrainRasterExport(
            projectSessionID: store.projectSessionID, captureID: capture.id))
        defer { store.endTerrainRasterExport(lease) }
        #expect(store.isExportingTerrainRaster && store.isRunningProjectTool)
        let operation = try provider.startTerrainRasterExport(capture: capture, cellSize: 5)
        for try await _ in operation.events { }
        let result = try await operation.value()

        #expect(result.state == "completed")
        #expect(SourceFilePaths.canonical(URL(fileURLWithPath: result.sourcePath))
            == SourceFilePaths.canonical(asset.url))
        #expect(result.sourceRevision.caseInsensitiveCompare(try #require(capture.edits.sourceRevision)) == .orderedSame)
        let outputPath = try #require(result.outputPath)
        let output = URL(fileURLWithPath: outputPath)
        #expect(output.pathExtension.lowercased() == "tif")
        let outputBytes = try Data(contentsOf: output)
        let bigTIFFHeader = try #require(outputBytes.count >= 16
            ? Array(outputBytes.prefix(16)) : nil)
        #expect(Array(bigTIFFHeader.prefix(8)) == [0x49, 0x49, 0x2B, 0x00, 0x08, 0x00, 0x00, 0x00])
        let firstDirectoryOffset = (0..<8).reduce(UInt64(0)) { value, byte in
            value | (UInt64(bigTIFFHeader[8 + byte]) << (byte * 8))
        }
        #expect(firstDirectoryOffset >= 16 && firstDirectoryOffset < UInt64(outputBytes.count))
        #expect(try Data(contentsOf: asset.url) == sourceBytes)
        #expect(try Data(contentsOf: projectURL) == projectBytes)
        store.endTerrainRasterExport(lease)
        #expect(!store.isExportingTerrainRaster)

        let outputInspection = try await editor.inspectTerrainInputImport(
            files: [output], expectedIdentity: editor.terrainInputImportIdentity)
        let inspectedOutput = try #require(outputInspection.sources.first {
            SourceFilePaths.canonical(URL(fileURLWithPath: $0.path))
                == SourceFilePaths.canonical(output)
        })
        #expect(inspectedOutput.isValid)
        #expect(inspectedOutput.bandCount == 1)
        #expect(inspectedOutput.width == expectedOutputWidth)
        #expect(inspectedOutput.height == expectedOutputHeight)
        #expect(abs(try #require(inspectedOutput.cellSize) - 5) < 1e-9)
        if outputInspection.targetProjection.isEmpty {
            #expect(inspectedOutput.projection == nil || inspectedOutput.projection?.isEmpty == true)
        } else {
            #expect(inspectedOutput.projection == outputInspection.targetProjection)
        }
        let outputOverviews = try #require(inspectedOutput.overviews)
        #expect(inspectedOutput.overviewCount == outputOverviews.count)
        #expect(outputOverviews.first == "\(expectedOutputWidth) × \(expectedOutputHeight)")

        // Stage the exported file without saving the project, then sample it
        // through the existing terrain reader to verify actual float values.
        let readbackSelection = TerrainInputImportSelection(path: inspectedOutput.path,
            sourceRevision: inspectedOutput.revision, rounding: "None", unitConversion: "None",
            customScaleFactor: nil, sourceID: inspectedOutput.id)
        let stagedOutput = try #require(await editor.appendTerrainInputImport([readbackSelection],
            inspection: outputInspection, stitchTiles: false,
            expectedIdentity: editor.terrainInputImportIdentity))
        let outputDraftToken = try #require(editor.terrainInputImportDraftToken)
        do {
            let stagedOperationCandidate = stagedOutput.operations.first { $0.isStaged }
            let stagedOperation = try #require(stagedOperationCandidate)
            let outputInputID = try #require(stagedOperation.outputInputID)
            let readback = try #require(try await editor.terrainMap(inputID: outputInputID).selectedRaster)
            let readbackMinimum = try #require(readback.minimum)
            let readbackMaximum = try #require(readback.maximum)
            #expect(readback.width == 256 && readback.height == 256)
            #expect(readbackMinimum.isFinite && readbackMaximum.isFinite && readbackMinimum <= readbackMaximum)
            #expect(readback.minX == fullTerrainPreview.minX)
            #expect(readback.maxY == fullTerrainPreview.maxY)
            #expect(abs(readback.maxX - (fullTerrainPreview.minX + Double(expectedOutputWidth) * 5)) < 1e-8)
            #expect(abs(readback.minY - (fullTerrainPreview.maxY - Double(expectedOutputHeight) * 5)) < 1e-8)
            #expect(stride(from: 3, to: readback.rgba.count, by: 4).contains { readback.rgba[$0] > 0 })
        } catch {
            _ = try? await provider.discardTerrainInputImport(asset, draftToken: outputDraftToken)
            throw error
        }
        #expect(try await provider.discardTerrainInputImport(asset, draftToken: outputDraftToken))
        #expect(try Data(contentsOf: asset.url) == sourceBytes)
        #expect(try Data(contentsOf: projectURL) == projectBytes)
    }

    @MainActor
    private func waitUntil(_ label: String, condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        if condition() { return }
        throw TerrainRasterExportTestError.timedOut(label)
    }
}

private enum TerrainRasterExportTestError: Error {
    case timedOut(String)
}
