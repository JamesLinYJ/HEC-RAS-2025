import Combine
import Foundation
import RASWorkspaceCore

struct ConnectionFileDraft: Identifiable, Equatable {
    let url: URL
    var name: String
    var id: String { url.standardizedFileURL.path }
    var effectiveName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? url.lastPathComponent : trimmed
    }
    static func valid(_ entries: [Self], existingNames: Set<String>) -> Bool {
        guard !entries.isEmpty else { return false }
        var names = existingNames
        return entries.allSatisfy { !$0.effectiveName.isEmpty && names.insert($0.effectiveName).inserted }
    }
}

struct ConnectionPreviewRequest: Hashable, Sendable {
    let projectID: UUID
    let connection: ProjectConnection
    let directory: URL
    let mappings: [PathMapping]
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.projectID == rhs.projectID && lhs.connection == rhs.connection && lhs.directory == rhs.directory
            && lhs.mappings.map { $0.sourceRoot + "\n" + $0.destination.path } == rhs.mappings.map { $0.sourceRoot + "\n" + $0.destination.path }
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(projectID); hasher.combine(connection); hasher.combine(directory)
        for mapping in mappings { hasher.combine(mapping.sourceRoot); hasher.combine(mapping.destination.path) }
    }
}
struct ConnectionFilePreview: Identifiable, Sendable {
    let url: URL
    let size: Int?
    let modified: Date?
    var id: String { url.standardizedFileURL.path }
}
struct ConnectionPreview: Sendable {
    let location: URL
    let files: [ConnectionFilePreview]
    let total: Int
}
protocol ConnectionPreviewProvider: Sendable {
    func preview(_ request: ConnectionPreviewRequest) async throws -> ConnectionPreview
}
struct FileSystemConnectionPreviewProvider: ConnectionPreviewProvider {
    @concurrent func preview(_ request: ConnectionPreviewRequest) async throws -> ConnectionPreview {
        try Task.checkCancellation()
        let location = try request.connection.resolve(relativeTo: request.directory, mappings: request.mappings)
        let files = try request.connection.files(relativeTo: request.directory, mappings: request.mappings)
        let values = try files.prefix(2000).map { url in
            try Task.checkCancellation()
            let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return ConnectionFilePreview(url: url, size: attributes.fileSize, modified: attributes.contentModificationDate)
        }
        return .init(location: location, files: values, total: files.count)
    }
}
@MainActor
final class ConnectionPreviewSession: ObservableObject {
    @Published private(set) var preview: ConnectionPreview?
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    private var revision = UUID()
    private var request: ConnectionPreviewRequest?
    func load(_ request: ConnectionPreviewRequest, provider: any ConnectionPreviewProvider = FileSystemConnectionPreviewProvider()) async {
        let revision = UUID(); self.revision = revision; self.request = request
        preview = nil; error = nil; busy = true
        defer { if self.revision == revision { busy = false } }
        do {
            let result = try await provider.preview(request)
            guard self.revision == revision, !Task.isCancelled else { return }
            preview = result
        } catch {
            guard self.revision == revision, !Task.isCancelled else { return }
            self.error = L10n.text(error.localizedDescription)
        }
    }
    func current(_ request: ConnectionPreviewRequest) -> ConnectionPreview? { self.request == request ? preview : nil }
    func accessCancelled() { invalidate(); error = L10n.text("Folder access was cancelled.") }
    func invalidate() { revision = UUID(); request = nil; busy = false; preview = nil; error = nil }
}
