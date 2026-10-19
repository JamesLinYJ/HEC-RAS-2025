import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

private struct CatalogSourcePreviewFixtureManifest: Decodable {
    struct Model: Decodable { let kind: String; let name: String; let assetPath: String }
    let projectPath: String
    let models: [Model]
}

struct BackendCatalogSourcePreviewTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_MESH_PREPARE_ACCEPTANCE_DIRECTORY"] != nil
        && ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil)) @MainActor
    func geometryCatalogPreviewReadsSelectedFlowAreaMeshWithoutSavingSource() async throws {
        let fixture = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["HECRAS_MESH_PREPARE_ACCEPTANCE_DIRECTORY"]))
        let executable = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"]))
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog-geometry-mesh-preview-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.copyItem(at: fixture, to: folder)
        defer { try? FileManager.default.removeItem(at: folder) }

        let projectURL = folder.appendingPathComponent("Prepared geometry.ras")
        let document = try ProjectDocument(contentsOf: projectURL)
        let asset = try #require(document.assets.first { $0.name == "Prepare geometry" && $0.section == .geometries })
        let client = BackendProcessClient(executableURL: executable)
        // This exported fixture contains conceptual topology, before the
        // source mesh-generation/Prepare workflow. Publish a real FlowArea in
        // our private copy, then establish the read-only preview baseline.
        let modelProvider = BackendModelProvider(client: client)
        modelProvider.setProject(document)
        let parent = ModelEditorSession(provider: modelProvider)
        await parent.load(asset, kind: .geometry)
        await parent.ensureGeometryTopologyLoaded()
        let topology = try #require(parent.geometryTopology)
        await topology.setField(featureKind: "region", fid: 0, fieldID: "PatchType", value: "TrianglePaver")
        await topology.setField(featureKind: "region", fid: 0, fieldID: "ConstantSize", value: "4")
        await topology.setField(featureKind: "region", fid: 0, fieldID: "SecondaryConstantSize", value: "4")
        await parent.ensureGeometryMeshLoaded()
        let mesh = try #require(parent.geometryMesh)
        await mesh.generateMesh()
        #expect(!mesh.flowAreas.isEmpty)
        #expect(await mesh.requestPrepare())
        #expect(await parent.saveLoadedModel())
        #expect(parent.error == nil)
        let projectBytes = try Data(contentsOf: projectURL)
        let geometryBytes = try Data(contentsOf: asset.url)
        let session = CatalogGeometryMeshPreviewSession()

        await session.load(asset: asset, projectURL: projectURL,
            coreLayerContext: nil,
            requestIdentity: "geometry-catalog-source-acceptance", provider: BackendGeometryMeshProvider(client: client))

        #expect(session.error == nil)
        let map = try #require(session.map)
        #expect(map.extent != nil)
        #expect(!map.cells.isEmpty)
        #expect(map.renderedCellCount == map.cells.count)
        let flowAreaIDs = Set(session.flowAreas.filter(\.hasMesh).map(\.id))
        #expect(!flowAreaIDs.isEmpty)
        #expect(map.cells.allSatisfy { flowAreaIDs.contains($0.flowAreaID) })
        let firstMeshCell = try #require(map.cells.first)
        let selectionExtent = try #require(CatalogGeometryPreviewExtent.enclosing(
            firstMeshCell.coordinates, sourceExtent: map.extent))
        let firstCell = try #require(firstMeshCell.coordinates.first)
        #expect(selectionExtent.minX <= firstCell.x && selectionExtent.maxX >= firstCell.x)
        #expect(selectionExtent.minY <= firstCell.y && selectionExtent.maxY >= firstCell.y)
        let pointFocusExtent = try #require(CatalogGeometryPreviewExtent.enclosing([firstCell], sourceExtent: map.extent))
        let sourceExtent = try #require(map.extent)
        #expect(pointFocusExtent.maxX - pointFocusExtent.minX < (sourceExtent.maxX - sourceExtent.minX) * 0.1)
        #expect(try Data(contentsOf: projectURL) == projectBytes)
        #expect(try Data(contentsOf: asset.url) == geometryBytes)

        // The catalog backup route reads the selected backup itself, even
        // when the current Geometry file is absent. It must not borrow an
        // active editor's geometry or republish the backup into the project.
        let backups = asset.url.deletingLastPathComponent().appendingPathComponent(asset.name + " Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let backup = backups.appendingPathComponent("Selected source backup.h5")
        try geometryBytes.write(to: backup, options: .withoutOverwriting)
        try FileManager.default.removeItem(at: asset.url)
        defer { try? geometryBytes.write(to: asset.url) }
        let backupSession = CatalogGeometryMeshPreviewSession()
        await backupSession.load(asset: ProjectAsset(url: backup, section: .geometries), projectURL: projectURL,
            coreLayerContext: nil,
            requestIdentity: "selected-backup-catalog-source-acceptance", provider: BackendGeometryMeshProvider(client: client))
        #expect(backupSession.error == nil)
        let backupMap = try #require(backupSession.map)
        #expect(backupMap.cells.count == map.cells.count)
        #expect(backupMap.renderedCellCount == map.renderedCellCount)
        #expect(!FileManager.default.fileExists(atPath: asset.url.path))
        #expect(try Data(contentsOf: backup) == geometryBytes)
        #expect(try Data(contentsOf: projectURL) == projectBytes)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_CATALOG_MODEL_ACTION_ACCEPTANCE_DIRECTORY"] != nil
        && ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil)) @MainActor
    func nValueCatalogPreviewReadsSelectedClassificationBackedLayerWithoutSavingSource() async throws {
        let fixture = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["HECRAS_CATALOG_MODEL_ACTION_ACCEPTANCE_DIRECTORY"]))
        let executable = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"]))
        let manifest = try JSONDecoder().decode(CatalogSourcePreviewFixtureManifest.self,
            from: Data(contentsOf: fixture.appendingPathComponent("manifest.json")))
        let model = try #require(manifest.models.first { $0.kind == "NValue" })
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog-nvalue-preview-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.copyItem(at: fixture, to: folder)
        defer { try? FileManager.default.removeItem(at: folder) }

        let projectURL = folder.appendingPathComponent(manifest.projectPath)
        let selectedHDFURL = folder.appendingPathComponent(model.assetPath)
        let document = try ProjectDocument(contentsOf: projectURL)
        let asset = try #require(document.assets.first {
            SourceFilePaths.canonical($0.url) == SourceFilePaths.canonical(selectedHDFURL)
        })
        let projectBytes = try Data(contentsOf: projectURL)
        let sourceFiles = try fileSnapshot(under: folder)
        let client = BackendProcessClient(executableURL: executable)
        let session = CatalogNValuePreviewSession()

        await session.load(asset: asset, projectURL: projectURL,
            requestIdentity: "nvalue-catalog-source-acceptance", provider: BackendCatalogNValuePreviewProvider(client: client))

        #expect(session.error == nil)
        #expect(session.mode == "ClassificationLayer")
        #expect(session.legendStops.count == 7)
        #expect(abs((session.legendStops.first?.value ?? 0) - 0.02) < 0.000001)
        #expect(abs((session.legendStops.last?.value ?? 0) - 0.16) < 0.000001)
        #expect(Set(session.legendStops.map { "\($0.red),\($0.green),\($0.blue),\($0.alpha)" }).count > 1)
        let histogram = try #require(session.histogram)
        #expect(histogram.maximum > histogram.minimum)
        let preview = try #require(session.preview)
        let raster = try #require(preview.rasters.first)
        // The retained EstimateHistogramFrom uses 1,024 bins for varying
        // values, but Histogram.ComputeFrom routes a constant range through
        // SingleValue: [value - 0.1, value + 0.1], one bin, area 1.0.
        let binCount = histogram.binArea.count
        #expect(binCount == 1)
        #expect(histogram.binArea.allSatisfy { $0.isFinite && $0 >= 0 })
        let totalBinArea = histogram.binArea.reduce(0, +)
        #expect(totalBinArea.isFinite && totalBinArea > 0)
        let histogramRange = histogram.maximum - histogram.minimum
        #expect(histogram.binWidth.isFinite && histogram.binWidth > 0)
        #expect(abs(histogramRange - histogram.binWidth * Double(binCount)) < 0.000001)
        let sourceNValue = 0.035 // CatalogModelActionChecks maps its source class to this value.
        #expect(abs((histogram.minimum + histogram.maximum) / 2 - sourceNValue) < 0.000001)
        #expect(abs(histogramRange - 0.2) < 0.000001)
        #expect(abs(histogram.binWidth - 0.2) < 0.000001)
        #expect(abs(totalBinArea - 1) < 0.000001)
        #expect(raster.width > 0 && raster.height > 0 && raster.rgba.count > 0)
        let sourcePreview = try await BackendCatalogNValuePreviewProvider(client: client).load(
            asset: asset, projectURL: projectURL, revision: CatalogPreviewFileRevision.sha256(asset.url))
        let sourceRaster = try #require(sourcePreview.raster)
        let sampledMinimum = try #require(sourceRaster.minimum)
        let sampledMaximum = try #require(sourceRaster.maximum)
        #expect(abs(sampledMinimum - sourceNValue) < 0.000001)
        #expect(abs(sampledMaximum - sourceNValue) < 0.000001)
        #expect(sourcePreview.legendStops.count == session.legendStops.count)
        #expect(sourcePreview.histogram?.binArea == histogram.binArea)
        #expect(raster.rgba.enumerated().contains { $0.offset % 4 == 3 && $0.element > 0 })
        #expect(try Data(contentsOf: projectURL) == projectBytes)
        for (path, bytes) in sourceFiles {
            #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == bytes)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_MESH_PREPARE_ACCEPTANCE_DIRECTORY"] != nil
        && ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil)) @MainActor
    func constantNValueCatalogPreviewKeepsSourceInfiniteExtentUnavailable() async throws {
        let fixture = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["HECRAS_MESH_PREPARE_ACCEPTANCE_DIRECTORY"]))
        let executable = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"]))
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog-nvalue-constant-preview-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.copyItem(at: fixture, to: folder)
        defer { try? FileManager.default.removeItem(at: folder) }

        let projectURL = folder.appendingPathComponent("Prepared geometry.ras")
        let document = try ProjectDocument(contentsOf: projectURL)
        let asset = try #require(document.assets.first { $0.name == "Prepare roughness" && $0.section == .surfaceLayers })
        let projectBytes = try Data(contentsOf: projectURL)
        let sourceBytes = try Data(contentsOf: asset.url)
        let client = BackendProcessClient(executableURL: executable)
        let session = CatalogNValuePreviewSession()

        await session.load(asset: asset, projectURL: projectURL,
            requestIdentity: "nvalue-constant-catalog-source-acceptance", provider: BackendCatalogNValuePreviewProvider(client: client))

        #expect(session.error == nil)
        #expect(session.mode == "Constant")
        #expect(session.preview == nil)
        #expect(session.legendStops.isEmpty)
        #expect(session.histogram == nil)
        #expect(try Data(contentsOf: projectURL) == projectBytes)
        #expect(try Data(contentsOf: asset.url) == sourceBytes)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_TERRAIN_ACCEPTANCE_DIRECTORY"] != nil
        && ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil)) @MainActor
    func terrainCatalogPreviewUsesTheReadOnlySourceBaseline() async throws {
        try await verifyRasterPreview(
            fixtureEnvironmentKey: "HECRAS_TERRAIN_ACCEPTANCE_DIRECTORY",
            projectFilename: "地形输入.ras",
            assetName: "地形编辑",
            modelKind: .terrain,
            summaryKind: .terrain,
            schemaID: "TerrainCatalogSummary"
        )
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_CLASSIFICATION_ACCEPTANCE_DIRECTORY"] != nil
        && ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil)) @MainActor
    func classificationCatalogPreviewUsesTheReadOnlySourceBaseline() async throws {
        try await verifyRasterPreview(
            fixtureEnvironmentKey: "HECRAS_CLASSIFICATION_ACCEPTANCE_DIRECTORY",
            projectFilename: "分类集成.ras",
            assetName: "土地分类",
            modelKind: .surface,
            summaryKind: .classification,
            schemaID: "ClassificationCatalogSummary"
        )
    }

    @MainActor
    private func verifyRasterPreview(
        fixtureEnvironmentKey: String,
        projectFilename: String,
        assetName: String,
        modelKind: ModelEditorKind,
        summaryKind: CatalogSummaryKind,
        schemaID: String
    ) async throws {
        let environment = ProcessInfo.processInfo.environment
        let fixturePath = try #require(environment[fixtureEnvironmentKey])
        let executable = try #require(environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog-source-preview-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: fixturePath), to: folder)
        defer { try? FileManager.default.removeItem(at: folder) }

        let projectURL = folder.appendingPathComponent(projectFilename)
        let document = try ProjectDocument(contentsOf: projectURL)
        let asset = try #require(document.assets.first { $0.name == assetName && $0.section == modelKind.section })
        let projectBytes = try Data(contentsOf: projectURL)
        let sourceHDFBytes = try Data(contentsOf: asset.url)
        let provider = BackendModelProvider(client: .init(executableURL: URL(fileURLWithPath: executable)))
        provider.setProject(document)

        // These fields are present in the real source snapshot and marked
        // read-only by editor-schemas.json. Passing them as edits makes the
        // backend reject the preview request.
        let snapshot = try await provider.load(asset, kind: modelKind)
        #expect(snapshot.fields[schemaID + "/Context_Name"] != nil)
        #expect(snapshot.fields[schemaID + "/Context_Filename"] != nil)
        let revision = try #require(snapshot.sourceRevision)

        // Invoke the production summary preview session, which must carry the
        // original sourceState and revision without submitting snapshot data.
        let session = CatalogModelRasterSummaryPreviewSession()
        await session.load(asset: asset, kind: summaryKind, snapshot: snapshot,
            requestRevision: "catalog-preview-acceptance", provider: provider)

        #expect(session.error == nil)
        let preview = try #require(session.preview)
        #expect(!preview.isEmpty)
        let raster = try #require(preview.rasters.first)
        #expect(raster.width > 0 && raster.height > 0 && raster.rgba.count > 0)
        #expect(snapshot.sourceRevision == revision)
        #expect(try Data(contentsOf: projectURL) == projectBytes)
        #expect(try Data(contentsOf: asset.url) == sourceHDFBytes)
    }

    private func fileSnapshot(under root: URL) throws -> [String: Data] {
        let paths = try FileManager.default.subpathsOfDirectory(atPath: root.path)
            .map { root.appendingPathComponent($0) }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        return try Dictionary(uniqueKeysWithValues: paths.map {
            (SourceFilePaths.canonical($0), try Data(contentsOf: $0))
        })
    }
}
