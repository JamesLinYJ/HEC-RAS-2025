import Foundation
import RASWorkspaceCore

/// NewProjectDataVM.ValidateProjectAllowed accepts an existing empty folder.
/// Hidden files count as content, just as Directory.GetFiles/GetDirectories do.
enum ProjectCreationDestination {
    static func validate(_ directory: URL, fileManager: FileManager = .default) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) else { return }
        guard isDirectory.boolValue,
              try fileManager.contentsOfDirectory(atPath: directory.path).isEmpty else {
            throw ProjectFileError.invalid("A project folder with this name is not empty.")
        }
    }
}
