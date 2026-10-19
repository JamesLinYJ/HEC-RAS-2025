import Foundation
import Testing
@testable import HECRAS2025

@MainActor
private final class DeferredTestingProvider: TestingProvider {
    let pointID = UUID()
    var ownerID: String?
    var actions: [TestingAction] = []
    private var completion: CheckedContinuation<TestingResult, any Error>?
    private var started: CheckedContinuation<Void, Never>?
    func snapshot(_ points: [InterestPoint]? = nil, pointOwnerID: String? = nil) -> TestingSnapshot {
        TestingSnapshot(objects: [], commits: [], points: points ?? [InterestPoint(id: pointID, serverID: 23, name: "Source point", x: 1, y: 2)], canEditPoints: true, vectors: [], status: "", log: [], pointOwnerID: pointOwnerID)
    }
    func load(projectURL: URL?) async throws -> TestingSnapshot { snapshot(pointOwnerID: ownerID) }
    func importPoints(_ shapefile: URL) async throws -> [InterestPoint] { [] }
    func perform(_ action: TestingAction) async throws -> TestingResult {
        actions.append(action)
        return try await withCheckedThrowingContinuation { completion = $0; started?.resume(); started = nil }
    }
    func waitForStart() async {
        if completion != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish(_ error: (any Error)? = nil) {
        if let error { completion?.resume(throwing: error) }
        else {
            let points: [InterestPoint]?
            switch actions.last {
            case .savePoints(let saved), .reconcilePoints(_, let saved): points = saved
            default: points = nil
            }
            completion?.resume(returning: TestingResult(snapshot: snapshot(points, pointOwnerID: ownerID), projectURL: nil))
        }
        completion = nil
    }
}

struct TestingWorkspaceTests {
    @Test @MainActor
    func pointEditsKeepOriginalServerIDAndReachSave() async throws {
        let provider = DeferredTestingProvider()
        let active = TestingSession(provider: provider)
        await active.load(projectURL: nil)
        active.editPoint(provider.pointID, name: "中文名称", x: 9)
        let saving = Task { await active.perform(.savePoints(active.points)) }
        await provider.waitForStart()
        if case .savePoints(let points) = provider.actions.first {
            #expect(points.first?.serverID == 23)
            #expect(points.first?.name == "中文名称")
            #expect(points.first?.x == 9)
        } else { Issue.record("Expected a point-save request") }
        provider.finish()
        #expect(await saving.value != nil)
        #expect(!active.pointsModified)
        #expect(active.points.first?.serverID == 23)
    }
    @Test @MainActor
    func unrelatedActionCannotReplaceModifiedPointDraft() async throws {
        let provider = DeferredTestingProvider()
        let active = TestingSession(provider: provider)
        await active.load(projectURL: nil); active.editPoint(provider.pointID, y: 7)
        #expect(await active.perform(.rename(id: "object", name: "new name")) == nil)
        #expect(provider.actions.isEmpty)
        #expect(active.points.first?.y == 7)
        #expect(active.pointsModified)
    }
    @Test @MainActor
    func failedPointSaveRetainsDraftAndIdentity() async throws {
        let provider = DeferredTestingProvider()
        let session = TestingSession(provider: provider)
        await session.load(projectURL: nil); session.editPoint(provider.pointID, x: 10)
        let saving = Task { await session.perform(.savePoints(session.points)) }
        await provider.waitForStart(); provider.finish(CocoaError(.fileWriteNoPermission))
        #expect(await saving.value == nil)
        #expect(session.pointsModified)
        #expect(session.points.first?.serverID == 23)
        #expect(session.points.first?.x == 10)
    }

    @Test @MainActor
    func remotePointSaveCarriesTheSelectedServerProjectIdentity() async throws {
        let provider = DeferredTestingProvider()
        provider.ownerID = "project:17"
        let active = TestingSession(provider: provider)
        await active.load(projectURL: nil)
        active.editPoint(provider.pointID, name: "Changed")
        let saving = Task { await active.perform(.savePoints(active.points)) }
        await provider.waitForStart()
        if case .reconcilePoints(let id, let points) = provider.actions.first {
            #expect(id == "project:17")
            #expect(points.first?.name == "Changed")
        } else { Issue.record("Expected a reconcile request with the owning project ID") }
        provider.finish()
        #expect(await saving.value != nil)
    }
}
