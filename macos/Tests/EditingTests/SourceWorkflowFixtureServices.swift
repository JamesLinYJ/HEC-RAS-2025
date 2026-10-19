import Foundation
import RASWorkspaceCore
@testable import HECRAS2025

/// Only disposable source fixtures are moved here. Product macOS Trash
/// behavior is verified separately through the actual application window.
@MainActor
final class SourceWorkflowFixtureServices: WorkspaceSystemServices {
    let recoveryFolder: URL
    var failTrashCall: Int?
    private(set) var trashCalls = 0
    init(recoveryFolder: URL) { self.recoveryFolder = recoveryFolder }
    func trash(_ url: URL) throws {
        trashCalls += 1
        if trashCalls == failTrashCall { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.createDirectory(at: recoveryFolder, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: recoveryFolder.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent))
    }
    func chooseProject() -> URL? { nil }
    func chooseProjectDestination(name: String) -> URL? { nil }
    func chooseFolder(title: String) -> URL? { nil }
    func chooseVectorLayer() -> URL? { nil }
    func chooseConnectionFile() -> URL? { nil }
    func chooseInputFiles() -> [URL] { [] }
    func chooseImageFiles() -> [URL] { [] }
    func chooseProjectionFile() -> URL? { nil }
    func reveal(_ url: URL) {}
    func copy(_ text: String) {}
    func openWebsite(_ url: URL) {}
}
