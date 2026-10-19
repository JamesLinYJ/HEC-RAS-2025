import Foundation
import RASWorkspaceCore
import SwiftUI

struct RecentProjectRecord: Codable, Hashable, Identifiable, Sendable {
    let url: URL
    var lastOpened: Date?
    var id: String { url.standardizedFileURL.path }
    var name: String { url.deletingPathExtension().lastPathComponent }
    init(url: URL, lastOpened: Date? = nil) { self.url = url.standardizedFileURL; self.lastOpened = lastOpened }
}

// Last-access time is history data, never inferred from the file modification date.
@MainActor
final class RecentProjectHistoryStore {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func load() -> [RecentProjectRecord] {
        var records: [RecentProjectRecord] = []
        if let data = defaults.data(forKey: "RecentProjectHistory"), let saved = try? JSONDecoder().decode([RecentProjectRecord].self, from: data) {
            records = saved
        }
        let legacy = defaults.stringArray(forKey: "RecentProjects") ?? []
        records += legacy.map { RecentProjectRecord(url: URL(fileURLWithPath: $0)) }
        var seen: Set<String> = []
        return Array(records.filter { $0.url.isFileURL && seen.insert($0.id).inserted }.prefix(20)).map { record in
            var record = record
            if record.lastOpened?.timeIntervalSince1970.isFinite == false { record.lastOpened = nil }
            return record
        }
    }
    func save(_ records: [RecentProjectRecord]) {
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: "RecentProjectHistory") }
        defaults.set(records.map { $0.url.path }, forKey: "RecentProjects")
    }
    func clear() { defaults.removeObject(forKey: "RecentProjectHistory"); defaults.removeObject(forKey: "RecentProjects") }
}

enum RecentProjectGroup: String, CaseIterable, Identifiable {
    case today = "Today", lastSevenDays = "Last 7 Days", older = "Older", unknown = "Open time unavailable"
    var id: String { rawValue }
    static func group(_ record: RecentProjectRecord, now: Date, calendar: Calendar) -> Self {
        guard let date = record.lastOpened else { return .unknown }
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        let start = calendar.startOfDay(for: now)
        if let cutoff = calendar.date(byAdding: .day, value: -7, to: start), calendar.startOfDay(for: date) > cutoff { return .lastSevenDays }
        return .older
    }
}

struct ProjectFolderStatistic: Identifiable, Sendable {
    let section: ProjectSection
    let count: Int?
    var error: String? = nil
    var id: String { section.rawValue }
}
struct RecentProjectPreview: Sendable {
    let projectURL: URL
    let modified: Date?
    let description: String
    let projection: ProjectionDefinitionDraft?
    let counts: [ProjectFolderStatistic]
    let thumbnail: Data?
    let warning: String?
}
protocol RecentProjectPreviewProvider: Sendable {
    func preview(_ url: URL) async throws -> RecentProjectPreview
}
struct FileSystemRecentProjectProvider: RecentProjectPreviewProvider {
    @concurrent func preview(_ url: URL) async throws -> RecentProjectPreview {
        try Task.checkCancellation()
        let file = try url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
        guard file.isRegularFile == true else { throw CocoaError(.fileReadNoSuchFile) }
        var description = "", warning: String?
        var projection: ProjectionDefinitionDraft?
        do {
            let document = try ProjectDocument(contentsOf: url)
            description = document.description
            if !document.projectionType.isEmpty { projection = .init(type: document.projectionType, value: document.projectionValue) }
        } catch { warning = error.localizedDescription }
        let counts = try [ProjectSection.plans, .geometries, .results, .boundaryConditions, .terrains].map { section -> ProjectFolderStatistic in
            try Task.checkCancellation()
            let directory = url.deletingLastPathComponent().appendingPathComponent(section.rawValue, isDirectory: true)
            do {
                let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
                let count = try files.reduce(0) { count, child in count + ((try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? 0 : 1) }
                return .init(section: section, count: count)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return .init(section: section, count: 0) }
            catch { return .init(section: section, count: nil, error: error.localizedDescription) }
        }
        let imageURL = url.deletingPathExtension().appendingPathExtension("thumbnail.png")
        var thumbnail: Data?
        if let size = try? imageURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16 * 1024 * 1024 {
            thumbnail = try? Data(contentsOf: imageURL)
        }
        try Task.checkCancellation()
        return .init(projectURL: url, modified: file.contentModificationDate, description: description, projection: projection, counts: counts, thumbnail: thumbnail, warning: warning)
    }
}

@MainActor
final class RecentProjectsSession: ObservableObject {
    @Published private(set) var previews: [String: RecentProjectPreview] = [:]
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var loading: Set<String> = []
    private var revision = 0
    func load(_ records: [RecentProjectRecord], provider: any RecentProjectPreviewProvider = FileSystemRecentProjectProvider()) async {
        revision += 1; let requested = revision
        let ids = Set(records.map(\.id))
        previews = previews.filter { ids.contains($0.key) }; errors = [:]; loading = ids
        struct Reply: Sendable { let id: String; let preview: RecentProjectPreview?; let error: String? }
        await withTaskGroup(of: Reply.self) { group in
            for record in records {
                group.addTask {
                    do { return Reply(id: record.id, preview: try await provider.preview(record.url), error: nil) }
                    catch { return Reply(id: record.id, preview: nil, error: error is CancellationError ? nil : error.localizedDescription) }
                }
            }
            for await reply in group {
                guard !Task.isCancelled, requested == revision else { group.cancelAll(); break }
                loading.remove(reply.id)
                if let preview = reply.preview, preview.projectURL.standardizedFileURL.path == reply.id { previews[reply.id] = preview }
                else { previews[reply.id] = nil; errors[reply.id] = reply.error ?? L10n.text("Project preview unavailable") }
            }
        }
        if requested == revision { loading = [] }
    }
    func invalidate() { revision += 1; loading = [] }
}
