import Foundation
import RASWorkspaceCore

private struct ProjectLibraryCatalogRequest: Encodable, Sendable {
    let debugMode: Bool
}

private struct ProjectLibraryWireRow: Decodable, Sendable {
    let id: String
    let title: String
    let description: String
    let publishDate: String?
    let tags: [String]
    let thumbnailUrl: URL?
    let kind: String

    var project: LibraryProject {
        LibraryProject(id: id, title: title, description: description,
            publishDate: Self.parseDate(publishDate), tags: tags, thumbnailURL: thumbnailUrl)
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }
}

private struct ProjectLibraryCatalogResponse: Decodable, Sendable {
    let examples: [ProjectLibraryWireRow]
    let synthetic: [ProjectLibraryWireRow]
}

private struct ProjectLibraryOpenRequest: Encodable, Sendable {
    let projectId: String
    let synthetic: Bool
    let debugMode: Bool
    let destinationDirectory: String
}

private struct ProjectLibraryOpenResponse: Decodable, Sendable {
    let projectPath: String
}

private enum BackendProjectLibraryError: LocalizedError {
    case requestAlreadyRunning
    case destinationUnavailable
    case invalidDestination
    case invalidProjectResponse

    var errorDescription: String? {
        switch self {
        case .requestAlreadyRunning: "A project library import is already running."
        case .destinationUnavailable: "Choose a folder to save the project."
        case .invalidDestination: "The selected project folder is no longer available."
        case .invalidProjectResponse: "The project library returned an invalid project location."
        }
    }
}

@MainActor
private final class ProjectLibraryProgressRelay {
    let jobID = UUID().uuidString
    let synthetic: Bool
    let receive: @MainActor (Job) -> Void

    init(synthetic: Bool, receive: @escaping @MainActor (Job) -> Void) {
        self.synthetic = synthetic
        self.receive = receive
    }

    func deliver(_ update: BackendProgressUpdate) {
        let progress = update.fraction.map { $0.isFinite ? min(max($0, 0), 1) * 100 : .nan } ?? .nan
        let name = update.taskName ?? L10n.text(synthetic ? "Creating Project" : "Downloading Project")
        receive(Job(id: jobID, name: name, progress: progress, message: update.message ?? "",
            isComplete: false, taskSucceeded: false, isCancelling: false, timeTaken: nil,
            isCancellable: false, showStatusMessage: true, canDelete: false))
    }
}

/// Calls the retained example catalog/importer and synthetic factory through
/// the bundled backend. The importer has no source cancellation control, so
/// its visible task is intentionally marked non-cancellable.
@MainActor
final class BackendProjectLibraryProvider: ProjectLibraryProvider {
    private let client: BackendProcessClient
    private let debugMode: Bool
    private let chooseDestinationFolder: @MainActor () -> URL?
    private var activeImportID: UUID?
    private var catalogCache: (loadedAt: Date, response: ProjectLibraryCatalogResponse)?
    private var catalogTask: (id: UUID, task: Task<ProjectLibraryCatalogResponse, any Error>)?
    var onImportRunningChanged: (@MainActor (Bool) -> Void)?

    init(client: BackendProcessClient? = nil, debugMode: Bool = false,
         chooseDestinationFolder: @escaping @MainActor () -> URL?) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
        self.debugMode = debugMode
        self.chooseDestinationFolder = chooseDestinationFolder
    }

    func examples() async throws -> [LibraryProject] {
        try await catalog().examples.map(\.project)
    }

    func syntheticProjects() async throws -> [LibraryProject] {
        guard debugMode else { return [] }
        return try await catalog().synthetic.map(\.project)
    }

    func openProject(_ project: LibraryProject, synthetic: Bool) async throws -> URL {
        try await openProject(project, synthetic: synthetic) { _ in }
    }

    func openProject(_ project: LibraryProject, synthetic: Bool,
                     progress: @escaping @MainActor (Job) -> Void) async throws -> URL {
        guard activeImportID == nil else { throw BackendProjectLibraryError.requestAlreadyRunning }
        let operationID = UUID()
        activeImportID = operationID
        onImportRunningChanged?(true)
        defer {
            if activeImportID == operationID {
                activeImportID = nil
                onImportRunningChanged?(false)
            }
        }
        if synthetic && !debugMode {
            throw BackendProjectLibraryError.invalidProjectResponse
        }
        guard let destination = chooseDestinationFolder() else {
            throw BackendProjectLibraryError.destinationUnavailable
        }
        let destinationRoot = destination.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard destinationRoot.isFileURL,
              FileManager.default.fileExists(atPath: destinationRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw BackendProjectLibraryError.invalidDestination }

        let request = ProjectLibraryOpenRequest(projectId: project.id, synthetic: synthetic,
            debugMode: debugMode, destinationDirectory: destinationRoot.path)
        let relay = ProjectLibraryProgressRelay(synthetic: synthetic, receive: progress)
        let response = try await client.request("projectLibrary.open", parameters: request,
            as: ProjectLibraryOpenResponse.self, reportsJob: true) { update in
                Task { @MainActor in relay.deliver(update) }
            }
        let projectURL = URL(fileURLWithPath: response.projectPath).standardizedFileURL.resolvingSymlinksInPath()
        let canonicalParent = projectURL.deletingLastPathComponent().resolvingSymlinksInPath()
        guard projectURL.isFileURL, projectURL.pathExtension.lowercased() == "ras",
              FileManager.default.fileExists(atPath: projectURL.path),
              canonicalParent.path != destinationRoot.path,
              canonicalParent.path.hasPrefix(destinationRoot.path.hasSuffix("/")
                  ? destinationRoot.path : destinationRoot.path + "/") else {
            throw BackendProjectLibraryError.invalidProjectResponse
        }
        return projectURL
    }

    private func catalog() async throws -> ProjectLibraryCatalogResponse {
        if let catalogCache, Date.now.timeIntervalSince(catalogCache.loadedAt) < 5 {
            return catalogCache.response
        }
        if let catalogTask { return try await catalogTask.task.value }

        let requestID = UUID()
        let task = Task {
            try await client.request("projectLibrary.catalog",
                parameters: ProjectLibraryCatalogRequest(debugMode: debugMode),
                as: ProjectLibraryCatalogResponse.self)
        }
        catalogTask = (requestID, task)
        do {
            let response = try await task.value
            if catalogTask?.id == requestID {
                catalogCache = (Date.now, response)
                catalogTask = nil
            }
            return response
        } catch {
            if catalogTask?.id == requestID { catalogTask = nil }
            throw error
        }
    }
}
