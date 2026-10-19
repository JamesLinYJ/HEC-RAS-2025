import CryptoKit
import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

struct ClassicCrossSectionTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HECRAS_CROSS_SECTION_ACCEPTANCE_DIRECTORY"] != nil))
    func retainedClassicHDFPagesAndProfilesUseTheProductionHostWithoutWriting() async throws {
        let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["HECRAS_CROSS_SECTION_ACCEPTANCE_DIRECTORY"]))
        let executable = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["HECRAS_BACKEND_TEST_EXECUTABLE"]))
        let source = directory.appendingPathComponent("Classic profiles.h5")
        let before = try Data(contentsOf: source)
        let revision = SHA256.hash(data: before).map { String(format: "%02X", $0) }.joined()
        let provider = BackendClassicCrossSectionProvider(client: BackendProcessClient(executableURL: executable))
        let scope = UUID()
        let first = try await provider.catalog(scopeID: scope, source: source, revision: nil, offset: 0)
        #expect(first.totalCount == 260 && first.rows.count == 256 && first.nextOffset == 256)
        #expect(first.sourceRevision == revision)
        let last = try await provider.catalog(scopeID: scope, source: source, revision: revision, offset: 256)
        #expect(last.rows.count == 4 && last.nextOffset == nil && last.contextToken == first.contextToken)
        #expect(first.rows[0].nodeName == first.rows[1].nodeName)
        #expect(first.rows[0].rowToken != first.rows[1].rowToken)
        let profile = try await provider.profile(scopeID: scope, source: source, revision: revision,
            contextToken: first.contextToken, row: first.rows[0])
        #expect(profile.points.map(\.elevation) == [9, 4, 10])
        #expect(profile.banks.map(\.station) == [5, 15])
        #expect(profile.banks.map(\.elevation) == [6.5, 7])
        let empty = try await provider.profile(scopeID: scope, source: source, revision: revision,
            contextToken: first.contextToken, row: first.rows[2])
        #expect(empty.points.isEmpty && empty.banks.isEmpty)
        let gaps = try await provider.profile(scopeID: scope, source: source, revision: revision,
            contextToken: first.contextToken, row: first.rows[3])
        #expect(gaps.points.count == 3 && gaps.points[1].station == nil && gaps.points[2].elevation == nil)
        let emptyBanks = try await provider.profile(scopeID: scope, source: source, revision: revision,
            contextToken: first.contextToken, row: first.rows[4])
        #expect(emptyBanks.points.isEmpty && emptyBanks.hasProfile)
        #expect(emptyBanks.banks.map(\.station) == [5, 15])
        #expect(emptyBanks.banks.map(\.elevation) == [0, 0])
        do {
            _ = try await provider.profile(scopeID: UUID(), source: source, revision: revision,
                contextToken: first.contextToken, row: first.rows[0])
            Issue.record("A cross-project row token was accepted")
        } catch let error as BackendServiceError { #expect(error.code == "sourceChanged") }
        #expect(try Data(contentsOf: source) == before)

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Classic-stale-\(UUID()).h5")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try before.write(to: temporary)
        let original = try await provider.catalog(scopeID: scope, source: temporary, revision: nil, offset: 0)
        var changed = before; changed.append(0)
        try changed.write(to: temporary)
        do {
            _ = try await provider.profile(scopeID: scope, source: temporary, revision: revision,
                contextToken: original.contextToken, row: original.rows[0])
            Issue.record("A changed source was accepted for an old section selection")
        } catch let error as BackendServiceError { #expect(error.code == "sourceChanged") }
        #expect(try Data(contentsOf: source) == before)
    }

    @Test @MainActor
    func linkedWindowsFollowSelectionWhilePinnedWindowsKeepTheirExactRow() async throws {
        let provider = ControlledClassicSections()
        let windows = ClassicCrossSectionWindows(), project = UUID()
        let browser = ClassicCrossSectionBrowserSession(provider: provider, projectSessionID: project, windows: windows)
        browser.open(URL(fileURLWithPath: "/classic-fixture.h5"))
        try await wait { browser.selection?.profile.row.ordinal == 0 }
        let firstRoute = try #require(browser.windowRoute())
        #expect(browser.windowRoute() == firstRoute)
        let pinned = try #require(windows.sessions[firstRoute.id])
        pinned.isDynamicallyLinked = false
        browser.select(1)
        try await wait { browser.selection?.profile.row.ordinal == 1 }
        #expect(pinned.selection?.profile.row.ordinal == 0)
        let secondRoute = try #require(browser.windowRoute())
        #expect(firstRoute != secondRoute)
        let linked = try #require(windows.sessions[secondRoute.id])
        #expect(linked.selection?.profile.row.ordinal == 1)
        pinned.isDynamicallyLinked = true
        #expect(pinned.selection?.profile.row.ordinal == 1)
        browser.select(2)
        try await wait { linked.selection?.profile.row.ordinal == 2 }
        #expect(pinned.selection?.profile.row.ordinal == 2)
        browser.invalidate()
        #expect(browser.rows.isEmpty && browser.selection == nil)
        #expect(linked.selection == nil && linked.error != nil)
        #expect(pinned.selection == nil && pinned.error != nil)
        windows.close(firstRoute.id); windows.close(secondRoute.id)
        #expect(windows.sessions.isEmpty)
    }

    @Test @MainActor
    func lateProfileCannotReplaceANewerSelectionOrReviveACancelledBrowser() async throws {
        let provider = ControlledClassicSections()
        let browser = ClassicCrossSectionBrowserSession(provider: provider, projectSessionID: UUID(), windows: ClassicCrossSectionWindows())
        browser.open(URL(fileURLWithPath: "/classic-fixture.h5"))
        try await wait { browser.selection?.profile.row.ordinal == 0 }
        await provider.hold(1)
        browser.select(1)
        try await wait { await provider.hasPending }
        browser.select(2)
        try await wait { browser.selection?.profile.row.ordinal == 2 }
        await provider.release()
        try await Task.sleep(for: .milliseconds(30))
        #expect(browser.selection?.profile.row.ordinal == 2 && browser.error == nil)
        await provider.hold(1)
        browser.select(1)
        try await wait { await provider.hasPending }
        browser.cancel()
        await provider.release()
        try await Task.sleep(for: .milliseconds(30))
        #expect(browser.selection == nil && !browser.isSelecting && browser.error == nil)
        browser.invalidate()
    }

    @Test @MainActor
    func aProfileFromAnotherFileIsRejectedEvenWhenItsRowAndRevisionMatch() async throws {
        let provider = ControlledClassicSections()
        let windows = ClassicCrossSectionWindows()
        let browser = ClassicCrossSectionBrowserSession(provider: provider, projectSessionID: UUID(), windows: windows)
        browser.open(URL(fileURLWithPath: "/classic-fixture.h5"))
        try await wait { browser.selection?.profile.row.ordinal == 0 }
        let route = try #require(browser.windowRoute())
        let pinned = try #require(windows.sessions[route.id])
        pinned.isDynamicallyLinked = false
        await provider.returnWrongSource(for: 1)
        browser.select(1)
        try await wait { !browser.isSelecting }
        #expect(browser.selection == nil && browser.error != nil)
        #expect(pinned.selection == nil && pinned.error != nil)
        windows.close(route.id)
        browser.invalidate()
    }

    @Test @MainActor
    func sourceRevisionAndProjectChangesInvalidatePinnedWindowsAfterChooserDismissal() async throws {
        let provider = ControlledClassicSections(), windows = ClassicCrossSectionWindows(), project = UUID()
        let browser = ClassicCrossSectionBrowserSession(provider: provider, projectSessionID: project, windows: windows)
        let source = URL(fileURLWithPath: "/classic-fixture.h5")
        browser.open(source)
        try await wait { browser.selection?.profile.row.ordinal == 0 }
        let route = try #require(browser.windowRoute())
        let pinned = try #require(windows.sessions[route.id])
        pinned.isDynamicallyLinked = false
        browser.cancel()
        #expect(pinned.selection?.profile.sourceRevision == String(repeating: "A", count: 64))
        await provider.advanceRevision()
        browser.open(source)
        try await wait { browser.selection?.profile.sourceRevision == String(repeating: "B", count: 64) }
        #expect(pinned.selection == nil && pinned.error != nil)
        pinned.isDynamicallyLinked = true
        #expect(pinned.selection?.profile.sourceRevision == String(repeating: "B", count: 64))
        browser.cancel()
        windows.closeProject(project)
        #expect(pinned.selection == nil && pinned.error != nil)
        windows.close(route.id)
    }

    @Test @MainActor
    func aPinnedReloadCannotOverwriteTheNewLinkedSelection() async throws {
        let provider = ControlledClassicSections(), windows = ClassicCrossSectionWindows()
        let browser = ClassicCrossSectionBrowserSession(provider: provider, projectSessionID: UUID(), windows: windows)
        browser.open(URL(fileURLWithPath: "/classic-fixture.h5"))
        try await wait { browser.selection?.profile.row.ordinal == 0 }
        let route = try #require(browser.windowRoute())
        let viewer = try #require(windows.sessions[route.id])
        viewer.isDynamicallyLinked = false
        await provider.hold(0)
        viewer.reload()
        try await wait { await provider.hasPending }
        browser.select(1)
        try await wait { browser.selection?.profile.row.ordinal == 1 }
        viewer.isDynamicallyLinked = true
        #expect(viewer.selection?.profile.row.ordinal == 1)
        await provider.release()
        try await Task.sleep(for: .milliseconds(30))
        #expect(viewer.selection?.profile.row.ordinal == 1 && !viewer.isLoading)
        windows.close(route.id); browser.cancel()
    }

    @Test @MainActor
    func aCompletedPinnedReloadPreservesTheLatestBrowserSelectionForRelinking() async throws {
        let provider = ControlledClassicSections(), windows = ClassicCrossSectionWindows()
        let browser = ClassicCrossSectionBrowserSession(provider: provider, projectSessionID: UUID(), windows: windows)
        browser.open(URL(fileURLWithPath: "/classic-fixture.h5"))
        try await wait { browser.selection?.profile.row.ordinal == 0 }
        let route = try #require(browser.windowRoute())
        let viewer = try #require(windows.sessions[route.id])
        viewer.isDynamicallyLinked = false
        await provider.hold(0)
        viewer.reload()
        try await wait { await provider.hasPending }
        browser.select(1)
        try await wait { browser.selection?.profile.row.ordinal == 1 }
        await provider.release()
        try await wait { !viewer.isLoading }
        #expect(viewer.selection?.profile.row.ordinal == 0 && viewer.error == nil)
        viewer.isDynamicallyLinked = true
        #expect(viewer.selection?.profile.row.ordinal == 1)
        windows.close(route.id); browser.cancel()
    }

    @Test @MainActor
    func aFailedPinnedReloadPreservesAnIndependentLinkedSelection() async throws {
        let provider = ControlledClassicSections(), windows = ClassicCrossSectionWindows()
        let browser = ClassicCrossSectionBrowserSession(provider: provider, projectSessionID: UUID(), windows: windows)
        browser.open(URL(fileURLWithPath: "/classic-fixture.h5"))
        try await wait { browser.selection?.profile.row.ordinal == 0 }
        let route = try #require(browser.windowRoute())
        let viewer = try #require(windows.sessions[route.id])
        viewer.isDynamicallyLinked = false
        browser.select(1)
        try await wait { browser.selection?.profile.row.ordinal == 1 }
        await provider.rejectProfile(0)
        viewer.reload()
        try await wait { !viewer.isLoading }
        #expect(viewer.selection == nil && viewer.error != nil)
        viewer.isDynamicallyLinked = true
        #expect(viewer.selection?.profile.row.ordinal == 1 && viewer.error == nil)
        windows.close(route.id); browser.cancel()
    }

    @MainActor private func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let satisfied = await condition()
        try #require(satisfied)
    }
}

/// Deliberately ignores cancellation after suspending so stale response guards
/// are exercised independently of cooperative provider cancellation.
private actor ControlledClassicSections: ClassicCrossSectionProvider {
    private var revision = String(repeating: "A", count: 64)
    private var held: Int?
    private var pending: CheckedContinuation<ClassicCrossSectionProfile, Never>?
    private var pendingProfile: ClassicCrossSectionProfile?
    private var wrongSourceOrdinal: Int?
    private var rejectedOrdinal: Int?
    var hasPending: Bool { pending != nil }
    func hold(_ ordinal: Int) { held = ordinal }
    func returnWrongSource(for ordinal: Int) { wrongSourceOrdinal = ordinal }
    func rejectProfile(_ ordinal: Int) { rejectedOrdinal = ordinal }
    func advanceRevision() { revision = String(repeating: "B", count: 64) }
    func release() {
        let continuation = pending, value = pendingProfile
        pending = nil; pendingProfile = nil; held = nil
        if let value { continuation?.resume(returning: value) }
    }
    func catalog(scopeID: UUID, source: URL, revision: String?, offset: Int) async throws -> ClassicCrossSectionCatalog {
        let token = BackendClassicCrossSectionProvider.contextToken(scopeID: scopeID, path: source.path, revision: self.revision)
        return .init(scopeID: scopeID.uuidString, sourcePath: source.path, sourceRevision: self.revision,
            sourceName: "Classic fixture", contextToken: token, totalCount: 3, offset: offset, nextOffset: nil,
            rows: (offset..<3).map { row($0, token: token) })
    }
    func profile(scopeID: UUID, source: URL, revision: String, contextToken: String,
                 row: ClassicCrossSectionRow) async throws -> ClassicCrossSectionProfile {
        if rejectedOrdinal == row.ordinal {
            throw BackendServiceError(code: "sourceChanged", message: "The cross-section source changed. Reload and select the section again.")
        }
        let value = ClassicCrossSectionProfile(scopeID: scopeID.uuidString,
            sourcePath: wrongSourceOrdinal == row.ordinal ? "/another-classic-file.h5" : source.path,
            sourceRevision: revision, contextToken: contextToken, row: row, hasProfile: true,
            points: [.init(ordinal: 0, station: 0, elevation: Double(row.ordinal)),
                     .init(ordinal: 1, station: 10, elevation: Double(row.ordinal) + 1)], banks: [])
        if held == row.ordinal {
            pendingProfile = value
            return await withCheckedContinuation { pending = $0 }
        }
        return value
    }
    private func row(_ ordinal: Int, token: String) -> ClassicCrossSectionRow {
        .init(ordinal: ordinal, rowToken: BackendClassicCrossSectionProvider.rowToken(token, ordinal),
            nodeName: "Repeated name", riverName: "River", reachName: "Reach", riverStation: "10",
            profilePointCount: 2, usesOverride: true)
    }
}
