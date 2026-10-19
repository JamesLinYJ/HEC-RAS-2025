import Foundation
import Testing
@testable import HECRAS2025

private struct SourceQueryFixtures: Decodable {
    struct Preset: Decodable { let id: String; let ql: String }
    struct Filter: Decodable { let comparison: OsmOperator; let key: String; let value: String; let ql: String }
    let presets: [Preset]
    let filters: [Filter]
    static func load() throws -> Self {
        let url = try #require(Bundle.module.url(forResource: "osm-query-source", withExtension: "json"))
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}
@MainActor
private final class DeferredFeatureQueryProvider: FeatureQueryProvider {
    private var completion: CheckedContinuation<FeatureQueryResult, any Error>?
    private var started: CheckedContinuation<Void, Never>?
    private var reporter: (@MainActor (FeatureQueryProgress) -> Void)?
    var savedFormat: String?
    func snapshot(_ context: FeatureQueryContext) async throws -> FeatureQuerySnapshot { .init(polygonSources: [], selectedPolygonID: nil) }
    func query(_ request: FeatureQueryRequest, progress: @escaping @MainActor (FeatureQueryProgress) -> Void) async throws -> FeatureQueryResult {
        reporter = progress
        return try await withCheckedThrowingContinuation { completion = $0; started?.resume(); started = nil }
    }
    func saveToDisk(_ resultID: String, formatID: String, context: FeatureQueryContext) async throws -> MapUpdate {
        savedFormat = formatID; throw CocoaError(.fileWriteNoPermission)
    }
    func suggest(key: String, value: String, isKey: Bool) async throws -> [String] { [] }
    func waitForStart() async { if completion == nil { await withCheckedContinuation { started = $0 } } }
    func finish() {
        reporter?(.init(info: "stale progress", percent: 90))
        completion?.resume(returning: .init(id: "fixture", hasFeatures: true, info: "fixture complete", layers: [])); completion = nil
    }
}

struct FeatureQueryTests {
    @Test @MainActor func allPresetAndOperatorTextsMatchOriginalRenamedCSharp() throws {
        let fixtures = try SourceQueryFixtures.load()
        #expect(fixtures.presets.count == 14)
        #expect(fixtures.filters.count == 7)
        for fixture in fixtures.presets {
            let preset = try #require(FeatureQueryOptions.source.osmPresets.first { $0.id == fixture.id })
            var draft = OSMQueryDraft(); draft.load(preset)
            #expect(draft.rawQL == fixture.ql)
        }
        for fixture in fixtures.filters {
            var draft = OSMQueryDraft()
            draft.editBuilder { $0.clauses = [.init(filters: [.init(key: fixture.key, comparison: fixture.comparison, value: fixture.value)])] }
            #expect(draft.rawQL == fixture.ql)
        }
    }
    @Test @MainActor func rawTextAndLabelEditsPreserveSourcePresetRules() throws {
        var draft = OSMQueryDraft()
        let first = draft.selectedPresetID
        draft.label = "本地名称"
        #expect(draft.selectedPresetID == first)
        draft.editQL("node[\"name\"=\"test\"]({{bbox}}); out;")
        #expect(draft.selectedPresetID == nil)
        #expect(draft.rawQL.contains("test"))
        draft.editBuilder { $0.clauses.removeAll() }
        #expect(draft.builderError != nil)
        #expect(draft.rawQL.hasPrefix("// "))
        draft.editBuilder { $0.clauses.append(.init()) }
        #expect(draft.builderError == L10n.text("A tag filter is missing its key."))
    }
    @Test @MainActor func cancelledQueryRejectsLateProgressAndResults() async throws {
        let provider = DeferredFeatureQueryProvider(), session = FeatureQuerySession()
        await session.load(context: .init(projectSessionID: UUID(), mapID: UUID(), kind: .nld), provider: provider)
        let task = try #require(session.query(extent: nil, provider: provider))
        await provider.waitForStart(); session.cancelQuery(); provider.finish(); await task.value
        #expect(session.result == nil)
        #expect(session.info == L10n.text("Query cancelled."))
        #expect(!session.busy)
        #expect(!session.canSave)
    }
    @Test @MainActor func failedSaveRetainsQueryResultsAndSelectedFormat() async throws {
        let provider = DeferredFeatureQueryProvider(), session = FeatureQuerySession()
        await session.load(context: .init(projectSessionID: UUID(), mapID: UUID(), kind: .nsi), provider: provider)
        session.useBoundaryPolygon = true
        #expect(!session.canQuery)
        session.useBoundaryPolygon = false
        let task = try #require(session.query(extent: nil, provider: provider))
        await provider.waitForStart(); provider.finish(); await task.value
        #expect(session.canSave)
        session.formatID = "GeoJson"
        #expect(await session.save(provider: provider) == nil)
        #expect(provider.savedFormat == "GeoJson")
        #expect(session.result?.id == "fixture")
        #expect(session.canSave)
        #expect(session.error != nil)
    }
}
