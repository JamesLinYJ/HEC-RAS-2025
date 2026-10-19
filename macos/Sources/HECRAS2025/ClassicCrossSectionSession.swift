import Combine
import Foundation
import RASWorkspaceCore

/// A shared lease lets a pinned profile outlive the source chooser window.
final class ClassicCrossSectionAccess: Sendable {
    let url: URL
    private let started: Bool
    init(url: URL) { self.url = url; started = url.startAccessingSecurityScopedResource() }
    deinit { if started { url.stopAccessingSecurityScopedResource() } }
}
struct ClassicCrossSectionSelection: Sendable {
    let profile: ClassicCrossSectionProfile
    let access: ClassicCrossSectionAccess
    let scopeID: UUID
}
struct ClassicCrossSectionWindowRoute: Hashable, Codable {
    let id: UUID
    let projectSessionID: UUID
}

@MainActor
final class ClassicCrossSectionWindows: ObservableObject {
    static let shared = ClassicCrossSectionWindows()
    @Published private(set) var sessions: [UUID: ClassicCrossSectionViewerSession] = [:]

    func open(projectSessionID: UUID, selection: ClassicCrossSectionSelection,
              provider: any ClassicCrossSectionProvider) -> ClassicCrossSectionWindowRoute {
        publish(projectSessionID: projectSessionID, selection: selection)
        if let existing = sessions.first(where: { $0.value.projectSessionID == projectSessionID && $0.value.isDynamicallyLinked }) {
            return .init(id: existing.key, projectSessionID: projectSessionID)
        }
        let id = UUID()
        sessions[id] = ClassicCrossSectionViewerSession(projectSessionID: projectSessionID,
            selection: selection, provider: provider)
        return .init(id: id, projectSessionID: projectSessionID)
    }
    func publish(projectSessionID: UUID, selection: ClassicCrossSectionSelection?) {
        for session in sessions.values where session.projectSessionID == projectSessionID {
            session.accept(selection)
        }
    }
    func invalidateChangedFile(projectSessionID: UUID, path: String, revision: String) {
        for session in sessions.values where session.projectSessionID == projectSessionID {
            if let profile = session.selection?.profile,
               profile.sourcePath == path, profile.sourceRevision != revision {
                session.invalidate("The cross-section source changed. Reload and select the section again.")
            }
        }
    }
    func invalidateFile(projectSessionID: UUID, path: String, message: String) {
        for session in sessions.values where session.projectSessionID == projectSessionID {
            if session.isDynamicallyLinked || session.selection?.profile.sourcePath == path {
                session.invalidate(message)
            }
        }
    }
    func close(_ id: UUID) { sessions.removeValue(forKey: id)?.cancel() }
    func closeProject(_ projectSessionID: UUID) {
        for session in sessions.values where session.projectSessionID == projectSessionID {
            session.invalidate("The project changed. Reopen this tool for the current project.")
        }
    }
}

@MainActor
final class ClassicCrossSectionViewerSession: ObservableObject {
    let projectSessionID: UUID
    @Published private(set) var selection: ClassicCrossSectionSelection?
    @Published private(set) var error: String?
    @Published private(set) var isLoading = false
    @Published var isDynamicallyLinked = true {
        didSet {
            guard isDynamicallyLinked != oldValue else { return }
            cancel()
            if isDynamicallyLinked { selection = latest; error = nil }
        }
    }
    private var latest: ClassicCrossSectionSelection?
    private let provider: any ClassicCrossSectionProvider
    private var loadTask: Task<Void, Never>?
    private var generation = 0

    init(projectSessionID: UUID, selection: ClassicCrossSectionSelection,
         provider: any ClassicCrossSectionProvider) {
        self.projectSessionID = projectSessionID; self.selection = selection
        latest = selection; self.provider = provider
    }
    func accept(_ value: ClassicCrossSectionSelection?) {
        latest = value
        guard isDynamicallyLinked else { return }
        cancel(); selection = value; error = nil
    }
    func reload() {
        guard let captured = selection else { return }
        cancel(); let current = generation; isLoading = true; error = nil
        loadTask = Task { [weak self, provider] in
            do {
                let p = captured.profile
                let updated = try await provider.profile(scopeID: captured.scopeID, source: captured.access.url,
                    revision: p.sourceRevision, contextToken: p.contextToken, row: p.row)
                guard let self, self.generation == current, !Task.isCancelled else { return }
                guard updated.contextToken == p.contextToken, updated.row == p.row,
                      updated.sourcePath == p.sourcePath, updated.sourceRevision == p.sourceRevision,
                      UUID(uuidString: updated.scopeID) == captured.scopeID else {
                    self.invalidate("The cross-section source returned an invalid selection or profile."); return
                }
                let next = ClassicCrossSectionSelection(profile: updated, access: captured.access, scopeID: captured.scopeID)
                self.selection = next
                // A pinned read refreshes only its captured row. The browser
                // may already have published a different linked selection.
                if self.latestMatches(captured) { self.latest = next }
                self.isLoading = false; self.loadTask = nil
            } catch {
                guard let self, self.generation == current, !Task.isCancelled else { return }
                self.selection = nil
                if self.latestMatches(captured) { self.latest = nil }
                self.error = L10n.text(error.localizedDescription)
                self.isLoading = false; self.loadTask = nil
            }
        }
    }
    func invalidate(_ message: String) {
        cancel(); selection = nil; latest = nil; error = L10n.text(message)
    }
    private func latestMatches(_ captured: ClassicCrossSectionSelection) -> Bool {
        guard let latest else { return false }
        return latest.scopeID == captured.scopeID
            && latest.profile.contextToken == captured.profile.contextToken
            && latest.profile.sourcePath == captured.profile.sourcePath
            && latest.profile.sourceRevision == captured.profile.sourceRevision
            && latest.profile.row == captured.profile.row
    }
    func cancel() { generation &+= 1; loadTask?.cancel(); loadTask = nil; isLoading = false }
}

@MainActor
final class ClassicCrossSectionBrowserSession: ObservableObject {
    let scopeID = UUID()
    let projectSessionID: UUID
    let provider: any ClassicCrossSectionProvider
    @Published private(set) var sourceURL: URL?
    @Published private(set) var rows: [ClassicCrossSectionRow] = []
    @Published private(set) var selectedOrdinal: Int?
    @Published private(set) var selection: ClassicCrossSectionSelection?
    @Published private(set) var isLoading = false
    @Published private(set) var isSelecting = false
    @Published private(set) var error: String?
    private var revision: String?
    private var sourcePath: String?
    private var contextToken: String?
    private var access: ClassicCrossSectionAccess?
    private let windows: ClassicCrossSectionWindows
    private var catalogTask: Task<Void, Never>?
    private var profileTask: Task<Void, Never>?
    private var generation = 0
    private var profileGeneration = 0

    init(provider: any ClassicCrossSectionProvider, projectSessionID: UUID,
         windows: ClassicCrossSectionWindows? = nil) {
        self.provider = provider; self.projectSessionID = projectSessionID
        self.windows = windows ?? .shared
    }
    func open(_ url: URL) {
        cancel(); let current = generation
        let lease = ClassicCrossSectionAccess(url: url)
        sourceURL = url; access = lease; rows = []; revision = nil; sourcePath = nil; contextToken = nil
        selectedOrdinal = nil; selection = nil; error = nil; isLoading = true
        windows.publish(projectSessionID: projectSessionID, selection: nil)
        catalogTask = Task { [weak self, provider, scopeID] in
            do {
                var loaded: [ClassicCrossSectionRow] = [], next = 0
                var sourceRevision: String?, token: String?, total: Int?, path: String?
                while true {
                    let page = try await provider.catalog(scopeID: scopeID, source: lease.url,
                        revision: sourceRevision, offset: next)
                    guard let self, self.generation == current, !Task.isCancelled else { return }
                    guard UUID(uuidString: page.scopeID) == scopeID, page.offset == next,
                          page.totalCount >= loaded.count, page.sourceRevision.count == 64,
                          page.contextToken.count == 64, page.rows.enumerated().allSatisfy({
                              $0.element.ordinal == next + $0.offset
                          }), sourceRevision == nil || sourceRevision == page.sourceRevision,
                          token == nil || token == page.contextToken,
                          total == nil || total == page.totalCount, path == nil || path == page.sourcePath else {
                        throw BackendServiceError(code: "protocolFailure", message: "The cross-section source returned an invalid selection or profile.")
                    }
                    sourceRevision = page.sourceRevision; token = page.contextToken
                    total = page.totalCount; path = page.sourcePath; loaded += page.rows
                    guard let offset = page.nextOffset else {
                        guard loaded.count == page.totalCount else { throw DataToolError.unavailable }
                        self.rows = loaded; self.revision = sourceRevision; self.contextToken = token; self.sourcePath = path
                        self.isLoading = false; self.catalogTask = nil
                        self.windows.invalidateChangedFile(projectSessionID: self.projectSessionID,
                            path: page.sourcePath, revision: page.sourceRevision)
                        if let first = loaded.first { self.select(first.ordinal) }
                        return
                    }
                    guard offset == loaded.count, offset > next, offset < page.totalCount else {
                        throw BackendServiceError(code: "protocolFailure", message: "The cross-section source returned an invalid selection or profile.")
                    }
                    next = offset
                }
            } catch {
                guard let self, self.generation == current, !Task.isCancelled else { return }
                self.error = L10n.text(error.localizedDescription); self.isLoading = false; self.catalogTask = nil
                self.windows.invalidateFile(projectSessionID: self.projectSessionID,
                    path: SourceFilePaths.canonical(lease.url), message: error.localizedDescription)
            }
        }
    }
    func select(_ ordinal: Int?) {
        profileGeneration &+= 1; profileTask?.cancel(); profileTask = nil
        selectedOrdinal = ordinal; selection = nil; error = nil; isSelecting = false
        windows.publish(projectSessionID: projectSessionID, selection: nil)
        guard !isLoading, let ordinal, let row = rows.first(where: { $0.ordinal == ordinal }),
              let revision, let sourcePath, let contextToken, let access else { return }
        let current = generation, request = profileGeneration; isSelecting = true
        profileTask = Task { [weak self, provider, scopeID] in
            do {
                let profile = try await provider.profile(scopeID: scopeID, source: access.url,
                    revision: revision, contextToken: contextToken, row: row)
                guard let self, self.generation == current, self.profileGeneration == request, !Task.isCancelled else { return }
                guard UUID(uuidString: profile.scopeID) == scopeID, profile.row == row,
                      profile.sourcePath == sourcePath, profile.sourceRevision == revision,
                      profile.contextToken == contextToken else {
                    throw BackendServiceError(code: "protocolFailure", message: "The cross-section source returned an invalid selection or profile.")
                }
                let selected = ClassicCrossSectionSelection(profile: profile, access: access, scopeID: scopeID)
                self.selection = selected; self.isSelecting = false; self.profileTask = nil
                self.windows.publish(projectSessionID: self.projectSessionID, selection: selected)
            } catch {
                guard let self, self.generation == current, self.profileGeneration == request, !Task.isCancelled else { return }
                self.error = L10n.text(error.localizedDescription); self.isSelecting = false; self.profileTask = nil
                self.windows.invalidateFile(projectSessionID: self.projectSessionID,
                    path: sourcePath, message: error.localizedDescription)
            }
        }
    }
    func windowRoute() -> ClassicCrossSectionWindowRoute? {
        guard let selection else { return nil }
        return windows.open(projectSessionID: projectSessionID, selection: selection, provider: provider)
    }
    func cancel() {
        generation &+= 1; profileGeneration &+= 1
        catalogTask?.cancel(); catalogTask = nil; profileTask?.cancel(); profileTask = nil
        isLoading = false; isSelecting = false
    }
    func reportFileSelectionError(_ failure: Error) {
        if let cocoa = failure as? CocoaError, cocoa.code == .userCancelled { return }
        error = L10n.text(failure.localizedDescription)
    }
    func invalidate() {
        cancel(); rows = []; selectedOrdinal = nil; selection = nil; access = nil
        sourcePath = nil; revision = nil; contextToken = nil
        windows.closeProject(projectSessionID)
        error = L10n.text("The project changed. Reopen this tool for the current project.")
    }
}
