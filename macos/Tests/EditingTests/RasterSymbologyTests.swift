import Foundation
import Testing
import RASWorkspaceCore
@testable import HECRAS2025

@MainActor
private final class LiveRasterSources {
    var values: [RasterMapSourceDescriptor]
    init(_ values: [RasterMapSourceDescriptor]) { self.values = values }
}

@MainActor
private final class RasterSymbologyFixtureProvider: RasterSymbologyProvider {
    var badHistogram = false
    var deferredSelection = false
    var snapshotAdditionalOptions: [RasterPlotOption] = []
    private(set) var appliedAdditionalOptions: [RasterPlotOption]?
    private var completion: CheckedContinuation<RasterSymbologyDraft, any Error>?
    private var started: CheckedContinuation<Void, Never>?
    func snapshot(_ context: RasterSymbologyContext) async throws -> RasterSymbologySnapshot? {
        .init(draft: makeDraft(name: context.assetID ?? ""), palettes: RasterPalette.defaults,
              additionalOptions: snapshotAdditionalOptions)
    }
    func makeDraft(name: String) -> RasterSymbologyDraft {
        .init(paletteID: "Depths", name: name, stops: [.init(color: "0000FFFF", value: 10), .init(color: "FFFFFFFF", value: 20), .init(color: "FF0000FF", value: 30)], valueSource: .manual, grayscale: false, isEditing: true, updateHistogramWithView: false, canComputeHistogram: true)
    }
    func selectPalette(_ id: String, draft: RasterSymbologyDraft, context: RasterSymbologyContext) async throws -> RasterSymbologyDraft {
        if deferredSelection { return try await withCheckedThrowingContinuation { completion = $0; started?.resume(); started = nil } }
        return draft
    }
    func histogram(count: Int, forView: Bool, context: RasterSymbologyContext) async throws -> [Double] { badHistogram ? [1] : (0..<count).map(Double.init) }
    func apply(_ draft: RasterSymbologyDraft, additionalOptions: [RasterPlotOption],
               context: RasterSymbologyContext) async throws {
        appliedAdditionalOptions = additionalOptions
    }
    func reset(_ context: RasterSymbologyContext) async throws -> RasterSymbologySnapshot { try await snapshot(context)! }
    func savePalette(_ draft: RasterSymbologyDraft, name: String, context: RasterSymbologyContext) async throws -> [RasterPalette] { throw CocoaError(.fileWriteNoPermission) }
    func deletePalette(_ id: String, context: RasterSymbologyContext) async throws -> [RasterPalette] { [] }
    func waitForStart() async { if completion == nil { await withCheckedContinuation { started = $0 } } }
    func finish() { completion?.resume(returning: makeDraft(name: "stale")); completion = nil }
}

struct RasterSymbologyTests {
    private struct RequestHandshakeTimeout: Error {}

    private func makeSource(mapID: UUID, visualizationRevision: String = "old-vis") -> RasterMapSourceDescriptor {
        RasterMapSourceDescriptor(id: "vis-map-0-node-0.0", projectPath: "/tmp/Project.ras",
            visualizationPath: "/tmp/Project.vis", visualizationRevision: visualizationRevision,
            mapIndex: 0, mapName: "Hydro", mapType: "Project", nodePath: [0, 0],
            nodeName: "Depth", mapLayerType: "SingleBandRasterMapLayer",
            filename: "depth.tif", filenameRelative: "depth.tif", sourcePath: "/tmp/depth.tif",
            sourceMapID: mapID, sourceRevision: "source-sha")
    }
    private func makeHydratedGdbSource(mapID: UUID, visualizationRevision: String,
                                       manifestRevision: String = String(repeating: "A", count: 64)) -> RasterMapSourceDescriptor {
        let projectPath = "/tmp/Project.ras"
        let projectXML = "<Project />"
        let sourcePath = "/tmp/elevation.gdb"
        let map = GdbRasterSymbologyMapCapture(projectPath: projectPath, projectXml: projectXML,
            projectXmlSHA: "project-xml-sha", mapID: mapID.uuidString, mapIndex: 0,
            mapName: "Hydro", mapType: "Project", expectedVisualizationRevision: visualizationRevision)
        let node = GdbRasterSymbologyNodeCapture(rootName: "Map", nodeType: "MapLayer",
            nodeName: "Elevation", nodePath: [0, 0], assetID: sourcePath,
            mapType: "SingleBandRasterMapLayer", filename: "GDB:elevation.gdb:table=Elevation",
            filenameRelative: "../elevation.gdb")
        let source = GdbMapSourceIdentity(sourcePath: sourcePath, revision: manifestRevision,
            files: [.init(relativePath: "a00000001.gdbtable", length: 128,
                          revision: String(repeating: "B", count: 64))])
        let context = GdbRasterSymbologyContext(map: map, node: node)
        let identity = GdbRasterSymbologyIdentity(map: map, node: node, source: source)
        return RasterMapSourceDescriptor(id: "vis-map-0-node-0.0", projectPath: projectPath,
            visualizationPath: "/tmp/Project.vis", visualizationRevision: visualizationRevision,
            mapIndex: 0, mapName: "Hydro", mapType: "Project", nodePath: [0, 0],
            nodeName: "Elevation", mapLayerType: "SingleBandRasterMapLayer",
            filename: node.filename, filenameRelative: node.filenameRelative, sourcePath: sourcePath,
            sourceMapID: mapID, sourceRevision: manifestRevision,
            gdbSourceContext: context, gdbSource: identity)
    }
    private func makeBackendClient(payload: String, marker: URL,
                                   expectedMethod: String? = nil) -> BackendProcessClient {
        let encodedPayload = Data(payload.utf8).base64EncodedString()
        let encodedMethod = Data((expectedMethod ?? "").utf8).base64EncodedString()
        let script = """
        import base64, json, os, sys, time
        request = json.load(sys.stdin)
        expected_method = base64.b64decode("\(encodedMethod)").decode("utf-8")
        if expected_method and request.get("method") != expected_method:
            print(f"unexpected test route: {request.get('method')!r}", file=sys.stderr)
            sys.exit(2)
        marker_path = sys.argv[-1]
        try:
            with open(marker_path, encoding="ascii") as marker:
                request_count = int(marker.read())
        except (FileNotFoundError, ValueError):
            request_count = 0
        request_count += 1
        with open(marker_path, "w", encoding="ascii") as marker:
            marker.write(str(request_count))
        release_path = f"{marker_path}.{request_count}.release"
        deadline = time.monotonic() + 30
        while not os.path.exists(release_path):
            if time.monotonic() >= deadline:
                print("timed out waiting for test release", file=sys.stderr)
                sys.exit(124)
            time.sleep(0.01)
        result = json.loads(base64.b64decode("\(encodedPayload)").decode("utf-8"))
        print(json.dumps({"id": request["id"], "result": result}, separators=(",", ":")))
        """
        return BackendProcessClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
                                    arguments: ["-c", script, marker.path])
    }

    @Test @MainActor func ordinaryRasterLayerLoadsThroughManifestRoute() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("requests")
        defer { releaseRequest(1, marker: marker) }
        let mapID = UUID()
        let source = makeSource(mapID: mapID)
        let payload = """
        {"previousVisualizationRevision":"old-vis","visualizationRevision":"old-vis","sourceRevision":"source-sha","raster":{"id":"\(source.id)","sourceMapID":"\(mapID.uuidString)","name":"Depth","width":1,"height":1,"rgba":"AAAAAA==","minX":0,"minY":0,"maxX":1,"maxY":1}}
        """
        let liveSources = LiveRasterSources([source])
        let provider = BackendRasterSymbologyProvider(
            client: makeBackendClient(payload: payload, marker: marker,
                expectedMethod: "map.raster.layer.load"),
            sources: { liveSources.values }, viewport: { _ in nil }, installLayer: { _ in },
            acceptVisualization: { _, _ in })
        let pending = Task { try await provider.loadMapLayerWithProperties(source) }
        try await waitForRequestCount(1, marker: marker)
        try signalRelease(1, marker: marker)
        let loaded = try await pending.value
        #expect(loaded.layer.id == source.id)
        #expect(loaded.layer.sourceMapID == mapID)
        #expect(loaded.sourceRevision == "source-sha")
    }

    @Test @MainActor func gdbRasterLayerLoadKeepsNestedIdentityRoute() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("requests")
        defer { releaseRequest(1, marker: marker) }
        let mapID = UUID()
        let source = makeHydratedGdbSource(mapID: mapID, visualizationRevision: "old-vis")
        let manifest = try #require(source.gdbSource?.source.revision)
        let payload = """
        {"previousVisualizationRevision":"old-vis","visualizationRevision":"old-vis","sourceRevision":"\(manifest)","snapshot":{"draft":{"paletteID":null,"name":"Elevation","stops":[{"id":"00000000-0000-0000-0000-000000000001","color":"000000FF","value":0},{"id":"00000000-0000-0000-0000-000000000002","color":"FFFFFFFF","value":1}],"valueSource":"Manual","grayscale":false,"isEditing":false,"updateHistogramWithView":false,"canComputeHistogram":true},"palettes":[],"surfaceFillValues":[0,1],"plotOptions":[]},"raster":{"id":"\(source.id)","sourceMapID":"\(mapID.uuidString)","name":"Elevation","width":1,"height":1,"rgba":"AAAAAA==","minX":0,"minY":0,"maxX":1,"maxY":1}}
        """
        let liveSources = LiveRasterSources([source])
        let provider = BackendRasterSymbologyProvider(
            client: makeBackendClient(payload: payload, marker: marker,
                expectedMethod: "rasterMap.load"),
            sources: { liveSources.values }, viewport: { _ in nil },
            projectXML: { "<Project />" }, installLayer: { _ in },
            acceptVisualization: { _, _ in })
        let pending = Task { try await provider.loadMapLayerWithProperties(source) }
        try await waitForRequestCount(1, marker: marker)
        try signalRelease(1, marker: marker)
        let loaded = try await pending.value
        #expect(loaded.layer.id == source.id)
        #expect(loaded.layer.sourceMapID == mapID)
        #expect(loaded.sourceRevision == nil)
    }
    private func waitForRequestCount(_ count: Int, marker: URL) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(15))
        while clock.now < deadline {
            if let data = try? Data(contentsOf: marker),
               let observedCount = Int(String(decoding: data, as: UTF8.self)),
               observedCount >= count { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw RequestHandshakeTimeout()
    }
    private func releaseRequest(_ count: Int, marker: URL) {
        let release = URL(fileURLWithPath: "\(marker.path).\(count).release")
        try? Data().write(to: release, options: .atomic)
    }
    private func signalRelease(_ count: Int, marker: URL) throws {
        let release = URL(fileURLWithPath: "\(marker.path).\(count).release")
        try Data().write(to: release, options: .atomic)
    }

    @Test func exportedSourcePalettesPreserveDistinctIdsAndTransparency() throws {
        let palettes = RasterPalette.defaults
        #expect(palettes.count == 41)
        #expect(Set(palettes.map(\.id)).count == palettes.count)
        #expect(palettes.filter { $0.name == "Gray To Red" }.count == 2)
        let error = try #require(palettes.first { $0.id == "WSError" })
        #expect(error.colors.contains { $0.hasSuffix("00") })
        #expect(palettes.allSatisfy { $0.values == nil })
    }
    @Test @MainActor func sourceModesAndMalformedHistogramPreserveDraft() async throws {
        let provider = RasterSymbologyFixtureProvider(), session = RasterSymbologySession()
        let context = RasterSymbologyContext(projectSessionID: UUID(), mapID: UUID(), assetID: "raster")
        await session.load(context: context, provider: provider)
        await session.setSource(.linear, provider: provider)
        session.edit { $0.stops[0].value = 0 }
        #expect(session.draft?.stops.map(\.value) == [0, 15, 30])
        #expect(session.draft?.valueIsEditable(at: 1) == false)
        provider.badHistogram = true
        let original = session.draft
        await session.setSource(.histogram, provider: provider)
        #expect(session.draft == original)
        #expect(session.error != nil)
        await session.setSource(.manual, provider: provider)
        let id = try #require(session.draft?.stops.first?.id)
        await session.changeRows(at: id, adding: true, provider: provider)
        #expect(session.draft?.stops.map(\.value) == [0, 0, 15, 30])
        #expect(session.draft?.valueIsIncreasing(at: 1) == false)
        #expect(session.draft?.valueIsEditable(at: 1) == true)
        let beforeSave = session.draft
        #expect(await session.save(name: "Custom", provider: provider) == false)
        #expect(session.draft == beforeSave)
    }

    @Test @MainActor func applyForwardsEditedTransientPlotOptions() async throws {
        let provider = RasterSymbologyFixtureProvider(), session = RasterSymbologySession()
        provider.snapshotAdditionalOptions = [
            .init(id: "ShowStrokeVertices", title: "Show stroke vertices", isBoolean: true,
                  value: "false", choices: [], isEnabled: true, description: nil)
        ]
        await session.load(context: .init(projectSessionID: UUID(), mapID: UUID(), assetID: "raster"),
                           provider: provider)
        session.setAdditional("ShowStrokeVertices", value: "true")

        #expect(await session.apply(provider: provider))
        #expect(provider.appliedAdditionalOptions?.count == 1)
        #expect(provider.appliedAdditionalOptions?.first?.id == "ShowStrokeVertices")
        #expect(provider.appliedAdditionalOptions?.first?.value == "true")
    }
    @Test @MainActor func latePaletteSelectionCannotReplaceNewLayerDraft() async throws {
        let provider = RasterSymbologyFixtureProvider(), session = RasterSymbologySession()
        let project = UUID(), map = UUID()
        await session.load(context: .init(projectSessionID: project, mapID: map, assetID: "first"), provider: provider)
        provider.deferredSelection = true
        let selection = Task { await session.choose("Terrain", provider: provider) }
        await provider.waitForStart()
        await session.load(context: .init(projectSessionID: project, mapID: map, assetID: "second"), provider: provider)
        provider.finish(); await selection.value
        #expect(session.draft?.name == "second")
        #expect(session.selectedPaletteID == "Depths")
        #expect(!session.busy)
    }

    @Test @MainActor func providerRejectsMutationWhenLiveSourceListIsEmpty() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let visualization = directory.appendingPathComponent("Map.vis")
        let original = Data("<Ras><Maps/><Symbology/><Views/></Ras>".utf8)
        try original.write(to: visualization)

        var acceptedRevisions = 0
        var mutationStates: [Bool] = []
        let provider = BackendRasterSymbologyProvider(
            client: BackendProcessClient(executableURL: URL(fileURLWithPath: "/missing-raster-backend")),
            sources: { [] }, viewport: { _ in nil }, projectXML: { nil },
            installLayer: { _ in },
            acceptVisualization: { _, _ in acceptedRevisions += 1 })
        provider.onMutationRunningChanged = { mutationStates.append($0) }
        let context = RasterSymbologyContext(projectSessionID: UUID(), mapID: UUID(), assetID: "vis-map-0-node-0")
        let draft = RasterSymbologyDraft(paletteID: nil, name: "Ramp",
            stops: [.init(color: "000000FF", value: 0), .init(color: "FFFFFFFF", value: 1)],
            valueSource: .manual, grayscale: false, isEditing: true,
            updateHistogramWithView: false, canComputeHistogram: true)

        var rejectedCode: String?
        do { try await provider.apply(draft, additionalOptions: [], context: context) }
        catch let error as BackendServiceError { rejectedCode = error.code }
        catch { rejectedCode = "unexpected" }
        #expect(rejectedCode == "notFound")
        #expect(mutationStates == [true, false])
        #expect(acceptedRevisions == 0)
        #expect((try Data(contentsOf: visualization)) == original)
    }

    @Test @MainActor func providerRejectsAReadThatFinishesAfterItsSourceDisappears() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("requests")
        defer {
            releaseRequest(1, marker: marker)
            releaseRequest(2, marker: marker)
        }
        let mapID = UUID()
        let source = makeSource(mapID: mapID)
        let payload = """
        {"previousVisualizationRevision":"old-vis","visualizationRevision":"old-vis","sourceRevision":"source-sha","snapshot":{"draft":{"paletteID":null,"name":"Depth","stops":[{"id":"00000000-0000-0000-0000-000000000001","color":"000000FF","value":0},{"id":"00000000-0000-0000-0000-000000000002","color":"FFFFFFFF","value":1}],"valueSource":"Manual","grayscale":false,"isEditing":false,"updateHistogramWithView":false,"canComputeHistogram":true},"palettes":[],"surfaceFillValues":[0,1]},"raster":{"id":"vis-map-0-node-0.0","sourceMapID":"\(mapID.uuidString)","name":"Depth","width":1,"height":1,"rgba":"AAAAAA==","minX":0,"minY":0,"maxX":1,"maxY":1}}
        """
        let client = makeBackendClient(payload: payload, marker: marker)
        let liveSources = LiveRasterSources([source])
        let provider = BackendRasterSymbologyProvider(
            client: client,
            sources: { liveSources.values }, viewport: { _ in nil }, installLayer: { _ in },
            acceptVisualization: { _, _ in })
        let context = RasterSymbologyContext(projectSessionID: UUID(), mapID: mapID, assetID: source.id)

        let pending = Task { try await provider.snapshot(context) }
        try await waitForRequestCount(1, marker: marker)
        liveSources.values = []
        try signalRelease(1, marker: marker)
        do {
            _ = try await pending.value
            Issue.record("A stale raster response was accepted after its source disappeared.")
        } catch let error as BackendServiceError {
            #expect(error.code == "notFound")
        } catch {
            Issue.record("Unexpected error while rejecting the stale raster read: \(error)")
        }

        liveSources.values = [source]
        let refreshed = Task { try await provider.snapshot(context) }
        try await waitForRequestCount(2, marker: marker)
        try signalRelease(2, marker: marker)
        let snapshot = try await refreshed.value
        #expect(snapshot?.draft.name == "Depth")
    }

    @Test @MainActor func providerRejectsConcurrentRasterMutations() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("requests")
        defer { releaseRequest(1, marker: marker) }
        let payload = """
        {"previousVisualizationRevision":"old-vis","visualizationRevision":"new-vis","sourceRevision":"source-sha","palettes":[]}
        """
        let client = makeBackendClient(payload: payload, marker: marker)
        let mapID = MapState.projectMapID
        let source = makeSource(mapID: mapID)
        let liveSources = LiveRasterSources([source])
        let provider = BackendRasterSymbologyProvider(
            client: client,
            sources: { liveSources.values }, viewport: { _ in nil }, installLayer: { _ in },
            acceptVisualization: { _, newRevision in
                liveSources.values = [source.updating(visualizationRevision: newRevision)]
            })
        var mutationStates: [Bool] = []
        provider.onMutationRunningChanged = { mutationStates.append($0) }
        let context = RasterSymbologyContext(projectSessionID: UUID(), mapID: mapID, assetID: source.id)
        let draft = RasterSymbologyDraft(paletteID: nil, name: "Ramp",
            stops: [.init(color: "000000FF", value: 0), .init(color: "FFFFFFFF", value: 1)],
            valueSource: .manual, grayscale: false, isEditing: true,
            updateHistogramWithView: false, canComputeHistogram: true)

        let first = Task { try await provider.savePalette(draft, name: "First", context: context) }
        try await waitForRequestCount(1, marker: marker)
        do {
            _ = try await provider.savePalette(draft, name: "Second", context: context)
            Issue.record("A second mutation was accepted while the first was running.")
        } catch let error as BackendServiceError {
            #expect(error.code == "busy")
        } catch {
            Issue.record("Unexpected error while rejecting the concurrent raster mutation: \(error)")
        }
        try signalRelease(1, marker: marker)
        _ = try await first.value
        #expect(mutationStates == [true, false])
        #expect((try Data(contentsOf: marker)).count == 1)
        #expect(liveSources.values.first?.visualizationRevision == "new-vis")
    }

    @Test @MainActor func gdbMutationAcceptsOnlyTheCommittedVisualizationRevisionRebase() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("requests")
        defer { releaseRequest(1, marker: marker) }
        let mapID = UUID()
        let source = makeHydratedGdbSource(mapID: mapID, visualizationRevision: "old-vis")
        let manifest = try #require(source.gdbSource?.source.revision)
        let payload = """
        {"previousVisualizationRevision":"old-vis","visualizationRevision":"new-vis","sourceRevision":"\(manifest)","raster":{"id":"\(source.id)","sourceMapID":"\(mapID.uuidString)","name":"Elevation","width":1,"height":1,"rgba":"AAAAAA==","minX":0,"minY":0,"maxX":1,"maxY":1}}
        """
        let liveSources = LiveRasterSources([source])
        var installedLayer: MapRasterLayer?
        var acceptedRevision: String?
        let provider = BackendRasterSymbologyProvider(
            client: makeBackendClient(payload: payload, marker: marker),
            sources: { liveSources.values }, viewport: { _ in nil },
            projectXML: { "<Project />" }, installLayer: { installedLayer = $0 },
            acceptVisualization: { oldRevision, newRevision in
                acceptedRevision = oldRevision + ">" + newRevision
                // The owning Store rebuilds the visible descriptor after accepting
                // the .vis write, rebasing only the nested map's expected revision.
                liveSources.values = [source.updating(visualizationRevision: newRevision)]
            })
        let context = RasterSymbologyContext(projectSessionID: UUID(), mapID: mapID, assetID: source.id)
        let draft = RasterSymbologyDraft(paletteID: nil, name: "Elevation",
            stops: [.init(color: "000000FF", value: 0), .init(color: "FFFFFFFF", value: 1)],
            valueSource: .manual, grayscale: false, isEditing: true,
            updateHistogramWithView: false, canComputeHistogram: true)

        let mutation = Task { try await provider.apply(draft, additionalOptions: [], context: context) }
        try await waitForRequestCount(1, marker: marker)
        try signalRelease(1, marker: marker)
        try await mutation.value

        #expect(acceptedRevision == "old-vis>new-vis")
        #expect(installedLayer?.id == source.id)
        #expect(installedLayer?.sourceMapID == mapID)
        #expect(liveSources.values.first?.visualizationRevision == "new-vis")
        #expect(liveSources.values.first?.gdbSource?.map.expectedVisualizationRevision == "new-vis")
        #expect(liveSources.values.first?.gdbSource?.source == source.gdbSource?.source)
    }

    @Test @MainActor func gdbMutationStillRejectsAChangedDirectoryManifestAfterAccept() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("requests")
        defer { releaseRequest(1, marker: marker) }
        let mapID = UUID()
        let source = makeHydratedGdbSource(mapID: mapID, visualizationRevision: "old-vis")
        let manifest = try #require(source.gdbSource?.source.revision)
        let payload = """
        {"previousVisualizationRevision":"old-vis","visualizationRevision":"new-vis","sourceRevision":"\(manifest)","raster":{"id":"\(source.id)","sourceMapID":"\(mapID.uuidString)","name":"Elevation","width":1,"height":1,"rgba":"AAAAAA==","minX":0,"minY":0,"maxX":1,"maxY":1}}
        """
        let liveSources = LiveRasterSources([source])
        var installedLayer: MapRasterLayer?
        let changedManifest = String(repeating: "C", count: 64)
        let provider = BackendRasterSymbologyProvider(
            client: makeBackendClient(payload: payload, marker: marker),
            sources: { liveSources.values }, viewport: { _ in nil },
            projectXML: { "<Project />" }, installLayer: { installedLayer = $0 },
            acceptVisualization: { _, newRevision in
                liveSources.values = [self.makeHydratedGdbSource(mapID: mapID,
                    visualizationRevision: newRevision, manifestRevision: changedManifest)]
            })
        let context = RasterSymbologyContext(projectSessionID: UUID(), mapID: mapID, assetID: source.id)
        let draft = RasterSymbologyDraft(paletteID: nil, name: "Elevation",
            stops: [.init(color: "000000FF", value: 0), .init(color: "FFFFFFFF", value: 1)],
            valueSource: .manual, grayscale: false, isEditing: true,
            updateHistogramWithView: false, canComputeHistogram: true)

        let mutation = Task { try await provider.apply(draft, additionalOptions: [], context: context) }
        try await waitForRequestCount(1, marker: marker)
        try signalRelease(1, marker: marker)
        do {
            try await mutation.value
            Issue.record("A committed raster response was installed after its GDB manifest changed.")
        } catch let error as BackendServiceError {
            #expect(error.code == "notFound")
        } catch {
            Issue.record("Unexpected error while rejecting a GDB response with a changed manifest: \(error)")
        }
        #expect(installedLayer == nil)
        #expect(liveSources.values.first?.gdbSource?.source.revision == changedManifest)
    }
}
