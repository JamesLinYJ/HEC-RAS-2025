import Foundation
import RASWorkspaceCore
import Testing
@testable import HECRAS2025

@MainActor
private final class DeveloperCredentialStoreProbe: WorkspaceS3CredentialStoring {
    var value: WorkspaceS3Credentials?
    private(set) var loadCount = 0
    private(set) var saveCount = 0
    private(set) var deleteCount = 0

    init(_ value: WorkspaceS3Credentials? = nil) { self.value = value }

    func load() -> WorkspaceS3Credentials? {
        loadCount += 1
        return value
    }

    func save(_ credentials: WorkspaceS3Credentials) throws {
        saveCount += 1
        value = credentials
    }

    func delete() throws {
        deleteCount += 1
        value = nil
    }
}

private final class DeveloperCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var countStorage = 0

    var count: Int { lock.withLock { countStorage } }

    func cancel() -> Bool {
        lock.withLock {
            countStorage += 1
            return true
        }
    }
}

struct WorkspaceDeveloperServicesTests {
    @Test @MainActor
    func missingMockCredentialsShortCircuitBeforeAnyNetworkOrBackendCall() async throws {
        let credentials = DeveloperCredentialStoreProbe()
        let unreachableExecutable = URL(fileURLWithPath: "/no-such-backend-for-credential-short-circuit")
        let provider = WorkspaceDeveloperProvider(credentials: credentials,
            jobs: WorkspaceJobRegistry(),
            backend: BackendProcessClient(executableURL: unreachableExecutable))

        let snapshot = try await provider.load()

        #expect(!snapshot.authenticated)
        #expect(snapshot.models.isEmpty)
        #expect(credentials.loadCount == 1)
        #expect(credentials.saveCount == 0)
        #expect(credentials.deleteCount == 0)
    }

    @Test @MainActor
    func inMemoryCredentialStoreRoundTripsAndClearsWithoutKeychainOrNetwork() throws {
        let credentials = WorkspaceSessionS3Credentials()
        #expect(credentials.load() == nil)

        try credentials.save(WorkspaceS3Credentials(accessKey: "test-access", secretKey: "test-secret"))
        #expect(credentials.load()?.accessKey == "test-access")
        #expect(credentials.load()?.secretKey == "test-secret")

        try credentials.delete()
        #expect(credentials.load() == nil)
        try credentials.delete()
        #expect(credentials.load() == nil)
    }

    @Test @MainActor
    func sourceJobCancellationUsesItsSourceControlAndRetainsCancelledTerminalState() async throws {
        let registry = WorkspaceJobRegistry()
        let cancellation = DeveloperCancellationProbe()
        let id = registry.beginSourceJob(name: "Archive upload", cancel: { cancellation.cancel() })

        #expect(registry.jobs.first(where: { $0.id == id })?.isCancellable == true)
        try await registry.cancel(id)
        #expect(cancellation.count == 1)
        #expect(registry.jobs.first(where: { $0.id == id })?.state == .cancelling)

        registry.finishSourceJob(id, succeeded: false, cancelled: true, message: "Cancelled by source.")
        let finished = registry.jobs.first(where: { $0.id == id })
        #expect(finished?.state == .cancelled)
        #expect(finished?.message == "Cancelled by source.")
        #expect(finished?.isCancellable == false)
    }

    @Test @MainActor
    func backendJobEventsKeepInvocationIdentityAndIgnoreSingleRequestCalls() {
        let registry = WorkspaceJobRegistry()
        registry.receive(BackendOperationEvent(invocationID: "one-shot", method: "catalog.read",
            phase: .started, isJob: false))
        #expect(registry.jobs.isEmpty)

        let id = "source-job-identity"
        registry.receive(BackendOperationEvent(invocationID: id, method: "terrain.download",
            phase: .started, isJob: true, cancellationCapability: .sourceControl,
            taskName: "Download terrain", requestSourceCancellation: { true }))
        registry.receive(BackendOperationEvent(invocationID: id, method: "terrain.download",
            phase: .progress, isJob: true, progress: 0.4, message: "Reading tile"))

        let running = registry.jobs.first(where: { $0.id == id })
        #expect(running?.progress == 40)
        #expect(running?.message == "Reading tile")
        #expect(running?.isCancellable == true)

        registry.receive(BackendOperationEvent(invocationID: id, method: "terrain.download",
            phase: .cancelled, isJob: true, message: "Source cancelled",
            sourceState: "cancelled", sourceCancelled: true))
        let terminal = registry.jobs.first(where: { $0.id == id })
        #expect(terminal?.state == .cancelled)
        #expect(terminal?.message == "Source cancelled")
        #expect(terminal?.isCancellable == false)
    }
}
