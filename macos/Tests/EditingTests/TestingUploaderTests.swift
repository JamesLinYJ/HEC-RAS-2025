import Foundation
import Testing
@testable import HECRAS2025

@MainActor
private final class TestingUploadFixture: TestingUploadProvider {
    var requests: [TestingUploadRequest] = []
    var fail = false
    var cancelCount = 0
    var result = TestingUploadOutcome(message: "Upload completed.", serverObjectID: "project:41", runQueued: false)
    let snapshot: TestingUploadSnapshot
    init(serverObjectID: String? = nil) {
        snapshot = TestingUploadSnapshot(sourceURL: URL(fileURLWithPath: "/task-fixture/project.ras"), suggestedName: "Task fixture",
            folder: "", description: "Original description", plans: [
                TestingPlanChoice(id: "valid", name: "Valid", geometry: "Geometry", boundaryCondition: "Boundary"),
                TestingPlanChoice(id: "missing", name: "Missing", geometry: nil, boundaryCondition: nil)
            ], selectedPlanIDs: [], geometries: [], selectedGeometryID: nil, serverObjectID: serverObjectID, existingNames: [], pointEditor: nil)
    }
    func prepare(sourceURL: URL?, kind: ToolKind, geometryID: String?) async throws -> TestingUploadSnapshot { snapshot }
    func upload(_ request: TestingUploadRequest, progress: @escaping @MainActor (Double?, String) -> Void) async throws -> TestingUploadOutcome {
        requests.append(request)
        if fail { throw CocoaError(.fileWriteNoPermission) }
        return result
    }
    func cancelUpload() { cancelCount += 1 }
}

struct TestingUploaderTests {
    @Test @MainActor
    func missingAssociationsCannotBeExportedEvenWhenSelected() async throws {
        let provider = TestingUploadFixture()
        let active = TestingUploadSession(provider: provider, kind: .testingProjectUpload)
        await active.prepare(sourceURL: nil)
        active.selectedPlans = ["valid", "missing", "unknown"]
        #expect(await active.upload())
        #expect(provider.requests.first?.planIDs == ["valid"])
    }
    @Test @MainActor
    func serverProjectWithoutPlansUsesPointOnlyRequest() async throws {
        let provider = TestingUploadFixture(serverObjectID: "source-server-id")
        let session = TestingUploadSession(provider: provider, kind: .testingProjectUpload)
        await session.prepare(sourceURL: nil)
        let point = InterestPoint(id: UUID(), serverID: 23, name: "Edited point", x: 1, y: 2)
        session.setPoints([point])
        #expect(session.pointsOnly)
        #expect(await session.upload())
        #expect(provider.requests.first?.serverObjectID == "source-server-id")
        #expect(provider.requests.first?.planIDs.isEmpty == true)
        #expect(provider.requests.first?.points.first?.serverID == 23)
    }
    @Test @MainActor
    func failedUploadRetainsMetadataAndChoices() async throws {
        let provider = TestingUploadFixture()
        provider.fail = true
        let session = TestingUploadSession(provider: provider, kind: .testingProjectUpload)
        await session.prepare(sourceURL: nil)
        session.name = "Edited name"; session.description = "Edited description"; session.selectedPlans = ["valid"]
        #expect(await session.upload() == false)
        #expect(session.name == "Edited name")
        #expect(session.description == "Edited description")
        #expect(session.selectedPlans == ["valid"])
        #expect(session.error != nil)
        #expect(!session.busy)
    }

    @Test @MainActor
    func uploadRunContinuationCarriesSelectedCommitTagAndIterationCount() async throws {
        let provider = TestingUploadFixture()
        provider.result = TestingUploadOutcome(message: "Queued Task fixture on commit abc123", serverObjectID: "project:41", runQueued: true)
        let session = TestingUploadSession(provider: provider, kind: .testingProjectUpload)
        await session.prepare(sourceURL: nil)
        session.selectedPlans = ["valid"]
        session.queueRunAfterUpload = true
        session.runCommit = "abc123"
        session.runTag = "nightly native"
        session.runIterations = 4

        #expect(await session.upload())
        #expect(provider.requests.first?.queueRunAfterUpload == true)
        #expect(provider.requests.first?.runCommit == "abc123")
        #expect(provider.requests.first?.runTag == "nightly native")
        #expect(provider.requests.first?.runIterations == 4)
        #expect(session.message == "Queued Task fixture on commit abc123")
        #expect(session.uploadCompleted)
    }

    @Test @MainActor
    func failedPostUploadRunContinuationDoesNotPretendTheUploadFailedOrTheRunQueued() async throws {
        let provider = TestingUploadFixture()
        provider.result = TestingUploadOutcome(message: "Upload completed; run queue status could not be confirmed.",
            serverObjectID: "project:41", runQueued: false, uploadCompleted: true,
            continuationError: "Upload completed, but the server could not read back the project.")
        let session = TestingUploadSession(provider: provider, kind: .testingProjectUpload)
        await session.prepare(sourceURL: nil)
        session.selectedPlans = ["valid"]
        session.queueRunAfterUpload = true
        session.runCommit = "abc123"

        #expect(await session.upload())
        #expect(session.uploadCompleted)
        #expect(session.message == "Upload completed; run queue status could not be confirmed.")
        #expect(session.error == "Upload completed, but the server could not read back the project.")
    }

    @Test @MainActor
    func invalidatingUploadSessionRequestsProviderCancellation() async throws {
        let provider = TestingUploadFixture()
        let session = TestingUploadSession(provider: provider, kind: .testingProjectUpload)
        session.invalidate()
        #expect(provider.cancelCount == 1)
        #expect(!session.busy)
    }
}
