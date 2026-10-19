import Foundation
import Testing
@testable import HECRAS2025

@MainActor
private final class DeferredChatProvider: ChatProvider {
    private var completion: CheckedContinuation<ChatSnapshot, any Error>?
    private var started: CheckedContinuation<Void, Never>?
    func send(_ message: String, model: String, reasoning: String, serviceTier: String) async throws -> ChatSnapshot {
        try await withCheckedThrowingContinuation { completion = $0; started?.resume(); started = nil }
    }
    func clear() async throws {}
    func waitForStart() async {
        if completion != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish() {
        completion?.resume(returning: ChatSnapshot(entries: [ChatEntry(id: "reply", role: "assistant", message: "Task fixture reply")], developerFeed: [], tokenDisplayText: "")); completion = nil
    }
}

struct ChatEditingTests {
    @Test @MainActor
    func typingNextDraftDuringRequestDoesNotLoseItOnReply() async throws {
        let session = ChatSession(), provider = DeferredChatProvider()
        session.input = "first message"
        let sending = Task { await session.send(provider: provider) }
        await provider.waitForStart()
        session.input = "next 中文草稿"
        provider.finish(); await sending.value
        #expect(session.input == "next 中文草稿")
        #expect(session.entries.count == 1)
        #expect(!session.busy)
    }
    @Test @MainActor
    func replacedProjectRejectsOldChatReply() async throws {
        let session = ChatSession(), provider = DeferredChatProvider()
        session.input = "old project message"
        let sending = Task { await session.send(provider: provider) }
        await provider.waitForStart()
        session.invalidate(); provider.finish(); await sending.value
        #expect(session.entries.isEmpty)
        #expect(!session.busy)
        #expect(session.error == nil)
    }
    @Test @MainActor
    func closingChatTabRetainsCompositionForReopening() async throws {
        let store = WorkspaceStore()
        let session = store.chatSession
        session.input = "unsent 中文草稿"
        store.chatIsOpen = true; store.activeTab = .chat
        store.requestCloseActiveTab()
        #expect(!store.chatIsOpen)
        store.chatIsOpen = true; store.activeTab = .chat
        #expect(store.chatSession === session)
        #expect(store.chatSession.input == "unsent 中文草稿")
    }
}
