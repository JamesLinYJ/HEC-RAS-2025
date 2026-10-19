import Foundation
import RASWorkspaceCore

/// Launches that suppress application-data I/O keep explicitly entered
/// developer credentials only for the lifetime of this workspace.
@MainActor
final class WorkspaceSessionS3Credentials: WorkspaceS3CredentialStoring {
    private var credentials: WorkspaceS3Credentials?

    func load() -> WorkspaceS3Credentials? { credentials }
    func save(_ credentials: WorkspaceS3Credentials) throws { self.credentials = credentials }
    func delete() throws { credentials = nil }
}

@MainActor
final class WorkspaceTestingSettings {
    private let defaults: UserDefaults?
    private var sessionURL = BackendTestingProvider.sourceDefaultUtilityURL

    init(defaults: UserDefaults?) { self.defaults = defaults }

    var baseURL: String {
        defaults?.string(forKey: BackendTestingProvider.utilityURLDefaultsKey) ?? sessionURL
    }

    func setBaseURL(_ value: String) throws {
        let input = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = input.isEmpty ? BackendTestingProvider.sourceDefaultUtilityURL : input
        guard let url = URL(string: selected),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false, url.fragment == nil else {
            throw ProjectFileError.invalid(L10n.text("Enter a valid Testing Utility HTTP or HTTPS URL."))
        }
        sessionURL = selected
        defaults?.set(selected, forKey: BackendTestingProvider.utilityURLDefaultsKey)
    }
}
