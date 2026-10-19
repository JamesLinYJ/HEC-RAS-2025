import Foundation
import Testing
@testable import HECRAS2025

private enum GlobalSymbologyFixtureError: Error { case requestDidNotStart }

@MainActor
private final class DeferredGlobalSymbologyProvider: VectorSymbologyProvider {
    private var completion: CheckedContinuation<MapUpdate, any Error>?
    var widths: [Double] = []
    var resetRequests: [Bool] = []
    var events: [String] = []
    private let style = VectorSymbologyStyle(penColor: "#FF000000", penWidth: 1, fillColor: "#800000FF", pointSize: 3, haloColor: "#00000000", haloThickness: 0, textEmphasis: 0)
    func snapshot(_ context: VectorSymbologyContext) async throws -> VectorSymbologySnapshot? {
        .init(options: [.init(id: "line", name: "Line", layerName: "Layer", type: .line, style: style, defaultStyle: style, columns: [], conditionsEnabled: false)], additionalOptions: [], canEdit: true)
    }
    func apply(options: [VectorStyleOption], additionalOptions: [VectorPlotOption], context: VectorSymbologyContext) async throws -> MapUpdate {
        widths.append(options[0].style.penWidth); resetRequests.append(options[0].resetRequested); events.append("apply")
        return try await withCheckedThrowingContinuation { completion = $0 }
    }
    func resetAllDefaults(context: VectorSymbologyContext) async throws -> VectorSymbologySnapshot {
        events.append("resetAll"); return try await snapshot(context)!
    }
    func waitForStart() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while completion == nil {
            guard ContinuousClock.now < deadline else { throw GlobalSymbologyFixtureError.requestDidNotStart }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    func finish(_ error: (any Error)? = nil) {
        let previous = completion; completion = nil
        if let error { previous?.resume(throwing: error) }
        else { previous?.resume(returning: .init(vectors: nil, rasters: nil, preview: [], selectedLayerID: nil, selectedFeatureID: nil)) }
    }
}

struct GlobalSymbologyTests {
    @Test @MainActor func rapidGlobalStyleChangesStayEditableAndKeepSourceOrder() async throws {
        let provider = DeferredGlobalSymbologyProvider(), session = VectorSymbologySession()
        await session.load(context: .init(projectSessionID: UUID(), mapID: UUID(), assetID: nil, scope: .global), provider: provider)
        session.edit("line") { $0.style.penWidth = 3 }; try await provider.waitForStart()
        session.edit("line") { $0.style.penWidth = 5 }
        #expect(session.options[0].style.penWidth == 5)
        #expect(provider.widths == [3])
        provider.finish(); await Task.yield(); try await provider.waitForStart()
        #expect(provider.widths == [3, 5])
        let closing = Task { await session.flushGlobalChanges() }
        provider.finish(); #expect(await closing.value)
        #expect(!session.hasPendingGlobalChanges)
    }
    @Test @MainActor func resetAllIsExplicitAndDoesNotRepeatOnLaterEdits() async throws {
        let provider = DeferredGlobalSymbologyProvider(), session = VectorSymbologySession()
        await session.load(context: .init(projectSessionID: UUID(), mapID: UUID(), assetID: nil, scope: .global), provider: provider)
        session.resetAllGlobalDefaults(); try await provider.waitForStart()
        #expect(provider.events == ["resetAll", "apply"])
        #expect(provider.resetRequests == [true])
        provider.finish(); #expect(await session.flushGlobalChanges())
        session.edit("line") { $0.style.penWidth = 2 }; try await provider.waitForStart()
        #expect(provider.resetRequests == [true, false])
        provider.finish(); #expect(await session.flushGlobalChanges())
    }
    @Test @MainActor func failedGlobalEditPreventsCloseAndRetainsLatestDraftForRetry() async throws {
        let provider = DeferredGlobalSymbologyProvider(), session = VectorSymbologySession()
        await session.load(context: .init(projectSessionID: UUID(), mapID: UUID(), assetID: nil, scope: .global), provider: provider)
        session.edit("line") { $0.style.penWidth = 7 }; try await provider.waitForStart()
        provider.finish(CocoaError(.fileWriteNoPermission))
        #expect(await session.flushGlobalChanges(retry: false) == false)
        // Failure retains the draft and retry request; close explicitly retries.
        let closing = Task { await session.flushGlobalChanges() }
        try await provider.waitForStart(); provider.finish(CocoaError(.fileWriteNoPermission))
        #expect(await closing.value == false)
        #expect(session.options[0].style.penWidth == 7)
        #expect(session.hasPendingGlobalChanges)
        #expect(session.error != nil)
    }
}
