import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class DeferredProjectionProvider: ProjectionProvider {
    var evaluations: [(ProjectionDefinitionDraft, CheckedContinuation<ProjectionEvaluation, any Error>)] = []
    var searches: [(ProjectionSearchQuery, CheckedContinuation<[ProjectionMatch], any Error>)] = []
    func evaluate(_ definition: ProjectionDefinitionDraft) async throws -> ProjectionEvaluation {
        try await withCheckedThrowingContinuation { evaluations.append((definition, $0)) }
    }
    func search(_ query: ProjectionSearchQuery) async throws -> [ProjectionMatch] {
        try await withCheckedThrowingContinuation { searches.append((query, $0)) }
    }
}
private actor DeferredRecentPreviewProvider: RecentProjectPreviewProvider {
    private var pending: [String: CheckedContinuation<RecentProjectPreview, any Error>] = [:]
    func preview(_ url: URL) async throws -> RecentProjectPreview {
        try await withCheckedThrowingContinuation { pending[url.path] = $0 }
    }
    func started(_ url: URL) -> Bool { pending[url.path] != nil }
    func finish(_ url: URL) {
        pending.removeValue(forKey: url.path)?.resume(returning: .init(projectURL: url, modified: nil, description: "old response", projection: .init(type: "Local", value: "SI"), counts: [], thumbnail: nil, warning: nil))
    }
}

struct ProjectBrowserProjectionTests {
    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(1)) }
        #expect(condition())
    }
    private func valid(_ code: Int) -> ProjectionEvaluation {
        .init(isValid: true, name: "source CRS", units: "SI", unitName: "Meters", epsgCode: code, utmZone: nil, wkt: "source WKT", error: nil, normalizedType: "EPSG", normalizedValue: String(code))
    }
    @Test @MainActor func lateProjectionEvaluationCannotApproveChangedInputOrClosedSheets() async throws {
        let provider = DeferredProjectionProvider(), state = ProjectProjectionSession()
        let old = ProjectionDefinitionDraft(type: "EPSG", value: "32650"), current = ProjectionDefinitionDraft(type: "EPSG", value: "3857")
        let first = Task { await state.evaluate(old, provider: provider, debounce: .zero) }
        try await waitUntil { provider.evaluations.count == 1 }
        let second = Task { await state.evaluate(current, provider: provider, debounce: .zero) }
        try await waitUntil { provider.evaluations.count == 2 }
        provider.evaluations[0].1.resume(returning: valid(32650)); await first.value
        #expect(state.accepted(old) == nil && state.accepted(current) == nil)
        provider.evaluations[1].1.resume(returning: valid(3857)); await second.value
        #expect(state.accepted(current)?.epsgCode == 3857 && state.accepted(old) == nil)
        #expect(state.accepted(.init(type: "EPSG", value: "4326")) == nil)
        let third = Task { await state.evaluate(old, provider: provider, debounce: .zero) }
        try await waitUntil { provider.evaluations.count == 3 }
        state.invalidate(); provider.evaluations[2].1.resume(returning: valid(32650)); await third.value
        #expect(state.evaluation == nil && !state.loading)
    }
    @Test @MainActor func invalidProjectionDoesNotReinstateAPreviousValidChoice() async throws {
        let provider = DeferredProjectionProvider(), state = ProjectProjectionSession(), definition = ProjectionDefinitionDraft(type: "EPSG", value: "4326")
        let task = Task { await state.evaluate(definition, provider: provider, debounce: .zero) }
        try await waitUntil { provider.evaluations.count == 1 }
        provider.evaluations[0].1.resume(returning: .init(isValid: false, name: "WGS 84", units: nil, unitName: nil, epsgCode: nil, utmZone: nil, wkt: nil, error: "Unprojected coordinate systems not supported (e.g. Lat/Long).", normalizedType: "EPSG", normalizedValue: "4326"))
        await task.value
        #expect(state.current(definition)?.isValid == false && state.accepted(definition) == nil)
        await state.evaluate(.init(type: "WKT", value: ""), provider: provider, debounce: .zero)
        #expect(state.evaluation == nil && provider.evaluations.count == 1)
    }
    @Test @MainActor func projectionSearchDropsEarlierQueriesAndRejectsInvalidSourceIdentities() async throws {
        let provider = DeferredProjectionProvider(), state = ProjectionSearchSession()
        let old = ProjectionSearchQuery(query: "old"), current = ProjectionSearchQuery(longitude: 116.4, latitude: 39.9)
        let first = Task { await state.search(old, provider: provider, debounce: .zero) }
        try await waitUntil { provider.searches.count == 1 }
        let second = Task { await state.search(current, provider: provider, debounce: .zero) }
        try await waitUntil { provider.searches.count == 2 }
        provider.searches[0].1.resume(returning: [.init(id: "EPSG:3857", name: "old", code: 3857, authority: "EPSG")]); await first.value
        #expect(state.results(for: current).isEmpty)
        provider.searches[1].1.resume(returning: [.init(id: "EPSG:32650", name: "UTM", code: 32650, authority: "EPSG")]); await second.value
        #expect(state.results(for: current).map(\.code) == [32650] && state.results(for: old).isEmpty)
        let third = Task { await state.search(old, provider: provider, debounce: .zero) }
        try await waitUntil { provider.searches.count == 3 }
        provider.searches[2].1.resume(returning: [.init(id: "area:32650", name: "wrong source identity", code: 32650, authority: "EPSG")]); await third.value
        #expect(state.matches.isEmpty && state.error != nil)
        await state.search(.init(longitude: 181, latitude: 0), provider: provider, debounce: .zero)
        #expect(state.error != nil && provider.searches.count == 3)
    }
    @Test @MainActor func legacyRecentHistoryPreservesUnknownOpenTimesAndDeduplicatesPaths() throws {
        let suite = "HECRAS2025RecentHistory-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["/fixture/工程.ras", "/fixture/../fixture/工程.ras", "/fixture/missing.ras"], forKey: "RecentProjects")
        let history = RecentProjectHistoryStore(defaults: defaults)
        let loaded = history.load()
        #expect(loaded.count == 2 && loaded.allSatisfy { $0.lastOpened == nil })
        var saved = loaded; saved[0].lastOpened = Date(timeIntervalSince1970: 1_700_000_000)
        history.save(saved)
        #expect(history.load().first?.lastOpened == saved[0].lastOpened)
        history.clear(); #expect(history.load().isEmpty)
    }
    @Test func recentGroupsUseSourceCalendarDaysAndLeaveUnknownDatesUnknown() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 12)))
        let file = URL(fileURLWithPath: "/fixture/project.ras")
        #expect(RecentProjectGroup.group(.init(url: file), now: now, calendar: calendar) == .unknown)
        for (days, expected) in [(0, RecentProjectGroup.today), (-1, .lastSevenDays), (-6, .lastSevenDays), (-7, .older), (-20, .older)] {
            let date = try #require(calendar.date(byAdding: .day, value: days, to: now))
            #expect(RecentProjectGroup.group(.init(url: file, lastOpened: date), now: now, calendar: calendar) == expected)
        }
    }
    @Test func filesystemPreviewsReadSourceCountsAndThumbnailsWithoutCreatingFolders() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = folder.appendingPathComponent("中文工程.ras")
        try Data("<Project><Description>预览文字</Description><Projection Type=\"Local\">SI</Projection></Project>".utf8).write(to: project)
        let plans = folder.appendingPathComponent("Plans"); try FileManager.default.createDirectory(at: plans, withIntermediateDirectories: true)
        try Data().write(to: plans.appendingPathComponent("one.h5")); try Data().write(to: plans.appendingPathComponent("metadata.txt"))
        try FileManager.default.createDirectory(at: plans.appendingPathComponent("subfolder"), withIntermediateDirectories: true)
        let thumbnail = Data([1, 2, 3]); try thumbnail.write(to: folder.appendingPathComponent("中文工程.thumbnail.png"))
        let result = try await FileSystemRecentProjectProvider().preview(project)
        #expect(result.description == "预览文字" && result.thumbnail == thumbnail && result.warning == nil)
        #expect(result.projection == .init(type: "Local", value: "SI"))
        #expect(result.counts.first { $0.section == .plans }?.count == 2)
        #expect(result.counts.first { $0.section == .geometries }?.count == 0)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("Geometries").path))
    }
    @Test @MainActor func removedRecentProjectsCannotReappearFromLatePreviewReplies() async throws {
        let provider = DeferredRecentPreviewProvider(), state = RecentProjectsSession(), url = URL(fileURLWithPath: "/fixture/removed.ras")
        let pending = Task { await state.load([.init(url: url)], provider: provider) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await provider.started(url)), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(await provider.started(url))
        await state.load([], provider: provider); await provider.finish(url); await pending.value
        #expect(state.previews.isEmpty && state.errors.isEmpty && state.loading.isEmpty)
    }
    @Test @MainActor func removingARecentRecordPreservesTheProjectFiles() throws {
        let suite = "HECRAS2025RecentRemoval-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = RecentProjectHistoryStore(defaults: defaults), store = WorkspaceStore(recentHistoryStore: history)
        store.createProject(name: "中文工程", units: "SI", description: "test", directory: directory, projectionType: "Local", projectionValue: "SI")
        let file = try #require(store.recentProjects.first)
        #expect(store.recentProjectHistory.first?.lastOpened != nil)
        store.removeRecentProject(file)
        #expect(store.recentProjects.isEmpty && history.load().isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"] != nil)) @MainActor
    func projectionSelectionUsesTheActualBundledSourceService() async throws {
        let executable = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"]))
        let provider = BackendProjectionProvider(client: BackendProcessClient(executableURL: executable))
        let evaluation = try await provider.evaluate(.init(type: "EPSG", value: "32650"))
        #expect(evaluation.isValid && evaluation.units == "SI" && evaluation.epsgCode == 32650 && evaluation.utmZone == 50)
        #expect(evaluation.normalizedDefinition == .init(type: "EPSG", value: "32650"))
        let geographic = try await provider.evaluate(.init(type: "EPSG", value: "4326"))
        #expect(!geographic.isValid)
        let matches = try await provider.search(.init(query: "32650"))
        #expect(matches.map(\.id) == ["EPSG:32650"] && matches.first?.name.contains("UTM zone 50N") == true)
        let location = try await provider.search(.init(longitude: 116.4, latitude: 39.9))
        #expect(!location.isEmpty && Set(location.map(\.id)).count == location.count)
    }
}
