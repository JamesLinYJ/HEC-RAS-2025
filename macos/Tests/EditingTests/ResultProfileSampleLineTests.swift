import CryptoKit
import Foundation
import Testing
import RASWorkspaceCore
@testable import HECRAS2025

@MainActor
private final class ControlledSampleLineProvider: ResultProfileProvider, ResultProfileSampleLineProvider {
    private(set) var sourceRequests: [(projectPath: String, resultPath: String, revision: String)] = []
    private(set) var mapRequests: [(resultPath: String, flowAreaIndex: Int, elementKind: String)] = []
    private(set) var computeRequests: [ResultProfileSampleLineRequest] = []
    private var sourceContinuations: [Int: CheckedContinuation<ResultProfileSources, any Error>] = [:]
    private var computeContinuations: [Int: CheckedContinuation<ResultProfileSampleLineResult, any Error>] = [:]
    private var computeProgress: [Int: @Sendable (BackendProgressUpdate) -> Void] = [:]
    var delaySources = false

    func loadCatalog(resultPath: String, revision: String) async throws -> ResultProfileCatalog {
        sampleCatalog(identity: ResultProfileIdentity(resultPath: resultPath, revision: revision))
    }

    func loadMap(resultPath: String, revision: String, flowAreaIndex: Int, elementKind: String,
                 extent: GeometryTopologyExtent?, limit: Int) async throws -> ResultProfileMapResult {
        mapRequests.append((resultPath, flowAreaIndex, elementKind))
        return sampleMap(identity: ResultProfileIdentity(resultPath: resultPath, revision: revision),
            flowAreaIndex: flowAreaIndex, elementKind: elementKind)
    }

    func readSeries(resultPath: String, revision: String,
                    selection: ResultProfileSelection) async throws -> ResultProfileSeries {
        sampleStoredSeries(identity: ResultProfileIdentity(resultPath: resultPath, revision: revision), selection: selection)
    }

    func loadSampleSources(projectPath: String, projectXml: String,
                           resultPath: String, revision: String) async throws -> ResultProfileSources {
        sourceRequests.append((projectPath, resultPath, revision))
        guard delaySources else { return sampleSources(projectPath: projectPath,
            identity: ResultProfileIdentity(resultPath: resultPath, revision: revision)) }
        let index = sourceRequests.count
        return try await withCheckedThrowingContinuation { sourceContinuations[index] = $0 }
    }

    func computeSampleLine(_ request: ResultProfileSampleLineRequest,
                           progress: @escaping @Sendable (BackendProgressUpdate) -> Void) async throws -> ResultProfileSampleLineResult {
        computeRequests.append(request)
        let index = computeRequests.count
        computeProgress[index] = progress
        return try await withCheckedThrowingContinuation { computeContinuations[index] = $0 }
    }

    func finishSources(_ index: Int, identity: ResultProfileIdentity, projectPath: String) {
        sourceContinuations.removeValue(forKey: index)?.resume(returning: sampleSources(
            projectPath: projectPath, identity: identity))
    }

    func finishCompute(_ index: Int, values: [Double]) {
        guard index > 0, index <= computeRequests.count else { return }
        let request = computeRequests[index - 1]
        computeContinuations.removeValue(forKey: index)?.resume(returning: sampleSampleLineResult(request, values: values))
    }

    func failCompute(_ index: Int, error: any Error) {
        computeContinuations.removeValue(forKey: index)?.resume(throwing: error)
    }

    func emitProgress(_ index: Int, update: BackendProgressUpdate) {
        computeProgress[index]?(update)
    }
}

struct ResultProfileSampleLineTests {
    @Test @MainActor
    func sampleLineMapUsesFirstEmbeddedFlowAreaAndRetainsExactCoordinates() async throws {
        let identity = ResultProfileIdentity(resultPath: "/fixture/primary.hdf", revision: "primary-revision")
        let provider = ControlledSampleLineProvider()
        let session = ResultProfileSession(provider: provider)
        await session.load(identity)
        await session.loadSampleSources(projectPath: "/fixture/model.ras", projectXml: "<Project />", contextID: "project-1")
        await session.loadSampleLineMap()
        #expect(provider.mapRequests.count == 1)
        #expect(provider.mapRequests[0].flowAreaIndex == 0 && provider.mapRequests[0].elementKind == "Cell")

        let first = GeometryTopologyCoordinate(x: 0.25, y: 0.5)
        let second = GeometryTopologyCoordinate(x: 1.75, y: 0.5)
        session.addSampleLinePoint(first)
        session.addSampleLinePoint(second)
        #expect(session.sampleLinePoints == [first, second])
        #expect(session.sampleLineSeries.isEmpty)
        session.undoSampleLinePoint()
        #expect(session.sampleLinePoints == [first])
        session.clearSampleLine()
        #expect(session.sampleLinePoints.isEmpty)
    }

    @Test @MainActor
    func staleSourceAndComputationRepliesCannotReplaceCurrentLineOrResult() async throws {
        let provider = ControlledSampleLineProvider()
        provider.delaySources = true
        let session = ResultProfileSession(provider: provider)
        let first = ResultProfileIdentity(resultPath: "/fixture/first.hdf", revision: "first-revision")
        let second = ResultProfileIdentity(resultPath: "/fixture/second.hdf", revision: "second-revision")

        let firstLoad = Task { await session.load(first) }
        await firstLoad.value
        let staleSources = Task {
            await session.loadSampleSources(projectPath: "/fixture/model.ras", projectXml: "<Project />", contextID: "project-1")
        }
        try await waitForSampleLine { provider.sourceRequests.count == 1 }
        await session.load(second)
        provider.finishSources(1, identity: first, projectPath: "/fixture/model.ras")
        await staleSources.value
        #expect(session.identity == second && session.sampleLineSources?.resultPath == nil)

        provider.delaySources = false
        await session.loadSampleSources(projectPath: "/fixture/model.ras", projectXml: "<Project />", contextID: "project-2")
        session.addSampleLinePoint(.init(x: 0.1, y: 0.5))
        session.addSampleLinePoint(.init(x: 1.9, y: 0.5))
        let oldCompute = Task { await session.computeSampleLine() }
        try await waitForSampleLine { provider.computeRequests.count == 1 }
        let firstProgress = try JSONDecoder().decode(BackendProgressUpdate.self,
            from: Data(#"{"fraction":0.4,"message":"Computing primary","taskName":"Primary"}"#.utf8))
        provider.emitProgress(1, update: firstProgress)
        try await waitForSampleLine { session.sampleLineProgressFraction == 0.4 }
        #expect(session.sampleLineProgressTaskName == "Primary")

        session.addSampleLinePoint(.init(x: 1.9, y: 0.8))
        #expect(session.sampleLineProgressFraction == nil)
        let currentCompute = Task { await session.computeSampleLine() }
        try await waitForSampleLine { provider.computeRequests.count == 2 }
        provider.emitProgress(1, update: firstProgress)
        try await Task.sleep(for: .milliseconds(10))
        #expect(session.sampleLineProgressFraction == nil)
        let currentProgress = try JSONDecoder().decode(BackendProgressUpdate.self,
            from: Data(#"{"fraction":0.8,"message":"Computing comparison","taskName":"Comparison"}"#.utf8))
        provider.emitProgress(2, update: currentProgress)
        try await waitForSampleLine { session.sampleLineProgressFraction == 0.8 }
        #expect(session.sampleLineProgressTaskName == "Comparison")
        provider.finishCompute(2, values: [4, 5, 6])
        await currentCompute.value
        #expect(session.sampleLineSeries.first?.points.compactMap(\.value) == [4, 5, 6])
        provider.failCompute(1, error: BackendServiceError(code: "late", message: "stale sample-line failure"))
        await oldCompute.value
        #expect(session.sampleLineSeries.first?.points.compactMap(\.value) == [4, 5, 6])
        #expect(session.sampleLineError == nil && !session.isComputingSampleLine)
    }

    @Test @MainActor
    func chartContainsOnlyReturnedSourceSeriesAndPreservesMissingSamplesAsGaps() throws {
        let path = "/fixture/primary.hdf"
        let points = [
            ResultProfileSampleLinePoint(profileIndex: 0, time: "2026-10-16T00:00:00.0000000", value: 2.5),
            ResultProfileSampleLinePoint(profileIndex: 1, time: "2026-10-16T00:30:00.0000000", value: nil),
            ResultProfileSampleLinePoint(profileIndex: 2, time: "2026-10-16T01:00:00.0000000", value: 7.5)
        ]
        let available = ResultProfileSampleLineSeries(resultPath: path, revision: "source-revision",
            resultName: "Primary", mode: "Flow", quantity: "Flow", units: "CFS",
            available: true, unavailableReason: nil, points: points)
        let unavailable = ResultProfileSampleLineSeries(resultPath: "/fixture/no-data.hdf", revision: "no-data",
            resultName: "No Data", mode: "Flow", quantity: "Flow", units: "CFS",
            available: false, unavailableReason: "no stored flow state", points: [])
        let samples = ResultProfileSampleLineChartData.samples(for: [available, unavailable])
        #expect(samples.count == 3)
        #expect(samples[0].y == 2.5 && samples[1].y.isNaN && samples[2].y == 7.5)
        #expect(Set(samples.map(\.datasetKey)) == ["result-sample-line/0"])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_RESULT_SAMPLE_LINE_ACCEPTANCE_DIRECTORY"] != nil
        && ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil)) @MainActor
    func retainedResultCallbackProducesRealFlowAndAccumulatedOverlayValuesWithoutChangingHDF() async throws {
        let environment = ProcessInfo.processInfo.environment
        let fixture = URL(fileURLWithPath: try #require(environment["HECRAS_RESULT_SAMPLE_LINE_ACCEPTANCE_DIRECTORY"]))
        // Retained post-processing creates a sibling PostProcess.h5 cache.
        // Exercise that real path in a disposable copy, leaving fixtures immutable.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("result-sample-line-" + UUID().uuidString)
        try FileManager.default.copyItem(at: fixture, to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = try #require(environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let files = try FileManager.default.subpathsOfDirectory(atPath: root.path)
        let projectRelative = try #require(files.first { $0.hasSuffix(".ras") })
        let projectURL = root.appendingPathComponent(projectRelative)
        let resultPaths = files.filter { $0.hasSuffix(".h5") && $0.contains("Results/") }
            .map { root.appendingPathComponent($0).resolvingSymlinksInPath().standardizedFileURL.path }
        let primaryPath = try #require(resultPaths.first { $0.hasSuffix("Sample Line Primary.h5") })
        let projectXML = try String(contentsOf: projectURL, encoding: .utf8)
        let originalBytes = try Dictionary(uniqueKeysWithValues: resultPaths.map { path in
            (path, try Data(contentsOf: URL(fileURLWithPath: path)))
        })
        let primaryBytes = try #require(originalBytes[primaryPath])
        let revision = Self.revision(primaryBytes)
        let provider = BackendResultProfileProvider(client: BackendProcessClient(executableURL: URL(fileURLWithPath: backend)))
        let session = ResultProfileSession(provider: provider)
        await session.load(ResultProfileIdentity(resultPath: primaryPath, revision: revision))
        await session.loadSampleSources(projectPath: projectURL.path, projectXml: projectXML, contextID: "source-fixture")
        #expect(session.sampleLineError == nil)
        #expect(session.sampleLineSources?.sources.count == 2)
        #expect(session.sampleLineSources?.firstFlowAreaCellCount == 1)

        await session.loadSampleLineMap()
        #expect(session.sampleLineMapData?.flowAreaIndex == 0 && session.sampleLineMapData?.elementKind == "Cell")
        session.addSampleLinePoint(.init(x: 0.5, y: 0.05))
        session.addSampleLinePoint(.init(x: 0.5, y: 0.95))
        let peer = try #require(session.sampleLineSources?.sources.first { $0.resultPath != primaryPath })
        session.setSampleLineSource(peer.resultPath, selected: true)
        await session.computeSampleLine()
        #expect(session.sampleLineError == nil && session.sampleLineSeries.count == 2)
        #expect(session.sampleLineSeries.allSatisfy { $0.available && $0.points.count == 3 })
        #expect(session.sampleLineSeries.contains { $0.points.contains { ($0.value ?? 0) != 0 } })

        session.setSampleLineMode(.cumulativeVolume)
        await session.computeSampleLine()
        #expect(session.sampleLineError == nil && session.sampleLineSeries.count == 2)
        #expect(session.sampleLineSeries.allSatisfy { $0.available && $0.quantity == "Volume" && $0.points.count == 3 })
        #expect(session.sampleLineSeries.allSatisfy { $0.points.contains { ($0.value ?? 0) != 0 } })
        for path in resultPaths {
            #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == originalBytes[path])
        }
    }
}

@MainActor
private func waitForSampleLine(_ predicate: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !predicate() {
        if ContinuousClock.now >= deadline { throw SampleLineTestError.timedOut }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private func sampleCatalog(identity: ResultProfileIdentity) -> ResultProfileCatalog {
    let variables = [ResultProfileVariable(id: "Cell Depth", name: "Cell Depth", elementKind: "Cell", quantity: "Length", units: "m")]
    let block = ResultProfileOutputBlock(name: "Base Output", profileCount: 3,
        profileNames: ["P0", "P1", "P2"], times: [
            "2026-10-16T00:00:00.0000000", "2026-10-16T00:30:00.0000000", "2026-10-16T01:00:00.0000000"
        ], variables: variables)
    return ResultProfileCatalog(resultPath: identity.resultPath, revision: identity.revision,
        resultName: URL(fileURLWithPath: identity.resultPath).deletingPathExtension().lastPathComponent,
        outputBlocks: [block], flowAreas: [ResultProfileFlowArea(index: 0, name: "First Area", cellCount: 1, faceCount: 4)])
}

@MainActor
private func sampleSources(projectPath: String, identity: ResultProfileIdentity) -> ResultProfileSources {
    let primary = ResultProfileSourceChoice(resultPath: identity.resultPath, revision: identity.revision,
        resultName: "Primary", embeddedPlanName: "Plan A", profileCount: 3,
        firstFlowAreaName: "First Area", firstFlowAreaCellCount: 1, firstFlowAreaFaceCount: 4)
    let peer = ResultProfileSourceChoice(resultPath: "/fixture/peer.hdf", revision: "peer-revision",
        resultName: "Peer", embeddedPlanName: "Plan A", profileCount: 3,
        firstFlowAreaName: "First Area", firstFlowAreaCellCount: 1, firstFlowAreaFaceCount: 4)
    return ResultProfileSources(projectPath: projectPath, resultPath: identity.resultPath,
        revision: identity.revision, embeddedPlanName: "Plan A", firstFlowAreaName: "First Area",
        firstFlowAreaCellCount: 1, firstFlowAreaFaceCount: 4, sources: [primary, peer])
}

private func sampleMap(identity: ResultProfileIdentity, flowAreaIndex: Int, elementKind: String) -> ResultProfileMapResult {
    let feature = ResultProfileMapElement(elementIndex: 0, paths: [[
        .init(x: 0, y: 0), .init(x: 1, y: 0), .init(x: 1, y: 1), .init(x: 0, y: 1), .init(x: 0, y: 0)
    ]])
    return ResultProfileMapResult(resultPath: identity.resultPath, revision: identity.revision,
        flowAreaName: "First Area", flowAreaIndex: flowAreaIndex, elementKind: elementKind,
        available: true, unavailableReason: nil, sourceExtent: .init(minX: 0, minY: 0, maxX: 1, maxY: 1),
        requestedExtent: nil, totalElements: 1, intersectingElements: 1, returnedElements: 1,
        elementLimit: 2500, vertexLimit: 120_000, isComplete: true, requiresZoom: false, elements: [feature])
}

private func sampleStoredSeries(identity: ResultProfileIdentity, selection: ResultProfileSelection) -> ResultProfileSeries {
    ResultProfileSeries(resultPath: identity.resultPath, revision: identity.revision,
        resultName: "Primary", outputBlockName: selection.outputBlockName, variable: selection.variableID,
        flowAreaName: "First Area", flowAreaIndex: selection.flowAreaIndex, elementIndex: selection.elementIndex,
        elementKind: "Cell", quantity: "Length", units: "m", available: true, unavailableReason: nil, points: [])
}

private func sampleSampleLineResult(_ request: ResultProfileSampleLineRequest,
                                    values: [Double]) -> ResultProfileSampleLineResult {
    let series = request.sources.map { source in
        ResultProfileSampleLineSeries(resultPath: source.resultPath, revision: source.revision,
            resultName: URL(fileURLWithPath: source.resultPath).deletingPathExtension().lastPathComponent,
            mode: request.mode, quantity: request.mode == "Flow" ? "Flow" : "Volume", units: "CFS",
            available: true, unavailableReason: nil, points: values.enumerated().map { index, value in
                ResultProfileSampleLinePoint(profileIndex: index,
                time: ["2026-10-16T00:00:00.0000000", "2026-10-16T00:30:00.0000000", "2026-10-16T01:00:00.0000000"][index], value: value)
            })
    }
    return ResultProfileSampleLineResult(projectPath: request.projectPath, resultPath: request.resultPath,
        revision: request.revision, mode: request.mode, sampleLine: request.sampleLine, series: series)
}

private extension ResultProfileSampleLineTests {
    static func revision(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().uppercased()
    }
}

private enum SampleLineTestError: Error { case timedOut }
