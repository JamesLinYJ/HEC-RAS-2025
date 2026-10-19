import CryptoKit
import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class DelayedResultProfileProvider: ResultProfileProvider {
    private(set) var catalogRequests: [(resultPath: String, revision: String)] = []
    private(set) var mapRequests: [(resultPath: String, revision: String, flowAreaIndex: Int,
        elementKind: String, extent: GeometryTopologyExtent?, limit: Int)] = []
    private(set) var seriesRequests: [(resultPath: String, revision: String, selection: ResultProfileSelection)] = []
    private var catalogContinuations: [Int: CheckedContinuation<ResultProfileCatalog, any Error>] = [:]
    private var mapContinuations: [Int: CheckedContinuation<ResultProfileMapResult, any Error>] = [:]
    private var seriesContinuations: [Int: CheckedContinuation<ResultProfileSeries, any Error>] = [:]

    func loadCatalog(resultPath: String, revision: String) async throws -> ResultProfileCatalog {
        let request = catalogRequests.count + 1
        catalogRequests.append((resultPath, revision))
        return try await withCheckedThrowingContinuation { catalogContinuations[request] = $0 }
    }

    func loadMap(resultPath: String, revision: String, flowAreaIndex: Int, elementKind: String,
                 extent: GeometryTopologyExtent?, limit: Int) async throws -> ResultProfileMapResult {
        let request = mapRequests.count + 1
        mapRequests.append((resultPath, revision, flowAreaIndex, elementKind, extent, limit))
        return try await withCheckedThrowingContinuation { mapContinuations[request] = $0 }
    }

    func readSeries(resultPath: String, revision: String, selection: ResultProfileSelection) async throws -> ResultProfileSeries {
        let request = seriesRequests.count + 1
        seriesRequests.append((resultPath, revision, selection))
        return try await withCheckedThrowingContinuation { seriesContinuations[request] = $0 }
    }

    func finishCatalog(_ request: Int, with value: ResultProfileCatalog) {
        catalogContinuations.removeValue(forKey: request)?.resume(returning: value)
    }

    func finishMap(_ request: Int, with value: ResultProfileMapResult) {
        mapContinuations.removeValue(forKey: request)?.resume(returning: value)
    }

    func failMap(_ request: Int, with error: any Error) {
        mapContinuations.removeValue(forKey: request)?.resume(throwing: error)
    }

    func failCatalog(_ request: Int, with error: any Error) {
        catalogContinuations.removeValue(forKey: request)?.resume(throwing: error)
    }

    func finishSeries(_ request: Int, with value: ResultProfileSeries) {
        seriesContinuations.removeValue(forKey: request)?.resume(returning: value)
    }
}

@MainActor
private struct ImmediateResultProfileProvider: ResultProfileProvider {
    let catalog: ResultProfileCatalog
    var catalogError: (any Error)? = nil

    func loadCatalog(resultPath: String, revision: String) async throws -> ResultProfileCatalog {
        if let catalogError { throw catalogError }
        return catalog
    }

    func loadMap(resultPath: String, revision: String, flowAreaIndex: Int, elementKind: String,
                 extent: GeometryTopologyExtent?, limit: Int) async throws -> ResultProfileMapResult {
        resultMap(identity: ResultProfileIdentity(resultPath: resultPath, revision: revision),
            flowAreaIndex: flowAreaIndex, elementKind: elementKind, extent: extent, indices: [])
    }

    func readSeries(resultPath: String, revision: String, selection: ResultProfileSelection) async throws -> ResultProfileSeries {
        throw BackendServiceError(code: "unavailable", message: "The fixture has no stored series.")
    }
}

@Suite(.serialized)
struct ResultProfileTests {
    @Test @MainActor
    func emptyCatalogAndMissingResultDoNotInventSeries() async throws {
        let identity = ResultProfileIdentity(resultPath: "/fixture/empty-result.hdf", revision: "empty-revision")
        let empty = ResultProfileCatalog(resultPath: identity.resultPath, revision: identity.revision,
            resultName: "Empty", outputBlocks: [], flowAreas: [])
        let session = ResultProfileSession(provider: ImmediateResultProfileProvider(catalog: empty))
        await session.load(identity)
        #expect(session.catalog?.outputBlocks.isEmpty == true)
        #expect(session.selection == nil && session.series == nil)
        #expect(ResultProfileChartData.samples(for: unavailableSeries(identity: identity)).isEmpty)

        let missingProvider = ImmediateResultProfileProvider(catalog: empty,
            catalogError: BackendServiceError(code: "notFound", message: "The selected result file was not found."))
        let missing = ResultProfileSession(provider: missingProvider)
        await missing.load(identity)
        #expect(missing.catalog == nil && missing.series == nil)
        #expect(missing.error == L10n.text("The selected result file was not found."))
    }

    @Test @MainActor
    func chartSamplesAreOnlyStoredValuesAndMissingRowsRemainGaps() throws {
        let identity = ResultProfileIdentity(resultPath: "/fixture/profile-result.hdf", revision: "profile-revision")
        let points = [
            ResultProfilePoint(profileIndex: 0, profileName: "P0", time: "2026-10-16T00:00:00.0000000", value: 2.75),
            ResultProfilePoint(profileIndex: 1, profileName: "P1", time: "2026-10-16T00:30:00.0000000", value: nil),
            ResultProfilePoint(profileIndex: 2, profileName: "P2", time: "2026-10-16T01:00:00.0000000", value: 4.25)
        ]
        let series = ResultProfileSeries(resultPath: identity.resultPath, revision: identity.revision,
            resultName: "Stored Result", outputBlockName: "Base Output", variable: "Cell Depth",
            flowAreaName: "Single Cell", flowAreaIndex: 0, elementIndex: 0, elementKind: "Cell",
            quantity: "Length", units: "ft", available: true, unavailableReason: nil, points: points)
        let samples = ResultProfileChartData.samples(for: series)
        #expect(samples.count == 3)
        #expect(samples[0].y == 2.75 && samples[1].y.isNaN && samples[2].y == 4.25)
        #expect(samples.map(\.id) == ["profile/0", "profile/1", "profile/2"])
        #expect(samples.allSatisfy { $0.datasetID == ResultProfileChartData.datasetID })
        #expect(samples[0].x < samples[1].x && samples[1].x < samples[2].x)
        #expect(ResultProfileChartData.samples(for: unavailableSeries(identity: identity, points: points)).isEmpty)
    }

    @Test @MainActor
    func oldResultAndSelectionRepliesAreDiscarded() async throws {
        let provider = DelayedResultProfileProvider()
        let session = ResultProfileSession(provider: provider)
        let first = ResultProfileIdentity(resultPath: "/fixture/first.hdf", revision: "first-rev")
        let second = ResultProfileIdentity(resultPath: "/fixture/second.hdf", revision: "second-rev")

        let firstLoad = Task { await session.load(first) }
        try await waitUntil { provider.catalogRequests.count == 1 }
        let secondLoad = Task { await session.load(second) }
        try await waitUntil { provider.catalogRequests.count == 2 }
        provider.finishCatalog(2, with: catalog(identity: second))
        await secondLoad.value
        #expect(session.identity == second && session.catalog?.resultPath == second.resultPath)
        provider.finishCatalog(1, with: catalog(identity: first))
        await firstLoad.value
        #expect(session.identity == second && session.catalog?.resultPath == second.resultPath)

        let oldSelection = try #require(session.selection)
        let oldRead = Task { await session.readSelectedSeries() }
        try await waitUntil { provider.seriesRequests.count == 1 }
        let newSelection = ResultProfileSelection(outputBlockName: "Base Output", variableID: "Face Velocity",
            flowAreaIndex: 1, elementIndex: 6)
        session.select(newSelection)
        let newRead = Task { await session.readSelectedSeries() }
        try await waitUntil { provider.seriesRequests.count == 2 }

        provider.finishSeries(2, with: series(identity: second, selection: newSelection, values: [8, 9]))
        await newRead.value
        #expect(session.selection == newSelection && session.series?.elementIndex == 6)
        provider.finishSeries(1, with: series(identity: second, selection: oldSelection, values: [1, 2]))
        await oldRead.value
        #expect(session.selection == newSelection && session.series?.elementIndex == 6)
        #expect(session.series?.points.map(\.value) == [8.0, 9.0])
    }

    @Test @MainActor
    func cancellationPreventsLateSeriesFromInstalling() async throws {
        let provider = DelayedResultProfileProvider()
        let identity = ResultProfileIdentity(resultPath: "/fixture/cancel.hdf", revision: "cancel-rev")
        let session = ResultProfileSession(provider: provider)
        let load = Task { await session.load(identity) }
        try await waitUntil { provider.catalogRequests.count == 1 }
        provider.finishCatalog(1, with: catalog(identity: identity))
        await load.value
        let selection = try #require(session.selection)
        let read = Task { await session.readSelectedSeries() }
        try await waitUntil { provider.seriesRequests.count == 1 }

        session.cancel()
        provider.finishSeries(1, with: series(identity: identity, selection: selection, values: [42]))
        await read.value
        #expect(session.series == nil && !session.isLoadingSeries)
    }

    @Test @MainActor
    func olderViewportGeometryCannotReplaceNewerMapRequest() async throws {
        let provider = DelayedResultProfileProvider()
        let identity = ResultProfileIdentity(resultPath: "/fixture/map-generation.hdf", revision: "map-rev")
        let session = ResultProfileSession(provider: provider)
        let load = Task { await session.load(identity) }
        try await waitUntil { provider.catalogRequests.count == 1 }
        provider.finishCatalog(1, with: catalog(identity: identity))
        await load.value

        let firstExtent = GeometryTopologyExtent(minX: 0, minY: 0, maxX: 8, maxY: 8)
        let secondExtent = GeometryTopologyExtent(minX: 2, minY: 2, maxX: 4, maxY: 4)
        let first = Task { await session.loadMap(flowAreaIndex: 0, elementKind: "Cell", extent: firstExtent) }
        try await waitUntil { provider.mapRequests.count == 1 }
        let second = Task { await session.loadMap(flowAreaIndex: 0, elementKind: "Cell", extent: secondExtent) }
        try await waitUntil { provider.mapRequests.count == 2 }

        provider.finishMap(2, with: resultMap(identity: identity, flowAreaIndex: 0, elementKind: "Cell",
            extent: secondExtent, indices: [0]))
        await second.value
        #expect(session.mapData?.requestedExtent == secondExtent)
        provider.finishMap(1, with: resultMap(identity: identity, flowAreaIndex: 0, elementKind: "Cell",
            extent: firstExtent, indices: [0, 1]))
        await first.value
        #expect(session.mapData?.requestedExtent == secondExtent)
        #expect(session.mapData?.elements.map(\.elementIndex) == [0])
    }

    @Test @MainActor
    func canceledMapRequestCannotInstallLateGeometry() async throws {
        let provider = DelayedResultProfileProvider()
        let identity = ResultProfileIdentity(resultPath: "/fixture/cancel-map.hdf", revision: "cancel-map-rev")
        let session = ResultProfileSession(provider: provider)
        let load = Task { await session.load(identity) }
        try await waitUntil { provider.catalogRequests.count == 1 }
        provider.finishCatalog(1, with: catalog(identity: identity))
        await load.value

        let request = Task { await session.loadMap(flowAreaIndex: 0, elementKind: "Cell") }
        try await waitUntil { provider.mapRequests.count == 1 }
        session.cancelMap()
        provider.finishMap(1, with: resultMap(identity: identity, flowAreaIndex: 0, elementKind: "Cell",
            extent: nil, indices: [0]))
        await request.value

        #expect(session.mapData == nil && !session.isLoadingMap)
    }

    @Test @MainActor
    func lateMapFailureFromPreviousResultDoesNotReplaceCurrentState() async throws {
        let provider = DelayedResultProfileProvider()
        let firstIdentity = ResultProfileIdentity(resultPath: "/fixture/first-map.hdf", revision: "first-map-rev")
        let secondIdentity = ResultProfileIdentity(resultPath: "/fixture/second-map.hdf", revision: "second-map-rev")
        let session = ResultProfileSession(provider: provider)

        let firstLoad = Task { await session.load(firstIdentity) }
        try await waitUntil { provider.catalogRequests.count == 1 }
        provider.finishCatalog(1, with: catalog(identity: firstIdentity))
        await firstLoad.value

        let oldMap = Task { await session.loadMap(flowAreaIndex: 0, elementKind: "Cell") }
        try await waitUntil { provider.mapRequests.count == 1 }
        let secondLoad = Task { await session.load(secondIdentity) }
        try await waitUntil { provider.catalogRequests.count == 2 }
        provider.finishCatalog(2, with: catalog(identity: secondIdentity))
        await secondLoad.value

        provider.failMap(1, with: BackendServiceError(code: "stale", message: "late map failure"))
        await oldMap.value
        #expect(session.identity == secondIdentity)
        #expect(session.catalog?.resultPath == secondIdentity.resultPath)
        #expect(session.mapData == nil && session.error == nil && !session.isLoadingMap)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_RESULT_PROFILE_ACCEPTANCE_RESULT"] != nil
        && ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil)) @MainActor
    func exportedSourceOutputBlockFixtureFlowsThroughBackendAndStaysReadOnly() async throws {
        let resultPath = try #require(ProcessInfo.processInfo.environment["HECRAS_RESULT_PROFILE_ACCEPTANCE_RESULT"])
        let backendPath = try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"])
        let resultURL = URL(fileURLWithPath: resultPath).standardizedFileURL
        let before = try Data(contentsOf: resultURL)
        let revision = SHA256.hash(data: before).map { String(format: "%02x", $0) }.joined().uppercased()
        let provider = BackendResultProfileProvider(client: BackendProcessClient(executableURL: URL(fileURLWithPath: backendPath)))
        let session = ResultProfileSession(provider: provider)
        await session.load(ResultProfileIdentity(resultPath: resultURL.path, revision: revision))
        #expect(session.error == nil && session.catalog?.outputBlocks.contains { $0.profileCount == 3 } == true)

        await session.loadMap(flowAreaIndex: 0, elementKind: "Cell")
        let mappedCell = try #require(session.mapData?.elements.first { $0.elementIndex == 0 })
        #expect(session.mapData?.isComplete == true && mappedCell.paths.first?.count == 5)
        #expect(mappedCell.paths.first?.first == mappedCell.paths.first?.last)
        let cellSelection = ResultProfileSelection(outputBlockName: "Base Output", variableID: "Cell Depth",
            flowAreaIndex: 0, elementIndex: mappedCell.elementIndex)
        session.select(cellSelection)
        await session.readSelectedSeries()
        #expect(session.series?.available == true)
        #expect(session.series?.units == "ft")
        #expect(session.series?.points.map(\.value) == [2.75, 3.5, 4.25])

        await session.loadMap(flowAreaIndex: 0, elementKind: "Face")
        let mappedFace = try #require(session.mapData?.elements.first { $0.elementIndex == 2 })
        #expect(session.mapData?.isComplete == true && mappedFace.paths.first?.count == 2)
        let faceSelection = ResultProfileSelection(outputBlockName: "Base Output", variableID: "Face Velocity",
            flowAreaIndex: 0, elementIndex: mappedFace.elementIndex)
        session.select(faceSelection)
        await session.readSelectedSeries()
        #expect(session.series?.available == true)
        #expect(session.series?.units == "ft/s")
        #expect(session.series?.points.map(\.value) == [1.25, -1.25, 0.125])
        #expect(try Data(contentsOf: resultURL) == before)

        let missingSession = ResultProfileSession(provider: provider)
        await missingSession.load(ResultProfileIdentity(resultPath: resultURL.appendingPathExtension("missing").path,
            revision: revision))
        #expect(missingSession.catalog == nil && missingSession.series == nil && missingSession.error != nil)
    }
}

@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !condition() {
        if ContinuousClock.now >= deadline { throw ResultProfileTestError.timedOut }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
private func catalog(identity: ResultProfileIdentity) -> ResultProfileCatalog {
    let variables = [
        ResultProfileVariable(id: "Cell Depth", name: "Cell Depth", elementKind: "Cell", quantity: "Length", units: "m"),
        ResultProfileVariable(id: "Face Velocity", name: "Face Velocity", elementKind: "Face", quantity: "Velocity", units: "m/s")
    ]
    let block = ResultProfileOutputBlock(name: "Base Output", profileCount: 2,
        profileNames: ["P0", "P1"], times: ["2026-10-16T00:00:00.0000000", "2026-10-16T00:30:00.0000000"], variables: variables)
    return ResultProfileCatalog(resultPath: identity.resultPath, revision: identity.revision,
        resultName: "Source Result", outputBlocks: [block], flowAreas: [
            ResultProfileFlowArea(index: 0, name: "Small Mesh", cellCount: 1, faceCount: 4),
            ResultProfileFlowArea(index: 1, name: "Large Mesh", cellCount: 2, faceCount: 7)
        ])
}

@MainActor
private func resultMap(identity: ResultProfileIdentity, flowAreaIndex: Int, elementKind: String,
                 extent: GeometryTopologyExtent?, indices: [Int]) -> ResultProfileMapResult {
    let elements = indices.map { index in
        ResultProfileMapElement(elementIndex: index, paths: [[
            GeometryTopologyCoordinate(x: Double(index), y: 0),
            GeometryTopologyCoordinate(x: Double(index + 1), y: 0),
            GeometryTopologyCoordinate(x: Double(index + 1), y: 1),
            GeometryTopologyCoordinate(x: Double(index), y: 1)
        ]])
    }
    return ResultProfileMapResult(resultPath: identity.resultPath, revision: identity.revision,
        flowAreaName: "Small Mesh", flowAreaIndex: flowAreaIndex, elementKind: elementKind,
        available: true, unavailableReason: nil,
        sourceExtent: GeometryTopologyExtent(minX: 0, minY: 0, maxX: 2, maxY: 1),
        requestedExtent: extent, totalElements: 2, intersectingElements: elements.count,
        returnedElements: elements.count, elementLimit: 2500, vertexLimit: 120_000,
        isComplete: true, requiresZoom: false, elements: elements)
}

@MainActor
private func series(identity: ResultProfileIdentity, selection: ResultProfileSelection, values: [Double]) -> ResultProfileSeries {
    let points = values.enumerated().map { index, value in
        ResultProfilePoint(profileIndex: index, profileName: "P\(index)",
            time: "2026-10-16T00:\(index == 0 ? "00" : "30"):00.0000000", value: value)
    }
    let variable = selection.variableID == "Face Velocity"
    return ResultProfileSeries(resultPath: identity.resultPath, revision: identity.revision,
        resultName: "Source Result", outputBlockName: selection.outputBlockName,
        variable: selection.variableID, flowAreaName: selection.flowAreaIndex == 0 ? "Small Mesh" : "Large Mesh",
        flowAreaIndex: selection.flowAreaIndex, elementIndex: selection.elementIndex,
        elementKind: variable ? "Face" : "Cell", quantity: variable ? "Velocity" : "Length",
        units: variable ? "m/s" : "m", available: true, unavailableReason: nil, points: points)
}

@MainActor
private func unavailableSeries(identity: ResultProfileIdentity, points: [ResultProfilePoint] = []) -> ResultProfileSeries {
    ResultProfileSeries(resultPath: identity.resultPath, revision: identity.revision,
        resultName: "Empty", outputBlockName: "Base Output", variable: "Cell Depth",
        flowAreaName: "", flowAreaIndex: 0, elementIndex: 0, elementKind: "Cell",
        quantity: "Length", units: "m", available: false, unavailableReason: "No stored profile values.", points: points)
}

private enum ResultProfileTestError: Error { case timedOut }
