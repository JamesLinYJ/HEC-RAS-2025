import CryptoKit
import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct BackendRasterCalculatorWorkflowTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_RASTER_CALCULATOR_ACCEPTANCE_DIRECTORY"] != nil
        && ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil)) @MainActor
    func retainedTerrainAndResultInputsEvaluateActualSelectedProfilesWithoutWritingSources() async throws {
        let environment = ProcessInfo.processInfo.environment
        let fixtureRoot = URL(fileURLWithPath: try #require(environment["HECRAS_RASTER_CALCULATOR_ACCEPTANCE_DIRECTORY"]))
        let executable = try #require(environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let fixtureBytes = try RasterCalculatorByteSnapshot(root: fixtureRoot)
        #expect(fixtureBytes.containsHDF)

        let workingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("raster-calculator-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.copyItem(at: fixtureRoot, to: workingRoot)
        defer { try? FileManager.default.removeItem(at: workingRoot) }

        let files = try RasterCalculatorByteSnapshot.fileURLs(in: workingRoot)
        let projectURL = try #require(files.first { $0.pathExtension.lowercased() == "ras" })
        let visualizationURL = try #require(files.first {
            $0.path == projectURL.deletingPathExtension().appendingPathExtension("vis").path
        })
        let projectData = try Data(contentsOf: projectURL)
        var projectXML = try #require(String(data: projectData, encoding: .utf8))
        if projectXML.first == "\u{FEFF}" { projectXML.removeFirst() }
        let visualization = try VisualizationDocument(projectURL: projectURL)
        let visualMap = try #require(visualization.maps.first)
        let map = MapTreeMapIdentity(projectPath: projectURL.standardizedFileURL.path,
            projectXml: projectXML, projectXmlSHA: Self.sha256(Data(projectXML.utf8)),
            mapID: UUID().uuidString, mapIndex: visualMap.index, mapName: visualMap.name,
            mapType: visualMap.type, expectedVisualizationRevision: Self.sha256(try Data(contentsOf: visualizationURL)))
        let viewport = RasterMapViewExtent(minX: 0, minY: 0, maxX: 1, maxY: 1,
            pixelWidth: 48, pixelHeight: 32)
        let provider = BackendRasterCalculatorProvider(client: BackendProcessClient(
            executableURL: URL(fileURLWithPath: executable)))

        let inspection = try await provider.inspect(map: map)
        let terrain = try #require(inspection.sources.first { $0.kind == "terrain" })
        let result = try #require(inspection.sources.first { $0.kind == "resultMap" })
        #expect(terrain.isAvailable && result.isAvailable)
        #expect(result.profileCount == 3 && result.profileTimes.count == result.profileCount)
        #expect(result.mapTypes == ["Depth", "WaterSurfaceElevation", "Velocity", "DepthTimesVelocity"])

        let staticRecipe = RasterCalculatorRecipe(expression: "a * factor + 1", noDataBehavior: "WriteNDV",
            inputs: [RasterCalculatorInput(variableName: "a", sourceID: terrain.id,
                sourceRevision: terrain.revision, kind: terrain.kind)],
            constants: [RasterCalculatorConstant(name: "factor", value: "2.5")])
        let (staticResult, staticLayer) = try await provider.evaluate(map: map,
            contextToken: inspection.contextToken, recipe: staticRecipe,
            layerID: "calculator-static-acceptance", layerName: "Calc: terrain expression",
            profileIndex: 0, viewport: viewport, expectedSources: inspection.sources)
        #expect(!staticResult.isDynamic && staticResult.profileCount == 1)
        #expect(staticLayer.width == viewport.pixelWidth && staticLayer.height == viewport.pixelHeight)
        #expect(staticLayer.rgba.count == viewport.pixelWidth * viewport.pixelHeight * 4)
        #expect(staticLayer.sourceMapID == UUID(uuidString: map.mapID))

        let dynamicRecipe = RasterCalculatorRecipe(expression: "depth + velocity * factor",
            noDataBehavior: "WriteZero", keyFrameVariableName: "depth",
            inputs: [
                RasterCalculatorInput(variableName: "depth", sourceID: result.id,
                    sourceRevision: result.revision, kind: result.kind,
                    mapType: "Depth", isKeyFrame: true),
                RasterCalculatorInput(variableName: "velocity", sourceID: result.id,
                    sourceRevision: result.revision, kind: result.kind,
                    mapType: "Velocity", forceHorizontal: true)
            ], constants: [RasterCalculatorConstant(name: "factor", value: "2.5")])
        let (first, firstLayer) = try await provider.evaluate(map: map,
            contextToken: inspection.contextToken, recipe: dynamicRecipe,
            layerID: "calculator-dynamic-acceptance", layerName: "Calc: dynamic expression",
            profileIndex: 0, viewport: viewport, expectedSources: inspection.sources)
        let (last, lastLayer) = try await provider.evaluate(map: map,
            contextToken: inspection.contextToken, recipe: dynamicRecipe,
            layerID: "calculator-dynamic-acceptance", layerName: "Calc: dynamic expression",
            profileIndex: 2, viewport: viewport, expectedSources: inspection.sources)
        #expect(first.isDynamic && first.profileCount == 3)
        #expect(first.selectedProfileIndex == 0 && last.selectedProfileIndex == 2)
        #expect(first.selectedProfileTime == result.profileTimes[0])
        #expect(last.selectedProfileTime == result.profileTimes[2])
        #expect(first.profiles.map(\.index) == [0, 1, 2])
        #expect(firstLayer.rgba.count == lastLayer.rgba.count)
        #expect(firstLayer.rgba != lastLayer.rgba,
            "Profile switching must render the selected timestep with the shared profile-zero palette.")

        #expect(try fixtureBytes.mismatches(root: fixtureRoot).isEmpty)
        #expect(try fixtureBytes.mismatches(root: workingRoot).isEmpty)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }
}

private struct RasterCalculatorByteSnapshot {
    private let files: [String: Data]
    let containsHDF: Bool

    init(root: URL) throws {
        var snapshot: [String: Data] = [:]
        var hasHDF = false
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = rootPath + "/"
        for url in try Self.fileURLs(in: root) {
            let extensionName = url.pathExtension.lowercased()
            guard ["ras", "vis", "h5", "hdf"].contains(extensionName) else { continue }
            if extensionName == "h5" || extensionName == "hdf" { hasHDF = true }
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard path.hasPrefix(prefix) else { throw RasterCalculatorWorkflowTestError.fixturePathEscapesRoot }
            snapshot[String(path.dropFirst(prefix.count))] = try Data(contentsOf: url)
        }
        files = snapshot
        containsHDF = hasHDF
    }

    static func fileURLs(in root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw RasterCalculatorWorkflowTestError.unreadableFixture
        }
        return enumerator.compactMap { $0 as? URL }.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    func mismatches(root: URL) throws -> [String] {
        guard !files.isEmpty else { return ["No source files were captured."] }
        var mismatches: [String] = []
        for (relativePath, expected) in files {
            let url = root.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                mismatches.append(relativePath + " (missing)")
                continue
            }
            if try Data(contentsOf: url) != expected { mismatches.append(relativePath) }
        }
        return mismatches.sorted()
    }
}

private enum RasterCalculatorWorkflowTestError: Error {
    case fixturePathEscapesRoot
    case unreadableFixture
}
