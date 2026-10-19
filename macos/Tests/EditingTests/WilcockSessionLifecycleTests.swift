import Foundation
import Testing
@testable import HECRAS2025

@MainActor
private final class DeferredWilcockProvider: WilcockProvider {
    private let initialSnapshot: WilcockWorkspaceSnapshot?
    private(set) var loadRequests = 0
    private(set) var evaluateRequests: [WilcockEvaluateRequest] = []
    private var loadContinuations: [Int: CheckedContinuation<WilcockWorkspaceSnapshot, any Error>] = [:]
    private var evaluateContinuations: [Int: CheckedContinuation<WilcockWorkspaceSnapshot, any Error>] = [:]

    init(initialSnapshot: WilcockWorkspaceSnapshot? = nil) {
        self.initialSnapshot = initialSnapshot
    }

    func load(numberCulture: String) async throws -> WilcockWorkspaceSnapshot {
        loadRequests += 1
        if let initialSnapshot { return initialSnapshot }
        let request = loadRequests
        return try await withCheckedThrowingContinuation { loadContinuations[request] = $0 }
    }

    func evaluate(_ request: WilcockEvaluateRequest) async throws -> WilcockWorkspaceSnapshot {
        evaluateRequests.append(request)
        let index = evaluateRequests.count
        return try await withCheckedThrowingContinuation { evaluateContinuations[index] = $0 }
    }

    func finishLoad(_ request: Int = 1, with snapshot: WilcockWorkspaceSnapshot) {
        loadContinuations.removeValue(forKey: request)?.resume(returning: snapshot)
    }

    func finishEvaluation(_ request: Int = 1, with snapshot: WilcockWorkspaceSnapshot) {
        evaluateContinuations.removeValue(forKey: request)?.resume(returning: snapshot)
    }
}

struct WilcockSessionLifecycleTests {
    @Test
    func chartSnapshotsPreserveMissingCoordinatesAsGapsAndRejectNonFiniteNumbers() throws {
        var snapshot = wilcockSnapshot(.empty, resultMarker: "gap")
        snapshot.charts = [WilcockSourceChart(
            id: "state",
            section: .state,
            titleKey: "STATE",
            xAxisKey: "Grain Diameter",
            yAxisKey: "Transport CDF",
            series: [WilcockSourceSeries(
                caseIndex: nil,
                labelKey: "GSD1",
                colorARGB: "#FF000000",
                strokeWidth: 1,
                points: [WilcockChartPoint(x: 1, y: 0.5), WilcockChartPoint(x: nil, y: 0.75)]
            )]
        )]
        try snapshot.validate()

        snapshot.charts[0].series[0].points[1] = WilcockChartPoint(x: .infinity, y: 0.75)
        #expect(throws: (any Error).self) { try snapshot.validate() }
    }

    @Test @MainActor
    func rawEditDuringCalculationRejectsLateResponseAndRetainsCurrentDraftAndResults() async throws {
        var initialDraft = WilcockDraft.empty
        initialDraft.sbtm.shearVelocity = "0.25"
        let provider = DeferredWilcockProvider(initialSnapshot: wilcockSnapshot(initialDraft, resultMarker: "accepted"))
        let session = WilcockSession(provider: provider)
        #expect(await session.load())

        let calculation = Task { await session.calculate() }
        try await waitForWilcock { provider.evaluateRequests.count == 1 && session.isCalculating }
        let submitted = try #require(provider.evaluateRequests.first?.draft)
        #expect(submitted.sbtm.shearVelocity == "0.25")

        var edited = session.draft
        edited.sbtm.shearVelocity = "0,30 raw"
        session.editDraft(edited)
        #expect(session.draft.sbtm.shearVelocity == "0,30 raw")
        #expect(session.snapshot?.draft.sbtm.shearVelocity == "0,30 raw")
        #expect(session.isStale && !session.isCalculating)

        // This fake intentionally ignores task cancellation. The session's owner
        // generation, rather than provider cooperation, must reject the reply.
        provider.finishEvaluation(with: wilcockSnapshot(submitted, resultMarker: "late"))
        let acceptedLateCalculation = await calculation.value
        #expect(!acceptedLateCalculation)
        #expect(session.draft.sbtm.shearVelocity == "0,30 raw")
        #expect(session.snapshot?.draft.sbtm.shearVelocity == "0,30 raw")
        #expect(session.snapshot?.sbtmResults?["marker"] == .string("accepted"))
        #expect(session.isStale && !session.isBusy)
    }

    @Test @MainActor
    func invalidatingAnInFlightLoadPreventsLateSnapshotAndBusyStateFromReturning() async throws {
        let provider = DeferredWilcockProvider()
        let session = WilcockSession(provider: provider)
        let load = Task { await session.load(numberCulture: "en-US") }
        try await waitForWilcock { provider.loadRequests == 1 && session.isLoading }

        session.invalidate()
        #expect(session.snapshot == nil && !session.isBusy)
        provider.finishLoad(with: wilcockSnapshot(.empty, resultMarker: "late load"))

        let acceptedLateLoad = await load.value
        #expect(!acceptedLateLoad)
        #expect(session.snapshot == nil)
        #expect(!session.isLoading && !session.isCalculating && !session.isBusy)
    }

    @Test @MainActor
    func invalidatingAnInFlightCalculationPreventsLateSnapshotAndBusyStateFromReturning() async throws {
        let provider = DeferredWilcockProvider(initialSnapshot: wilcockSnapshot(.empty, resultMarker: "loaded"))
        let session = WilcockSession(provider: provider)
        #expect(await session.load())

        let calculation = Task { await session.calculate() }
        try await waitForWilcock { provider.evaluateRequests.count == 1 && session.isCalculating }
        let submitted = try #require(provider.evaluateRequests.first?.draft)
        session.invalidate()
        #expect(session.snapshot == nil && !session.isBusy)

        provider.finishEvaluation(with: wilcockSnapshot(submitted, resultMarker: "late calculation"))
        let acceptedLateCalculation = await calculation.value
        #expect(!acceptedLateCalculation)
        #expect(session.snapshot == nil)
        #expect(!session.isLoading && !session.isCalculating && !session.isBusy)
    }
}

@MainActor
private func waitForWilcock(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<200 {
        if condition() { return }
        await Task.yield()
    }
    throw WilcockLifecycleTestError.timedOut
}

private func wilcockSnapshot(_ draft: WilcockDraft, resultMarker: String) -> WilcockWorkspaceSnapshot {
    WilcockWorkspaceSnapshot(
        draft: draft,
        btmMode: draft.btmMode,
        cases: [],
        selectedCaseID: nil,
        selectedPlotIndex: 0,
        canAddCase: false,
        canRemoveSelectedCase: false,
        canImportCase: false,
        btmImportPolicy: .unavailable,
        importConfirmationRequired: false,
        btmImportReasonKey: nil,
        replacedExistingCases: false,
        sbtmResults: ["marker": .string(resultMarker)],
        isbtmResults: nil,
        stabResults: nil,
        stateResults: nil,
        tables: [],
        charts: [],
        inputIssues: [],
        sbtmErrorKey: nil,
        isbtmErrorKey: nil,
        stabErrorKey: nil,
        stateErrorKey: nil
    )
}

private enum WilcockLifecycleTestError: Error {
    case timedOut
}
