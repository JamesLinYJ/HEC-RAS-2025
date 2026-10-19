import Foundation
import Testing
@testable import HECRAS2025

@MainActor
private final class DeferredDeveloperProvider: DeveloperProvider {
    private var completion: CheckedContinuation<DeveloperResult, any Error>?
    private var started: CheckedContinuation<Void, Never>?
    var progress: (@MainActor (Double?, String) -> Void)?
    func load() async throws -> DeveloperSnapshot { DeveloperSnapshot(authenticated: true, models: []) }
    func authenticate(key: String, secret: String) async throws -> DeveloperSnapshot { try await load() }
    func perform(_ operation: DeveloperOperation, progress: @escaping @MainActor (Double?, String) -> Void) async throws -> DeveloperResult {
        self.progress = progress
        return try await withCheckedThrowingContinuation { completion = $0; started?.resume(); started = nil }
    }
    func waitForStart() async {
        if completion != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish() {
        completion?.resume(returning: DeveloperResult(snapshot: nil, projectURL: URL(fileURLWithPath: "/task-fixture/old-project.ras"), clipboardText: "task fixture text", message: "Old operation completed")); completion = nil
    }
}

struct DeveloperSessionTests {
    @Test @MainActor
    func closedDeveloperPageRejectsOldOpenAndClipboardResult() async throws {
        let provider = DeferredDeveloperProvider()
        let active = DeveloperSession(provider: provider)
        await active.load()
        let operation = Task { await active.perform(.openModel(key: "task-fixture")) }
        await provider.waitForStart()
        active.invalidate()
        provider.progress?(90, "Old progress")
        provider.finish()
        #expect(await operation.value == nil)
        #expect(active.progress == nil)
        #expect(active.message.isEmpty)
        #expect(!active.busy)
        #expect(active.error == nil)
    }
    @Test @MainActor
    func unavailableDeveloperServiceCannotReportSuccess() async throws {
        let session = DeveloperSession(provider: nil)
        await session.load()
        #expect(session.snapshot == nil)
        #expect(await session.perform(.generateUploadURL(key: "task-fixture")) == nil)
        #expect(!session.busy)
    }
}
