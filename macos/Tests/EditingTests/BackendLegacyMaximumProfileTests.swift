import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct BackendLegacyMaximumProfileTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_LEGACY_MAXIMUM_ACCEPTANCE_DIRECTORY"] != nil
        && ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil)) @MainActor
    func bundledLegacyMaximumProfilesUseActiveResultAndPreserveSourceFiles() async throws {
        let environment = ProcessInfo.processInfo.environment
        let fixture = URL(fileURLWithPath: try #require(
            environment["HECRAS_LEGACY_MAXIMUM_ACCEPTANCE_DIRECTORY"]))
        let backend = URL(fileURLWithPath: try #require(
            environment["HECRAS_BACKEND_TEST_EXECUTABLE"]))
        try #require(FileManager.default.isExecutableFile(atPath: backend.path))

        let fixtureBytes = try Self.bytes(in: fixture)
        #expect(!fixtureBytes.isEmpty)
        let workingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-maximum-profile-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.copyItem(at: fixture, to: workingRoot)
        defer { try? FileManager.default.removeItem(at: workingRoot) }
        #expect(try Self.bytes(in: workingRoot) == fixtureBytes)

        let manifest = try JSONDecoder().decode(LegacyMaximumFixture.self,
            from: Data(contentsOf: workingRoot.appendingPathComponent("LEGACY_MAXIMUM_PROFILE_FIXTURE.json")))
        let projectURL = workingRoot.appendingPathComponent(manifest.project)
        let visualizationURL = workingRoot.appendingPathComponent(manifest.visualization)
        let resultURL = workingRoot.appendingPathComponent(manifest.result)
        var projectXML = try String(contentsOf: projectURL, encoding: .utf8)
        if projectXML.first == "\u{FEFF}" { projectXML.removeFirst() }
        let map = MapResultChartMapRequest(
            projectPath: projectURL.standardizedFileURL.path,
            projectXml: projectXML,
            projectXmlSHA: MapDynamicProfileRequest.digest(Data(projectXML.utf8)),
            mapID: manifest.map.id,
            mapIndex: manifest.map.index,
            mapName: manifest.map.name,
            mapType: manifest.map.type,
            expectedVisualizationRevision: MapDynamicProfileRequest.digest(try Data(contentsOf: visualizationURL)))

        let client = BackendProcessClient(executableURL: backend)
        let chartProvider = BackendMapResultChartProvider(client: client)
        let sources = try await chartProvider.loadSources(map: map, selectionOverrides: [])
        let expectedResultPath = SourceFilePaths.canonical(resultURL)
        let matchingNodes = sources.activeNodes.filter { node in
            node.nodeKind == "Result" && node.selections.contains { selection in
                guard let selected = selection.selectedResult else { return false }
                return SourceFilePaths.canonical(URL(fileURLWithPath: selected.resultPath)) == expectedResultPath
            }
        }
        let activeResultNode = try #require(matchingNodes.count == 1 ? matchingNodes.first : nil)

        let line = MapDynamicProfileLine(id: manifest.line.id,
            points: manifest.line.points.map { GeometryTopologyCoordinate(x: $0.x, y: $0.y) })
        let profileProvider = BackendMapDynamicProfileProvider(client: client)
        let requestedTypes: [(name: String, expected: Double)] = [
            ("Depth", manifest.expected.depthAtFirstPoint),
            ("WaterSurfaceElevation", manifest.expected.waterSurfaceElevationAtFirstPoint),
            ("Velocity", manifest.expected.velocityAtFirstPoint)
        ]

        for (mapType, expectedFirstSample) in requestedTypes {
            let request = MapDynamicProfileRequest(
                map: map,
                contextToken: sources.contextToken,
                selectionOverrides: [],
                lines: [line],
                linesToken: "legacy-maximum-\(mapType)",
                targetSampleCount: 16,
                plotTerrains: false,
                plotResults: true,
                terrainRequiresElevationResult: false,
                mapType: mapType,
                profileSelections: [.init(node: activeResultNode.node, profileIndex: Int(Int32.max))])
            let response = try await profileProvider.sample(request)
            try response.validate(for: request, expectedProjectRevision: sources.projectRevision)
            let sampledLine = try #require(response.lines.first)
            let result = try #require(sampledLine.series.first { $0.sourceKind == "Result" })
            let firstSample = try #require(result.samples.first ?? nil)

            #expect(response.contextToken == sources.contextToken)
            #expect(response.linesToken == request.linesToken)
            #expect(response.distanceUnits == manifest.expected.distanceUnits)
            #expect(result.profileIndex == Int(Int32.max))
            #expect(result.time == nil)
            #expect(result.unavailableReason == nil)
            #expect(SourceFilePaths.canonical(URL(fileURLWithPath: result.sourcePath)) == expectedResultPath)
            #expect(result.sourceRevision == MapDynamicProfileRequest.digest(try Data(contentsOf: resultURL)))
            #expect(abs(firstSample - expectedFirstSample) < 1e-8)
            if mapType == "Velocity" { #expect(firstSample.isFinite && firstSample > 0) }
        }

        #expect(try Self.bytes(in: fixture) == fixtureBytes)
        #expect(try Self.bytes(in: workingRoot) == fixtureBytes)
    }

    private static func bytes(in root: URL) throws -> [String: Data] {
        let prefix = SourceFilePaths.canonical(root) + "/"
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        var result: [String: Data] = [:]
        for case let url as URL in enumerator where
            try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            let path = SourceFilePaths.canonical(url)
            guard path.hasPrefix(prefix) else { throw CocoaError(.fileReadInvalidFileName) }
            result[String(path.dropFirst(prefix.count))] = try Data(contentsOf: url)
        }
        return result
    }
}

private struct LegacyMaximumFixture: Decodable {
    let project: String
    let visualization: String
    let result: String
    let map: SourceMap
    let line: SourceLine
    let expected: ExpectedSamples

    struct SourceMap: Decodable {
        let id: String
        let index: Int
        let name: String
        let type: String
    }

    struct SourceLine: Decodable {
        let id: String
        let points: [Point]
    }

    struct Point: Decodable {
        let x: Double
        let y: Double
    }

    struct ExpectedSamples: Decodable {
        let distanceUnits: String
        let depthAtFirstPoint: Double
        let waterSurfaceElevationAtFirstPoint: Double
        let velocityAtFirstPoint: Double
    }
}
