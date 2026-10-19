import CryptoKit
import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct BackendRasterMapImportWorkflowTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil))
    @MainActor
    func actualTIFFCreatesFirstMapRendersStatsAndReopensThroughSavedConnection() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("raster-map-import-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Project")
        let inputs = root.appendingPathComponent("External Inputs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        let projectURL = folder.appendingPathComponent("Raster.ras")
        let project = try ProjectDocument(name: "Raster", units: "SI")
        try project.save(to: projectURL)
        let projectBytes = try Data(contentsOf: projectURL)
        let rasterURL = inputs.appendingPathComponent("真实栅格.tif")
        let rasterBytes = Self.tiff(value: 42)
        try rasterBytes.write(to: rasterURL)
        let client = BackendProcessClient(executableURL: URL(fileURLWithPath: executable))
        let store = WorkspaceStore(system: SourceWorkflowFixtureServices(recoveryFolder: root.appendingPathComponent("Recovery")),
            modelProvider: BackendModelProvider(client: client))
        store.requestOpen(projectURL)
        try await wait { store.hasProject && !store.isOpeningProject && !store.isMapLoading }
        // Match the real ProjectMapView initializer, which creates the empty
        // Project map state before a layer can be connected to it.
        _ = store.mapState(for: MapState.projectMapID)
        store.descriptionDraft = "保留尚未保存的工程描述"
        #expect(await store.connectMapSource(rasterURL, for: MapState.projectMapID))
        try await wait { !store.isRasterMapLoading && !store.rasterLayers.isEmpty }
        let source = try #require(store.rasterMapSources.first { $0.sourceMapID == MapState.projectMapID })
        let layer = try #require(store.rasterLayers.first { $0.id == source.id && $0.sourceMapID == source.sourceMapID })
        #expect(layer.width > 0 && layer.height > 0 && layer.rgba.count == layer.width * layer.height * 4)
        #expect(layer.rgba.enumerated().contains { $0.offset % 4 == 3 && $0.element != 0 })
        let metadata = try #require(store.rasterMapSourceInfoStats[MapState.projectMapID.uuidString + "|" + source.id])
        #expect(metadata.revision.caseInsensitiveCompare(Self.hash(rasterBytes)) == .orderedSame)
        #expect(metadata.stats.flatMap { Double($0.min) } == 42
            && metadata.stats.flatMap { Double($0.max) } == 42
            && metadata.stats.flatMap { Double($0.mean) } == 42)
        #expect(store.document?.connections.count == 1 && store.isModified)
        #expect(try Data(contentsOf: projectURL) == projectBytes)
        #expect(try Data(contentsOf: rasterURL) == rasterBytes)
        let visualizationURL = projectURL.deletingPathExtension().appendingPathExtension("vis")
        let visualizationBytes = try Data(contentsOf: visualizationURL)
        #expect(!(await store.connectRasterSource(rasterURL, for: MapState.projectMapID)))
        #expect(try Data(contentsOf: visualizationURL) == visualizationBytes)
        #expect(store.document?.connections.count == 1)
        #expect(store.save())
        #expect(try ProjectDocument(contentsOf: projectURL).description == "保留尚未保存的工程描述")
        store.requestClose()
        if store.showDiscardConfirmation { store.discardAndContinue() }
        try #require(store.document == nil)
        let reopened = WorkspaceStore(system: SourceWorkflowFixtureServices(recoveryFolder: root.appendingPathComponent("Recovery 2")),
            modelProvider: BackendModelProvider(client: client))
        reopened.requestOpen(projectURL)
        try await wait { reopened.hasProject && !reopened.isOpeningProject && !reopened.isRasterMapLoading && !reopened.rasterLayers.isEmpty }
        #expect(reopened.document?.connections.count == 1)
        #expect(reopened.rasterMapSources.contains {
            SourceFilePaths.canonical(URL(fileURLWithPath: $0.sourcePath)) == SourceFilePaths.canonical(rasterURL)
        })
        #expect(try Data(contentsOf: rasterURL) == rasterBytes)
        let nodes = try await reopened.sourceMapLayerNodes(MapState.projectMapID)
        let rasterNode = try #require(nodes.first { $0.sourceLocator?.mapType == "SingleBandRasterMapLayer" })
        #expect(await reopened.removeMapSourceNode(rasterNode, mapID: MapState.projectMapID))
        try await wait { !reopened.isRasterMapLoading && reopened.rasterMapSources.isEmpty }
        #expect(reopened.document?.connections.count == 1)
        #expect(try Data(contentsOf: rasterURL) == rasterBytes)
        reopened.requestClose()
        if reopened.showDiscardConfirmation { reopened.discardAndContinue() }
    }

    @MainActor
    private func wait(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw CocoaError(.fileReadUnknown) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }

    /// A complete little-endian, single-band Float32 GeoTIFF. Production GDAL
    /// must decode these samples; no mocked pixel or metadata provider is used.
    private static func tiff(value: Float) -> Data {
        // The retained RasterStatsHelpers path reads cached GDAL statistics;
        // it does not compute missing statistics. Supply the exact statistics
        // of this constant raster as real GeoTIFF metadata, as the source UI expects.
        let statistics = Data(("""
        <GDALMetadata><Item name="STATISTICS_MINIMUM" sample="0">\(value)</Item><Item name="STATISTICS_MAXIMUM" sample="0">\(value)</Item><Item name="STATISTICS_MEAN" sample="0">\(value)</Item><Item name="STATISTICS_STDDEV" sample="0">0</Item></GDALMetadata>
        """ + "\0").utf8)
        let entryCount: UInt16 = 14
        let scaleOffset: UInt32 = 8 + 2 + UInt32(entryCount) * 12 + 4
        let tieOffset = scaleOffset + 24
        let statisticsOffset = tieOffset + 48
        let pixelOffset = statisticsOffset + UInt32(statistics.count)
        var result = Data([0x49, 0x49])
        func u16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { result.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { result.append(contentsOf: $0) } }
        func f64(_ value: Double) { var bits = value.bitPattern.littleEndian; withUnsafeBytes(of: &bits) { result.append(contentsOf: $0) } }
        func entry(_ tag: UInt16, _ type: UInt16, _ count: UInt32, _ value: UInt32) {
            u16(tag); u16(type); u32(count); u32(value)
        }
        u16(42); u32(8); u16(entryCount)
        entry(256, 4, 1, 8); entry(257, 4, 1, 8); entry(258, 3, 1, 32)
        entry(259, 3, 1, 1); entry(262, 3, 1, 1); entry(273, 4, 1, pixelOffset)
        entry(277, 3, 1, 1); entry(278, 4, 1, 8); entry(279, 4, 1, 256)
        entry(284, 3, 1, 1); entry(339, 3, 1, 3)
        entry(33550, 12, 3, scaleOffset); entry(33922, 12, 6, tieOffset)
        entry(42112, 2, UInt32(statistics.count), statisticsOffset)
        u32(0)
        [1.0, 1, 0].forEach(f64)
        [0.0, 0, 0, 0, 8, 0].forEach(f64)
        result.append(statistics)
        for _ in 0..<64 { u32(value.bitPattern) }
        return result
    }
}
