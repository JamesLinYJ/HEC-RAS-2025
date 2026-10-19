import Foundation
import Testing
@testable import HECRAS2025

struct ReprojectionSessionTests {
    @Test
    func identificationFailuresKeepSourceDiagnosticsAndExactFileOwnership() throws {
        let path = "/tmp/reprojection-accepted.prj"
        let request = ReprojectionIdentifyRequest(paths: [path])
        let failure = ReprojectionIdentifySnapshot(
            recognizedPath: path, wkt: nil, projectionSummary: nil,
            errorMessage: "The source coordinate system could not be exported.")
        try failure.validate(for: request)
        #expect(failure.errorMessage == "The source coordinate system could not be exported.")

        #expect(throws: ReprojectionProviderError.self) {
            try failure.validate(for: ReprojectionIdentifyRequest(paths: ["/tmp/another-model.h5"]))
        }
    }

    @Test @MainActor
    func sessionKeepsSourceDefaultsRawRowsAndFiveRowAdditions() async {
        let provider = ImmediateReprojectionProvider()
        let session = ReprojectionSession(provider: provider)
        let projectSessionID = UUID()
        let identity = ReprojectionSession.contextIdentity(projectSessionID: projectSessionID, projectProjection: nil)
        session.configure(projectSessionID: projectSessionID, projectProjection: nil, contextIdentity: identity)

        #expect(session.sourceOption == .wgs84)
        #expect(session.destinationOption == .project)
        #expect(session.rows.count == 10)

        let firstID = session.rows[0].id
        session.setCoordinate(rowID: firstID, axis: .x, text: " 001.250 ")
        session.setCoordinate(rowID: firstID, axis: .y, text: " 002.500 ")
        session.setOption(.custom, for: .source)
        session.setCustomProjectionText("32650", for: .source)
        session.setOption(.wgs84, for: .source)
        #expect(session.sourceCustomProjectionText.isEmpty)

        session.addRows()
        #expect(session.rows.count == 15)
        await session.transformNow()

        let request = provider.requests.last
        #expect(request?.sourceOption == "WGS84")
        #expect(request?.destinationOption == "Project")
        #expect(request?.rows.count == 15)
        #expect(request?.rows.first?.xText == " 001.250 ")
        #expect(request?.rows.first?.yText == " 002.500 ")
        #expect(session.resultsByID[firstID]?.status == .transformed)

        session.setCoordinate(rowID: firstID, axis: .y, text: "unfinished")
        #expect(session.resultsByID[firstID] == nil)
        await session.transformNow()
        #expect(session.resultsByID[firstID]?.status == .invalid)
        #expect(session.resultsByID[firstID]?.x == nil && session.resultsByID[firstID]?.y == nil)
    }

    @Test @MainActor
    func lateTransformFromPreviousProjectCannotReplaceCurrentResults() async {
        let provider = DeferredReprojectionProvider()
        let session = ReprojectionSession(provider: provider)
        let firstProject = UUID()
        let firstIdentity = ReprojectionSession.contextIdentity(projectSessionID: firstProject, projectProjection: nil)
        session.configure(projectSessionID: firstProject, projectProjection: nil, contextIdentity: firstIdentity)
        let rowID = session.rows[0].id
        session.setCoordinate(rowID: rowID, axis: .x, text: "1")
        session.setCoordinate(rowID: rowID, axis: .y, text: "2")

        let firstRequestTask = Task { await session.transformNow() }
        let firstStarted = await waitUntil { provider.transformRequests.count == 1 }
        #expect(firstStarted)
        guard firstStarted else { session.close(); return }

        let secondProject = UUID()
        let secondIdentity = ReprojectionSession.contextIdentity(projectSessionID: secondProject, projectProjection: nil)
        session.configure(projectSessionID: secondProject, projectProjection: nil, contextIdentity: secondIdentity)
        let secondStarted = await waitUntil { provider.transformRequests.count == 2 }
        #expect(secondStarted)
        guard secondStarted else { session.close(); provider.resolveTransform(0, x: 11); await firstRequestTask.value; return }

        provider.resolveTransform(1, x: 22)
        let secondInstalled = await waitUntil { session.resultsByID[rowID]?.x == 22.0 }
        #expect(secondInstalled)

        provider.resolveTransform(0, x: 11)
        await firstRequestTask.value
        #expect(session.resultsByID[rowID]?.x == 22.0)
        #expect(session.errorMessage == nil)
        session.close()
    }

    @Test @MainActor
    func editingProjectionWhileIdentificationIsInFlightKeepsTheNewInput() async {
        let provider = DeferredReprojectionProvider()
        let session = ReprojectionSession(provider: provider)
        let projectSessionID = UUID()
        session.configure(
            projectSessionID: projectSessionID,
            projectProjection: nil,
            contextIdentity: ReprojectionSession.contextIdentity(projectSessionID: projectSessionID, projectProjection: nil))

        let file = URL(fileURLWithPath: "/tmp/reprojection-source.prj")
        let identifyTask = Task { await session.identifyProjection(paths: [file], for: .source) }
        let identifyStarted = await waitUntil { provider.identifyRequests.count == 1 }
        #expect(identifyStarted)
        guard identifyStarted else { session.close(); return }

        session.setCustomProjectionText("manual CRS text", for: .source)
        provider.resolveIdentify(0, path: file.path)
        await identifyTask.value

        #expect(session.sourceOption == .wgs84)
        #expect(session.sourceCustomProjectionText == "manual CRS text")
        #expect(session.identifyError == nil)
        session.close()
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

@MainActor
private final class ImmediateReprojectionProvider: ReprojectionProvider {
    private(set) var requests: [ReprojectionRequest] = []

    func transform(_ request: ReprojectionRequest) async throws -> ReprojectionSnapshot {
        requests.append(request)
        return ReprojectionSnapshot(
            sourceSummary: request.sourceOption,
            destinationSummary: request.destinationOption,
            errorCode: nil,
            errorMessage: nil,
            rows: request.rows.map { row in
                let xText = row.xText.trimmingCharacters(in: .whitespacesAndNewlines)
                let yText = row.yText.trimmingCharacters(in: .whitespacesAndNewlines)
                if xText.isEmpty || yText.isEmpty {
                    return ReprojectionRowResult(id: row.id, status: .blank, x: nil, y: nil)
                }
                guard let x = Double(xText), let y = Double(yText), x.isFinite, y.isFinite else {
                    return ReprojectionRowResult(id: row.id, status: .invalid, x: nil, y: nil)
                }
                return ReprojectionRowResult(id: row.id, status: .transformed, x: x, y: y)
            },
            sourceProjectionSummary: nil,
            destinationProjectionSummary: nil)
    }

    func identify(_ request: ReprojectionIdentifyRequest) async throws -> ReprojectionIdentifySnapshot {
        ReprojectionIdentifySnapshot(recognizedPath: nil, wkt: nil, projectionSummary: nil, errorMessage: nil)
    }
}

@MainActor
private final class DeferredReprojectionProvider: ReprojectionProvider {
    private(set) var transformRequests: [ReprojectionRequest] = []
    private(set) var identifyRequests: [ReprojectionIdentifyRequest] = []
    private var transformContinuations: [CheckedContinuation<ReprojectionSnapshot, any Error>?] = []
    private var identifyContinuations: [CheckedContinuation<ReprojectionIdentifySnapshot, any Error>?] = []

    func transform(_ request: ReprojectionRequest) async throws -> ReprojectionSnapshot {
        transformRequests.append(request)
        return try await withCheckedThrowingContinuation { continuation in
            transformContinuations.append(continuation)
        }
    }

    func identify(_ request: ReprojectionIdentifyRequest) async throws -> ReprojectionIdentifySnapshot {
        identifyRequests.append(request)
        return try await withCheckedThrowingContinuation { continuation in
            identifyContinuations.append(continuation)
        }
    }

    func resolveTransform(_ index: Int, x: Double) {
        guard transformContinuations.indices.contains(index), let continuation = transformContinuations[index],
              transformRequests.indices.contains(index) else { return }
        let request = transformRequests[index]
        transformContinuations[index] = nil
        let rows = request.rows.enumerated().map { offset, row in
            offset == 0
                ? ReprojectionRowResult(id: row.id, status: .transformed, x: x, y: x + 1)
                : ReprojectionRowResult(id: row.id, status: .blank, x: nil, y: nil)
        }
        continuation.resume(returning: ReprojectionSnapshot(
            sourceSummary: request.sourceOption,
            destinationSummary: request.destinationOption,
            errorCode: nil,
            errorMessage: nil,
            rows: rows,
            sourceProjectionSummary: nil,
            destinationProjectionSummary: nil))
    }

    func resolveIdentify(_ index: Int, path: String) {
        guard identifyContinuations.indices.contains(index), let continuation = identifyContinuations[index] else { return }
        identifyContinuations[index] = nil
        continuation.resume(returning: ReprojectionIdentifySnapshot(
            recognizedPath: path,
            wkt: "PROJCRS[\"Test CRS\"]",
            projectionSummary: ReprojectionProjectionSummary(
                option: "Custom", projectionName: "Test CRS", validity: "True", unitName: "metre",
                isVertical: false, isProjected: true, epsgCode: nil, utmZone: nil),
            errorMessage: nil))
    }
}
