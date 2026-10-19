import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct BackendMapDynamicProfileTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_DYNAMIC_PROFILE_ACCEPTANCE_DIRECTORY"] != nil
        && ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil)) @MainActor
    func bundledDynamicProfilesSampleRealMapFramesTerrainsAndLinkedSummariesWithoutWritingSources() async throws {
        let environment = ProcessInfo.processInfo.environment
        let fixture = URL(fileURLWithPath: try #require(environment["HECRAS_DYNAMIC_PROFILE_ACCEPTANCE_DIRECTORY"]))
        let backend = URL(fileURLWithPath: try #require(environment["HECRAS_BACKEND_TEST_EXECUTABLE"]))
        try #require(FileManager.default.isExecutableFile(atPath: backend.path))
        let before = try Self.bytes(in: fixture)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dynamic-profile-" + UUID().uuidString)
        try FileManager.default.copyItem(at: fixture, to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = try JSONDecoder().decode(DynamicProfileFixture.self,
            from: Data(contentsOf: root.appendingPathComponent("DYNAMIC_PROFILE_FIXTURE.json")))
        let project = root.appendingPathComponent(manifest.project)
        var xml = try String(contentsOf: project, encoding: .utf8)
        if xml.first == "\u{FEFF}" { xml.removeFirst() }
        let map = MapResultChartMapRequest(projectPath: project.path, projectXml: xml,
            projectXmlSHA: MapDynamicProfileRequest.digest(Data(xml.utf8)), mapID: UUID().uuidString,
            mapIndex: manifest.map.index, mapName: manifest.map.name, mapType: manifest.map.type,
            expectedVisualizationRevision: MapDynamicProfileRequest.digest(
                try Data(contentsOf: root.appendingPathComponent(manifest.visualization))))
        let client = BackendProcessClient(executableURL: backend)
        let sources = try await BackendMapResultChartProvider(client: client).loadSources(map: map, selectionOverrides: [])
        let resultPath = root.appendingPathComponent(try #require(manifest.results.first))
        let node = try #require(sources.activeNodes.first { node in
            node.nodeKind == "Result" && node.selections.contains { slot in
                slot.selectedResult.map { SourceFilePaths.canonical(URL(fileURLWithPath: $0.resultPath))
                    == SourceFilePaths.canonical(resultPath) } ?? false
            }
        })
        let lines = try manifest.lines.map { line in
            let rawFeature = try #require(line.feature)
            let vectorURL = root.appendingPathComponent(rawFeature.vectorPath)
            #expect(FileManager.default.fileExists(atPath: vectorURL.path))
            let listedSource = try #require(manifest.vectorSources.first {
                $0.featureID == rawFeature.featureID && $0.coordinateSHA == rawFeature.coordinateSHA
            })
            #expect(listedSource.path == rawFeature.vectorPath)
            #expect(listedSource.sourceRevision == rawFeature.vectorRevision)
            #expect(rawFeature.featureID == line.id)
            #expect(MapDynamicProfileRequest.digest(try Data(contentsOf: vectorURL))
                == rawFeature.vectorRevision)
            #expect(listedSource.mapType == "PolylinesVector")
            return MapDynamicProfileLine(id: line.id,
                points: line.points.map { .init(x: $0.x, y: $0.y) },
                feature: MapResultFeatureIdentity(vectorPath: SourceFilePaths.canonical(vectorURL),
                    vectorRevision: rawFeature.vectorRevision, featureID: rawFeature.featureID,
                    coordinateSHA: rawFeature.coordinateSHA))
        }
        func request(_ profile: Int, terrainGate: Bool = true,
                     linked: LinkedResultProfilesRequest? = nil, mode: String = "Profile") -> MapDynamicProfileRequest {
            MapDynamicProfileRequest(map: map, contextToken: sources.contextToken, selectionOverrides: [],
                lines: lines, linesToken: GeometryDynamicProfileLines.token(lines: lines, sourceIdentity: sources.contextToken),
                targetSampleCount: 16, plotTerrains: true, plotResults: true,
                terrainRequiresElevationResult: terrainGate, mapType: "Depth",
                profileSelections: linked == nil ? [.init(node: node.node, profileIndex: profile)] : [],
                linkedResults: linked, linkedFrameMode: mode)
        }
        let provider = BackendMapDynamicProfileProvider(client: client)
        let first = try await provider.sample(request(0))
        let last = try await provider.sample(request(2, terrainGate: false))
        try last.validate(for: request(2, terrainGate: false), expectedProjectRevision: sources.projectRevision)
        #expect(first.distanceUnits == manifest.distanceUnits && last.distanceUnits == manifest.distanceUnits)
        let firstLine = try #require(first.lines.first), lastLine = try #require(last.lines.first)
        let firstResult = try #require(firstLine.series.first { $0.sourceKind == "Result" })
        let lastResult = try #require(lastLine.series.first { $0.sourceKind == "Result" })
        #expect(firstResult.profileIndex == 0 && lastResult.profileIndex == 2)
        let firstValue = try #require(firstResult.samples.first ?? nil)
        let lastValue = try #require(lastResult.samples.first ?? nil)
        #expect(lastValue > firstValue)
        #expect(lastResult.samples.contains(0))
        #expect(firstLine.series.allSatisfy { $0.sourceKind != "Terrain" })
        let terrain = try #require(lastLine.series.first { $0.sourceKind == "Terrain" })
        #expect(try #require(terrain.samples.first ?? nil) == 100)
        #expect(terrain.sourceRevision.count == 64)
        #expect(lastLine.samplePoints.count > lines[0].points.count)
        #expect(lastLine.distances.count == lastLine.samplePoints.count && lastLine.distances.first == 0)

        let context = try await BackendResultPlanContextProvider(client: client).inspect(
            resultPath: resultPath, projectPath: project, projectXml: xml,
            revision: MapDynamicProfileRequest.digest(try Data(contentsOf: resultPath)))
        let linked = LinkedResultProfilesRequest(projectPath: project.path, projectXml: xml,
            projectRevision: context.projectRevision, anchor: context.anchor, selectedGroups: [], profileIndex: 2)
        let linkedSample = try await provider.sample(request(0, terrainGate: false, linked: linked))
        let linkedResult = try #require(linkedSample.lines.first?.series.first { $0.sourceKind == "Result" })
        #expect(linkedResult.profileIndex == 2 && linkedResult.samples == lastResult.samples)
        for mode in ["Maximum", "Minimum"] {
            let result = try await provider.sample(request(0, linked: linked, mode: mode))
            let summary = try #require(result.lines.first?.series.first { $0.sourceKind == "Result" })
            #expect(summary.unavailableReason != nil && summary.time == nil)
            #expect(summary.profileIndex == (mode == "Maximum" ? Int(Int32.max) : Int(Int32.min)))
            #expect(summary.samples.allSatisfy { $0 == nil })
        }
        #expect(try Self.bytes(in: fixture) == before)
        #expect(try Self.bytes(in: root) == before)
    }

    private static func bytes(in root: URL) throws -> [String: Data] {
        // Foundation can normalize /private/var back to /var even after its
        // symlink resolver. Compare physical strings for both root and entry.
        let prefix = SourceFilePaths.canonical(root) + "/"
        let enumerator = try #require(FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey]))
        var result: [String: Data] = [:]
        for case let url as URL in enumerator where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            let path = SourceFilePaths.canonical(url)
            guard path.hasPrefix(prefix) else { throw CocoaError(.fileReadInvalidFileName) }
            result[String(path.dropFirst(prefix.count))] = try Data(contentsOf: url)
        }
        return result
    }
}

private struct DynamicProfileFixture: Decodable {
    let project: String
    let visualization: String
    let results: [String]
    let vectorSources: [VectorSource]
    let distanceUnits: String
    let map: SourceMap
    let lines: [Line]
    struct VectorSource: Decodable {
        let path: String
        let mapType: String
        let sourceRevision: String
        let featureID: String
        let coordinateSHA: String
    }
    struct SourceMap: Decodable {
        let index: Int
        let name: String
        let type: String
    }
    struct Line: Decodable {
        let id: String
        let points: [Point]
        let feature: Feature?
        enum CodingKeys: String, CodingKey { case id, legacyID = "Id", points, feature }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id)
                ?? container.decode(String.self, forKey: .legacyID)
            points = try container.decode([Point].self, forKey: .points)
            feature = try container.decodeIfPresent(Feature.self, forKey: .feature)
        }
    }
    struct Feature: Decodable {
        let vectorPath: String
        let vectorRevision: String
        let featureID: String
        let coordinateSHA: String
    }
    struct Point: Decodable {
        let x: Double
        let y: Double
        enum CodingKeys: String, CodingKey { case x, y, legacyX = "X", legacyY = "Y" }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            x = try container.decodeIfPresent(Double.self, forKey: .x)
                ?? container.decode(Double.self, forKey: .legacyX)
            y = try container.decodeIfPresent(Double.self, forKey: .y)
                ?? container.decode(Double.self, forKey: .legacyY)
        }
    }
}
