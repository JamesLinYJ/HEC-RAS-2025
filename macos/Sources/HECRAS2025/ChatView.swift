import SwiftUI

struct ChatEntry: Identifiable, Sendable {
    let id: String
    let role: String
    let message: String
    var thinking: ThinkingMessage? = nil
    var developerDetails: DeveloperFeedMessage? = nil
    var display: ChatDisplayPayload? = nil
}
struct ChatSnapshot: Sendable {
    let entries: [ChatEntry]
    let developerFeed: [ChatEntry]
    let tokenDisplayText: String
    var displayObjects: [String: ChatDisplayObject] = [:]
}
@MainActor
protocol ChatProvider {
    func send(_ message: String, model: String, reasoning: String, serviceTier: String) async throws -> ChatSnapshot
    func clear() async throws
}

@MainActor
final class ChatSession: ObservableObject {
    @Published var input = "" { didSet { inputRevision += 1 } }
    @Published var model = "gpt-5"
    @Published var reasoning = "Minimal"
    @Published var tier = "default"
    @Published var tab = "Chat"
    @Published private(set) var entries: [ChatEntry] = []
    @Published private(set) var feed: [ChatEntry] = []
    @Published private(set) var tokenDisplay = ""
    @Published private(set) var displayObjects: [String: ChatDisplayObject] = [:]
    @Published private(set) var busy = false
    @Published var error: String?
    private var inputRevision = 0
    private var generation = 0
    private var request: Task<ChatSnapshot, any Error>?
    func send(provider: (any ChatProvider)?) async {
        guard let provider, !busy, !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let message = input, revision = inputRevision, captured = generation
        let model = model, reasoning = reasoning, tier = tier
        busy = true
        defer { if captured == generation { busy = false; request = nil } }
        let task = Task { try await provider.send(message, model: model, reasoning: reasoning, serviceTier: tier) }
        request = task
        do {
            let snapshot = try await task.value
            guard captured == generation, !Task.isCancelled else { return }
            entries = snapshot.entries; feed = snapshot.developerFeed; tokenDisplay = snapshot.tokenDisplayText
            displayObjects = snapshot.displayObjects
            if revision == inputRevision { input = "" }
        } catch { if captured == generation, !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func clear(provider: (any ChatProvider)?) async {
        guard !busy else { return }
        let captured = generation
        busy = true
        defer { if captured == generation { busy = false } }
        do {
            try await provider?.clear()
            guard captured == generation, !Task.isCancelled else { return }
            entries = []; feed = []; tokenDisplay = ""
            displayObjects = [:]
        } catch { if captured == generation, !Task.isCancelled { self.error = error.localizedDescription } }
    }
    func invalidate() { generation += 1; request?.cancel(); request = nil; busy = false }
}

// Port of RasChat: conversation, developer feed, model/reasoning/tier options,
// token display, log copy, and Return/Shift-Return input behavior. Transport is
// injected; constructing or opening this UI never sends a network request.
struct ChatView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject private var session: ChatSession
    init(store: WorkspaceStore) { self.store = store; session = store.chatSession }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Model", selection: $session.model) {
                    ForEach(["gpt-5", "gpt-5-mini", "gpt-5-nano"], id: \.self) { Text($0).tag($0) }
                }.frame(maxWidth: 220)
                Picker("Reasoning", selection: $session.reasoning) {
                    ForEach(["Minimal", "Low", "Medium", "High"], id: \.self) { Text(L10n.text($0)).tag($0) }
                }.frame(maxWidth: 160)
                Picker("Service Tier", selection: $session.tier) {
                    ForEach(["default", "flex", "priority"], id: \.self) { Text(L10n.text($0)).tag($0) }
                }.frame(maxWidth: 190)
                Spacer()
                Button("Clear Chat") { Task { await clear() } }.disabled(session.busy)
                Button("Copy Logs") { store.system.copy(session.feed.map { $0.role + ": " + $0.message }.joined(separator: "\n\n")) }
            }.padding(12)
            if store.chatProvider == nil {
                WorkspaceDialogNotice(message: "Chat is unavailable because no chat provider is configured.")
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
            Divider()
            Picker("View", selection: $session.tab) { Text("Chat").tag("Chat"); Text("Developer Feed").tag("Developer Feed") }
                .pickerStyle(.segmented).frame(width: 320).padding(10)
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(session.tab == "Chat" ? session.entries : session.feed) { entry in
                            VStack(alignment: .leading, spacing: 6) {
                                Label(L10n.text(entry.role), systemImage: entry.role == "user" ? "person.circle" : "bubble.left").font(.headline)
                                if let thinking = entry.thinking { ThinkingMessageView(message: thinking) }
                                if let details = entry.developerDetails { DeveloperFeedMessageView(message: details) }
                                if let display = entry.display {
                                    ChatDisplayView(payload: display, objects: session.displayObjects, store: store,
                                        onDock: store.isChatDisplayDocked(entry.id) ? nil : { store.dockChatDisplay(entryID: entry.id, payload: display, objects: session.displayObjects) })
                                }
                                if !entry.message.isEmpty { Text(entry.message).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                            }.id(entry.id)
                            Divider()
                        }
                    }.padding(18)
                }
                .onChange(of: session.entries.count) { _, _ in if let last = session.entries.last { scroll.scrollTo(last.id, anchor: .bottom) } }
                .onChange(of: session.feed.count) { _, _ in if session.tab == "Developer Feed", let last = session.feed.last { scroll.scrollTo(last.id, anchor: .bottom) } }
            }
            Divider()
            VStack(spacing: 8) {
                TextEditor(text: $session.input).frame(minHeight: 70, maxHeight: 140).accessibilityLabel("Message")
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) { return .ignored }
                        if !session.busy, store.chatProvider != nil, !session.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Task { await send() }; return .handled
                        }
                        return .ignored
                    }
                HStack {
                    Text(session.tokenDisplay).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if session.busy { ProgressView().controlSize(.small) }
                    Button("Send") { Task { await send() } }.buttonStyle(.borderedProminent)
                        .disabled(store.chatProvider == nil || session.busy || session.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(12)
        }
        .alert("HEC-RAS 2025", isPresented: Binding(get: { session.error != nil }, set: { if !$0 { session.error = nil } })) {
            Button("OK") { session.error = nil }
        } message: { Text(session.error ?? "") }
    }
    private func send() async { await session.send(provider: store.chatProvider) }
    private func clear() async { await session.clear(provider: store.chatProvider) }
}
