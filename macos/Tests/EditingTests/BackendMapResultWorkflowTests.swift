import CryptoKit
import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct BackendMapResultWorkflowTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_MAP_RESULT_CHART_ACCEPTANCE_DIRECTORY"] != nil
        && ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil)) @MainActor
    func actualMapResultSourcesAndSampleLineUseCopiedSourceFixture() async throws {
        let environment = ProcessInfo.processInfo.environment
        let fixture = URL(fileURLWithPath: try #require(environment["HECRAS_MAP_RESULT_CHART_ACCEPTANCE_DIRECTORY"]))
        let backend = try #require(environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let originalBytes = try SourceByteSnapshot(root: fixture)
        #expect(originalBytes.containsHDF)
        let workingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("map-result-chart-workflow-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.copyItem(at: fixture, to: workingRoot)
        defer { try? FileManager.default.removeItem(at: workingRoot) }

        let layout = try FixtureLayout(root: workingRoot)
        let map = try Self.mapRequest(layout: layout)
        let mapID = try #require(UUID(uuidString: map.mapID))
        let (vectorURL, vectorLayer, feature, coordinates) = try Self.sampleLine(in: layout)
        let capture = try MapResultChartLineCapture(
            projectSessionID: UUID(), mapID: mapID, projectPath: URL(fileURLWithPath: map.projectPath),
            projectXML: map.projectXml, mapIndex: map.mapIndex, mapName: map.mapName,
            mapType: map.mapType, visualizationRevision: map.expectedVisualizationRevision,
            layerID: SourceFilePaths.canonical(vectorURL), vectorPath: vectorURL,
            vectorRevision: try #require(vectorLayer.sourceRevision),
            stableFeatureIdentity: try #require(feature.pathStableIdentities.first),
            coordinates: coordinates, draftGeneration: "map-result-acceptance-source")
        let context = MapResultChartContext(capture: capture)

        let client = BackendProcessClient(executableURL: URL(fileURLWithPath: backend))
        let provider = BackendMapResultChartProvider(client: client)
        let initial = try await provider.loadSources(map: map, selectionOverrides: [])
        let planNode = try #require(initial.activeNodes.first {
            $0.nodeKind == "MultiResult" && !$0.selections.isEmpty
        })
        let overrides = [
            MapResultSelectionOverride(node: planNode.node, selectionIndex: 0, mode: .latest),
            MapResultSelectionOverride(node: planNode.node, selectionIndex: 1, mode: .previous)
        ]
        let sources = try await provider.loadSources(map: map, selectionOverrides: overrides)
        try MapResultChartContractValidation.validate(sources, map: map, overrides: overrides)
        let selectedPlan = try #require(sources.activeNodes.first { $0.id == planNode.id })
        #expect(selectedPlan.selections.map(\.selectionIndex) == [0, 1])
        #expect(selectedPlan.selections.map(\.selectionMode) == [.latest, .previous])
        #expect(selectedPlan.selections.allSatisfy { $0.selectedResult != nil && $0.choices.count >= 2 })

        let snapshot = MapResultSourcesSnapshot(map: map, identity: "map-result-acceptance",
            sources: sources, selectionOverrides: overrides)
        let flowRequest = MapResultChartSampleLineRequest(context: context,
            contextToken: sources.contextToken, selectionOverrides: overrides, mode: .flow)
        let flow = try await provider.compute(flowRequest) { _ in }
        try MapResultChartContractValidation.validate(flow, context: context, snapshot: snapshot, mode: .flow)
        #expect(flow.feature.featureID == feature.pathStableIdentities[0])
        #expect(flow.feature.vectorPath == context.vectorPath)
        #expect(flow.feature.coordinateSHA.uppercased() == context.coordinateSHA)
        #expect(flow.featureContextToken == context.expectedFeatureContextToken(
            contextToken: sources.contextToken, mode: .flow))
        #expect(Set(flow.series.flatMap(\.selections).filter { $0.node == planNode.node }.map(\.selectionIndex)) == Set([0, 1]))
        #expect(flow.series.count == 2)
        #expect(flow.series.allSatisfy { $0.series.available && $0.series.mode == "Flow" && $0.series.points.count == 3 })
        #expect(flow.series.allSatisfy { $0.series.points.contains { abs($0.value ?? 0) > 1e-8 } })

        let cumulativeRequest = MapResultChartSampleLineRequest(context: context,
            contextToken: sources.contextToken, selectionOverrides: overrides, mode: .cumulativeVolume)
        let cumulative = try await provider.compute(cumulativeRequest) { _ in }
        try MapResultChartContractValidation.validate(cumulative, context: context,
            snapshot: snapshot, mode: .cumulativeVolume)
        #expect(cumulative.feature.featureID == feature.pathStableIdentities[0])
        #expect(cumulative.feature.coordinateSHA.uppercased() == context.coordinateSHA)
        #expect(cumulative.featureContextToken == context.expectedFeatureContextToken(
            contextToken: sources.contextToken, mode: .cumulativeVolume))
        #expect(cumulative.series.allSatisfy { $0.series.available && $0.series.quantity == "Volume" })
        #expect(cumulative.series.allSatisfy { $0.series.points.contains { abs($0.value ?? 0) > 1e-8 } })

        let originalMismatches = try originalBytes.mismatches(root: fixture)
        #expect(originalMismatches.isEmpty,
            "Source byte mismatches: \(originalMismatches.joined(separator: "; "))")
        let workingMismatches = try originalBytes.mismatches(root: workingRoot)
        #expect(workingMismatches.isEmpty,
            "Working-copy byte mismatches: \(workingMismatches.joined(separator: "; "))")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_MAP_RESULT_RENDER_ACCEPTANCE_DIRECTORY"] != nil
        && ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil)) @MainActor
    func actualMapResultRendererSelectsProfilesAndPreservesSourceFiles() async throws {
        let environment = ProcessInfo.processInfo.environment
        let fixture = URL(fileURLWithPath: try #require(environment["HECRAS_MAP_RESULT_RENDER_ACCEPTANCE_DIRECTORY"]))
        let backend = try #require(environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let originalBytes = try SourceByteSnapshot(root: fixture)
        #expect(originalBytes.containsHDF)
        let workingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("map-result-render-workflow-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.copyItem(at: fixture, to: workingRoot)
        defer { try? FileManager.default.removeItem(at: workingRoot) }

        let layout = try FixtureLayout(root: workingRoot)
        let map = try Self.mapRequest(layout: layout)
        let mapID = try #require(UUID(uuidString: map.mapID))
        let client = BackendProcessClient(executableURL: URL(fileURLWithPath: backend))
        let chartProvider = BackendMapResultChartProvider(client: client)
        let sources = try await chartProvider.loadSources(map: map, selectionOverrides: [])
        try MapResultChartContractValidation.validate(sources, map: map, overrides: [])
        let node = try #require(sources.activeNodes.first { $0.nodeKind == "Result" && $0.selections.contains { $0.selectedResult != nil } })
        let viewport = RasterMapViewExtent(minX: 0, minY: 0, maxX: 1, maxY: 1, pixelWidth: 32, pixelHeight: 32)
        let prepared = try await BackendMapResultRenderProvider.prepare(client: client, map: map,
            selectionOverrides: [], sources: sources, node: node, mapID: mapID, viewport: { viewport })
        let firstLayer = try #require(prepared.initial.layers.first)
        #expect(prepared.initial.selectedProfileIndex == 0)
        #expect(prepared.presentation.steps.map(\.id) == [0, 1, 2])
        #expect(firstLayer.profileIndex == 0 && firstLayer.sourceMapID == map.mapID)
        #expect(firstLayer.width == viewport.pixelWidth && firstLayer.height == viewport.pixelHeight)
        #expect(firstLayer.rgba.count == viewport.pixelWidth * viewport.pixelHeight * 4)
        #expect(firstLayer.terrainPath == prepared.initial.sources.first?.terrainPath)
        #expect(firstLayer.terrainRevision == prepared.initial.sources.first?.terrainRevision)
        #expect(!firstLayer.terrainPath.isEmpty && firstLayer.terrainRevision.count == 64)
        #expect(prepared.initial.sources.allSatisfy { $0.available && $0.terrainPath != nil && $0.terrainRevision?.count == 64 })

        let profileZeroUpdate = try await prepared.provider.selectProfile(0)
        #expect(profileZeroUpdate.rasters?.first?.rgba == firstLayer.rgba)
        let profileTwoUpdate = try await prepared.provider.selectProfile(2)
        let profileTwoLayer = try #require(profileTwoUpdate.rasters?.first)
        #expect(profileTwoUpdate.rasters?.count == 1)
        #expect(profileTwoLayer.sourceMapID == mapID)
        #expect(profileTwoLayer.rgba.count == firstLayer.rgba.count)
        #expect(profileTwoLayer.rgba != firstLayer.rgba)

        let originalMismatches = try originalBytes.mismatches(root: fixture)
        #expect(originalMismatches.isEmpty,
            "Source byte mismatches: \(originalMismatches.joined(separator: "; "))")
        let workingMismatches = try originalBytes.mismatches(root: workingRoot)
        #expect(workingMismatches.isEmpty,
            "Working-copy byte mismatches: \(workingMismatches.joined(separator: "; "))")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_MAP_RESULT_RENDER_ACCEPTANCE_DIRECTORY"] != nil
        && ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil)) @MainActor
    func actualResultVelocityMapperFeedsViewportParticleFieldAndPreservesFiles() async throws {
        let environment = ProcessInfo.processInfo.environment
        let fixture = URL(fileURLWithPath: try #require(environment["HECRAS_MAP_RESULT_RENDER_ACCEPTANCE_DIRECTORY"]))
        let backend = try #require(environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let originalBytes = try SourceByteSnapshot(root: fixture)
        #expect(originalBytes.containsHDF)
        let workingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("map-result-velocity-workflow-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.copyItem(at: fixture, to: workingRoot)
        defer { try? FileManager.default.removeItem(at: workingRoot) }

        let layout = try FixtureLayout(root: workingRoot)
        var visualizationXML = try String(contentsOf: layout.visualizationURL, encoding: .utf8)
        guard let mapTypeRange = visualizationXML.range(of: "SelectedMapType=\"Depth\"") else {
            throw MapResultWorkflowTestError.missingVelocityNode
        }
        visualizationXML.replaceSubrange(mapTypeRange, with: "SelectedMapType=\"Velocity\"")
        try Data(visualizationXML.utf8).write(to: layout.visualizationURL, options: .atomic)
        let workingBytes = try SourceByteSnapshot(root: workingRoot)

        let map = try Self.mapRequest(layout: layout)
        let mapID = try #require(UUID(uuidString: map.mapID))
        let client = BackendProcessClient(executableURL: URL(fileURLWithPath: backend))
        let chartProvider = BackendMapResultChartProvider(client: client)
        let sources = try await chartProvider.loadSources(map: map, selectionOverrides: [])
        try MapResultChartContractValidation.validate(sources, map: map, overrides: [])
        let node = try #require(sources.activeNodes.first {
            $0.nodeKind == "Result" && $0.selectedMapType == "Velocity"
                && $0.selections.contains { $0.selectionIndex == 0 && $0.selectedResult != nil }
        })
        let viewport = RasterMapViewExtent(minX: 0, minY: 0, maxX: 1, maxY: 1,
            pixelWidth: 32, pixelHeight: 32)
        let prepared = try await BackendMapResultRenderProvider.prepare(client: client,
            map: map, selectionOverrides: [], sources: sources, node: node,
            mapID: mapID, viewport: { viewport })
        let first = try await prepared.provider.sampleVelocityField(requestID: "velocity-0",
            profileIndex: 0, viewport: viewport)
        let last = try await prepared.provider.sampleVelocityField(requestID: "velocity-2",
            profileIndex: 2, viewport: viewport)
        let nonSquareViewport = RasterMapViewExtent(minX: 0, minY: 0, maxX: 1, maxY: 1,
            pixelWidth: 31, pixelHeight: 32)
        let normalized = try await prepared.provider.sampleVelocityField(requestID: "velocity-nonsquare",
            profileIndex: 0, viewport: nonSquareViewport)
        #expect(first.width == viewport.pixelWidth && first.height == viewport.pixelHeight)
        #expect(first.profileIndex == 0 && last.profileIndex == 2)
        #expect(first.profileName == prepared.presentation.steps[0].label)
        #expect(last.profileName == prepared.presentation.steps[2].label)
        #expect(first.resultPath == last.resultPath && first.revision == last.revision)
        #expect(first.terrainPath == last.terrainPath && first.terrainRevision == last.terrainRevision)
        #expect(first.magnitude.contains { $0.isFinite && $0 != first.noDataValue && $0 >= 1e-5 })
        #expect(first.velocityX != last.velocityX || first.velocityY != last.velocityY
            || first.magnitude != last.magnitude)
        let normalizedCellSize = max(1.0 / Double(nonSquareViewport.pixelWidth),
            1.0 / Double(nonSquareViewport.pixelHeight))
        #expect(normalized.width == nonSquareViewport.pixelWidth)
        #expect(normalized.height == nonSquareViewport.pixelHeight)
        #expect(abs(normalized.cellSize - normalizedCellSize) < 1e-12)
        #expect(abs(normalized.maxX - 1) < 1e-12)
        #expect(abs(normalized.minY - (1 - Double(nonSquareViewport.pixelHeight) * normalizedCellSize)) < 1e-12)
        #expect(normalized.minY < nonSquareViewport.minY,
            "The returned extent must follow RasterDefinition's square-cell expansion for this non-square raster.")
        let originalMismatches = try originalBytes.mismatches(root: fixture)
        #expect(originalMismatches.isEmpty,
            "Source byte mismatches: \(originalMismatches.joined(separator: "; "))")
        let workingMismatches = try workingBytes.mismatches(root: workingRoot)
        #expect(workingMismatches.isEmpty,
            "Working-copy byte mismatches: \(workingMismatches.joined(separator: "; "))")
    }

    private static func mapRequest(layout: FixtureLayout) throws -> MapResultChartMapRequest {
        let projectBytes = try Data(contentsOf: layout.projectURL)
        guard var projectXML = String(data: projectBytes, encoding: .utf8) else {
            throw MapResultWorkflowTestError.invalidProjectXML
        }
        if projectXML.first == "\u{FEFF}" { projectXML.removeFirst() }
        let visualization = try VisualizationDocument(projectURL: layout.projectURL)
        guard let sourceMap = visualization.maps.first else { throw MapResultWorkflowTestError.missingMap }
        let visualizationBytes = try Data(contentsOf: layout.visualizationURL)
        let mapID = UUID().uuidString
        return MapResultChartMapRequest(
            projectPath: layout.projectURL.standardizedFileURL.path,
            projectXml: projectXML,
            projectXmlSHA: Self.sha256(Data(projectXML.utf8)),
            mapID: mapID,
            mapIndex: sourceMap.index,
            mapName: sourceMap.name,
            mapType: sourceMap.type,
            expectedVisualizationRevision: Self.sha256(visualizationBytes))
    }

    private static func sampleLine(in layout: FixtureLayout) throws -> (URL, MapVectorLayer, MapFeature, [GeometryTopologyCoordinate]) {
        let files = try FixtureLayout.fileURLs(in: layout.root)
        let candidates: [URL]
        if let vectorHint = layout.vectorURL {
            candidates = [vectorHint]
        } else {
            candidates = files.filter { ["geojson", "json"].contains($0.pathExtension.lowercased()) }
        }
        for url in candidates {
            guard let layer = try? MapVectorLayer(contentsOf: url),
                  let feature = layer.features.first(where: { feature in
                      if case .line = feature.kind { return feature.paths.count == 1 && feature.pathStableIdentities.count == 1 }
                      return false
                  }),
                  let path = feature.paths.first, path.count >= 2 else { continue }
            return (url, layer, feature, path.map { GeometryTopologyCoordinate(x: $0.x, y: $0.y) })
        }
        throw MapResultWorkflowTestError.missingPolyline
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }
}

private struct FixtureLayout {
    let root: URL
    let projectURL: URL
    let visualizationURL: URL
    let vectorURL: URL?

    init(root: URL) throws {
        self.root = root
        let files = try Self.fileURLs(in: root)
        var manifest: [String: Any] = [:]
        let manifestURL = root.appendingPathComponent("manifest.json")
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            let data = try Data(contentsOf: manifestURL)
            manifest = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let projectHint = (manifest["project"] as? String) ?? (manifest["projectPath"] as? String)
        guard let projectURL = Self.resolve(projectHint, root: root, files: files)
                ?? files.first(where: { $0.pathExtension.lowercased() == "ras" }) else {
            throw MapResultWorkflowTestError.missingProject
        }
        let visualizationHint = (manifest["visualization"] as? String) ?? (manifest["visualizationPath"] as? String)
        guard let visualizationURL = Self.resolve(visualizationHint, root: root, files: files)
                ?? files.first(where: { $0.path == projectURL.deletingPathExtension().appendingPathExtension("vis").path }) else {
            throw MapResultWorkflowTestError.missingVisualization
        }
        let vectorHint = manifest["vector"] as? String
        self.projectURL = projectURL
        self.visualizationURL = visualizationURL
        self.vectorURL = Self.resolve(vectorHint, root: root, files: files)
    }

    static func fileURLs(in root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey]) else { throw MapResultWorkflowTestError.unreadableFixture }
        return enumerator.compactMap { $0 as? URL }.filter { url in
            (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    private static func resolve(_ value: String?, root: URL, files: [URL]) -> URL? {
        guard let value, !value.isEmpty else { return nil }
        if value.hasPrefix("/") {
            let path = URL(fileURLWithPath: value)
            if path.path.hasPrefix(root.standardizedFileURL.path + "/"),
               FileManager.default.fileExists(atPath: path.path) { return path }
        } else {
            let candidate = root.appendingPathComponent(value)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        let path = URL(fileURLWithPath: value)
        return files.first { $0.lastPathComponent == path.lastPathComponent }
    }
}

private struct SourceByteSnapshot {
    private let files: [String: Data]
    let containsHDF: Bool

    init(root: URL) throws {
        var snapshot: [String: Data] = [:]
        var hasHDF = false
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = rootPath + "/"
        for url in try FixtureLayout.fileURLs(in: root) {
            let ext = url.pathExtension.lowercased()
            guard ["ras", "vis", "h5", "hdf"].contains(ext) else { continue }
            if ext == "h5" || ext == "hdf" { hasHDF = true }
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard path.hasPrefix(prefix) else { throw MapResultWorkflowTestError.unreadableFixture }
            let relativePath = String(path.dropFirst(prefix.count))
            snapshot[relativePath] = try Data(contentsOf: url)
        }
        files = snapshot
        containsHDF = hasHDF
    }

    func mismatches(root: URL) throws -> [String] {
        guard !files.isEmpty else { return ["No source files were captured."] }
        var mismatches: [String] = []
        for (relativePath, bytes) in files {
            let url = root.appendingPathComponent(relativePath)
            let expectedHash = Self.sha256(bytes)
            guard FileManager.default.fileExists(atPath: url.path) else {
                mismatches.append("\(relativePath): expected SHA-256 \(expectedHash), actual missing")
                continue
            }
            let actual = try Data(contentsOf: url)
            guard actual == bytes else {
                mismatches.append("\(relativePath): expected SHA-256 \(expectedHash), actual SHA-256 \(Self.sha256(actual))")
                continue
            }
        }
        return mismatches.sorted()
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private enum MapResultWorkflowTestError: Error {
    case unreadableFixture
    case missingProject
    case missingVisualization
    case missingMap
    case invalidProjectXML
    case missingPolyline
    case missingVelocityNode
}
