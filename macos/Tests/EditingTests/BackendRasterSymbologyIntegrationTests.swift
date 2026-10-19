import Foundation
import Testing
import RASWorkspaceCore
@testable import HECRAS2025

struct BackendRasterSymbologyIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_RASTER_SYMBOLOGY_ACCEPTANCE_DIRECTORY"] != nil &&
                   ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil))
    @MainActor
    func actualGeoTIFFAndVisualizationApplyThroughTheBundledBackend() async throws {
        let environment = ProcessInfo.processInfo.environment
        let fixturePath = try #require(environment["HECRAS_RASTER_SYMBOLOGY_ACCEPTANCE_DIRECTORY"])
        let executablePath = try #require(environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let fixture = URL(fileURLWithPath: fixturePath, isDirectory: true)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("raster-symbology-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.copyItem(at: fixture, to: folder)
        defer { try? FileManager.default.removeItem(at: folder) }

        let projectURL = folder.appendingPathComponent("Map.ras")
        let visualizationURL = folder.appendingPathComponent("Map.vis")
        let rasterURL = folder.appendingPathComponent("elevation.tif")
        let originalRaster = try Data(contentsOf: rasterURL)
        let originalVisualization = try Data(contentsOf: visualizationURL)
        let document = try VisualizationDocument(projectURL: projectURL)
        let mapID = UUID()
        let source = try #require(document.singleBandRasterMapSources().first).assigning(mapID: mapID)
        #expect(source.mapIndex == 0 && source.mapName == "Map" && source.mapType == "Project")
        #expect(source.nodePath == [0] && source.sourcePath == rasterURL.resolvingSymlinksInPath().path)

        let localView = SavedMapView(name: "Unsaved local map view",
            lowerLeft: MapPoint(x: 0, y: 0), upperRight: MapPoint(x: 4, y: 5))
        try document.add(localView)
        #expect(document.modified)

        var installedLayer: MapRasterLayer?
        let client = BackendProcessClient(executableURL: URL(fileURLWithPath: executablePath))
        let provider = BackendRasterSymbologyProvider(
            client: client,
            sources: { [source] }, viewport: { _ in nil }, projectXML: { nil },
            installLayer: { installedLayer = $0 },
            acceptVisualization: { oldRevision, newRevision in
                try document.acceptExternalRasterSymbologyChange(
                    expectedPreviousRevision: oldRevision, newRevision: newRevision)
            })
        let context = RasterSymbologyContext(projectSessionID: UUID(), mapID: mapID, assetID: source.id)

        let snapshot = try #require(try await provider.snapshot(context))
        #expect(snapshot.draft.name == "Source ramp")
        #expect(snapshot.draft.stops.map(\.value) == [0, 20])
        #expect(snapshot.interpolatedSurfaceFillContext?.colorValues == [0, 20])
        let initialLayer = try await provider.loadMapLayer(source)
        #expect(initialLayer.sourceMapID == mapID)
        #expect(initialLayer.rgba.count == initialLayer.width * initialLayer.height * 4)

        var edited = snapshot.draft
        edited.name = "Swift applied ramp"
        edited.stops[0].color = "00FF00FF"
        edited.stops[1].color = "FFFFFFFF"
        edited.isEditing = true
        try await provider.apply(edited, context: context)

        let appliedLayer = try #require(installedLayer)
        #expect(appliedLayer.sourceMapID == mapID)
        #expect(appliedLayer.rgba != initialLayer.rgba)
        #expect(try Data(contentsOf: rasterURL) == originalRaster)
        #expect(try Data(contentsOf: visualizationURL) != originalVisualization)
        #expect(document.views.contains { $0.id == localView.id && $0.name == localView.name })
        #expect(document.modified)

        try document.save()
        let persistedDocument = try VisualizationDocument(projectURL: projectURL)
        #expect(persistedDocument.views.contains { $0.name == localView.name })
        let persistedSource = try #require(persistedDocument.singleBandRasterMapSources().first).assigning(mapID: mapID)
        let persistedProvider = BackendRasterSymbologyProvider(
            client: client, sources: { [persistedSource] }, viewport: { _ in nil }, projectXML: { nil },
            installLayer: { _ in }, acceptVisualization: { _, _ in })
        let reread = try #require(try await persistedProvider.snapshot(context))
        #expect(reread.draft.name == edited.name)
        #expect(reread.draft.stops.map(\.value) == edited.stops.map(\.value))
        #expect(reread.draft.stops.map(\.color) == edited.stops.map(\.color))

        let acceptedVisualization = try Data(contentsOf: visualizationURL)
        var externallyChangedVisualization = acceptedVisualization
        externallyChangedVisualization.append(contentsOf: Data("\n".utf8))
        try externallyChangedVisualization.write(to: visualizationURL)
        var documentRejectedExternalChange = false
        do { _ = try persistedDocument.singleBandRasterMapSources() }
        catch { documentRejectedExternalChange = true }
        #expect(documentRejectedExternalChange)
        let visualizationError = await backendErrorCode {
            _ = try await persistedProvider.snapshot(context)
        }
        #expect(visualizationError == "sourceChanged")
        #expect(try Data(contentsOf: visualizationURL) == externallyChangedVisualization)

        try acceptedVisualization.write(to: visualizationURL)
        var externallyChangedRaster = originalRaster
        externallyChangedRaster.append(0xFF)
        try externallyChangedRaster.write(to: rasterURL)
        let rasterError = await backendErrorCode {
            _ = try await persistedProvider.snapshot(context)
        }
        #expect(rasterError == "sourceChanged")
        #expect(try Data(contentsOf: visualizationURL) == acceptedVisualization)
    }

    @MainActor
    private func backendErrorCode(_ operation: @MainActor () async throws -> Void) async -> String? {
        do { try await operation(); return nil }
        catch let error as BackendServiceError { return error.code }
        catch { return "unexpected" }
    }
}
