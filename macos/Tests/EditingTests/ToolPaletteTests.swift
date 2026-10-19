import Foundation
@testable import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class DeferredToolPaletteProvider: MapInteractionProvider {
    var calls: [(id: String, value: String, scope: String)] = []
    private var completion: CheckedContinuation<MapUpdate, any Error>?
    private var started: CheckedContinuation<Void, Never>?
    func handle(_ input: MapInput) async throws -> MapUpdate { empty }
    func undo() async throws -> MapUpdate { empty }
    func redo() async throws -> MapUpdate { empty }
    func toolPalette(_ context: ToolPaletteContext) async throws -> ToolPaletteSnapshot? {
        ToolPaletteSnapshot(nodes: [], optionScopeID: context.selectedLayerID ?? "map")
    }
    func changeToolOption(_ id: String, value: String, scopeID: String, context: ToolPaletteContext) async throws -> MapUpdate {
        calls.append((id, value, scopeID))
        return try await withCheckedThrowingContinuation { completion = $0; started?.resume(); started = nil }
    }
    func waitForStart() async { if completion == nil { await withCheckedContinuation { started = $0 } } }
    func finish() { let previous = completion; completion = nil; previous?.resume(returning: empty) }
    private var empty: MapUpdate { .init(vectors: nil, rasters: nil, preview: [], selectedLayerID: nil, selectedFeatureID: nil) }
}

struct ToolPaletteTests {
    @Test @MainActor
    func delayedMapPreviewStaysInOriginatingMapAfterFocusChanges() async throws {
        let provider = DeferredMapPreviewProvider()
        let workspace = WorkspaceStore(mapInteractionProvider: provider)
        let first = UUID(), second = UUID()
        workspace.activateMap(first)
        workspace.enqueueMapInput(.init(kind: .click, toolID: "Graph.Add", mapID: first, point: .init(x: 0, y: 0), screenX: 0, screenY: 0, modifiers: []))
        await provider.waitForStart()
        workspace.activateMap(second)
        provider.finish()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while workspace.mapState(for: first).preview.isEmpty && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(workspace.mapState(for: first).preview.count == 1)
        #expect(workspace.mapState(for: second).preview.isEmpty)
    }
    @Test @MainActor
    func rapidOptionEditsKeepSourceOrderAndSharedScope() async throws {
        let provider = DeferredToolPaletteProvider(), session = ToolPaletteSession()
        let option = try #require(ToolPaletteLibrary.shared.option("Arc.Smooth.Iterations"))
        let context = ToolPaletteContext(projectSessionID: UUID(), mapID: UUID(), selectedLayerID: "geometry-A")
        await session.load(provider: provider, context: context)
        #expect(session.set(option, raw: "3"))
        await provider.waitForStart()
        #expect(session.set(option, raw: "4"))
        #expect(provider.calls.count == 1)
        provider.finish()
        await Task.yield()
        await provider.waitForStart()
        #expect(provider.calls.map(\.value) == ["3", "4"])
        #expect(provider.calls.map(\.scope) == ["geometry-A", "geometry-A"])
        provider.finish()
        session.invalidate()
    }
    @Test @MainActor
    func replacedContextRejectsOldOptionCallbackAndDropsQueuedEdits() async throws {
        let provider = DeferredToolPaletteProvider(), session = ToolPaletteSession()
        let option = try #require(ToolPaletteLibrary.shared.option("Arc.Smooth.Iterations"))
        let context = ToolPaletteContext(projectSessionID: UUID(), mapID: UUID(), selectedLayerID: "old-geometry")
        var installed = 0
        session.didUpdate = { _, _ in installed += 1 }
        await session.load(provider: provider, context: context)
        session.set(option, raw: "5")
        await provider.waitForStart()
        session.set(option, raw: "6")
        session.invalidate(); provider.finish()
        await Task.yield()
        #expect(installed == 0)
        #expect(provider.calls.map(\.value) == ["5"])
        #expect(session.values.isEmpty)
    }
}

@MainActor
private final class DeferredMapPreviewProvider: MapInteractionProvider {
    private var completion: CheckedContinuation<MapUpdate, any Error>?
    private var started: CheckedContinuation<Void, Never>?
    func handle(_ input: MapInput) async throws -> MapUpdate {
        try await withCheckedThrowingContinuation { completion = $0; started?.resume(); started = nil }
    }
    func undo() async throws -> MapUpdate { .init(vectors: nil, rasters: nil, preview: [], selectedLayerID: nil, selectedFeatureID: nil) }
    func redo() async throws -> MapUpdate { try await undo() }
    func waitForStart() async { if completion == nil { await withCheckedContinuation { started = $0 } } }
    func finish() {
        let feature = MapFeature(id: 0, kind: .point, paths: [[MapPoint(x: 0, y: 0)]], attributes: [:])
        completion?.resume(returning: .init(vectors: nil, rasters: nil, preview: [feature], selectedLayerID: nil, selectedFeatureID: nil)); completion = nil
    }
}
