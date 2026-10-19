import AppKit
import Foundation

/// Opens a real interactive zsh session in the current project directory.
/// The retained Windows menu runs EnvironmentInit.bat; the native app has no
/// equivalent batch environment, so this starts the user's login shell and
/// does not claim to initialize HEC-RAS-specific environment variables.
@MainActor
enum WorkspaceCommandPrompt {
    static func open(projectURL: URL?) {
        do {
            let directory = try workingDirectory(for: projectURL)
            let scriptDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("hec-ras-command-prompt", isDirectory: true)
            try FileManager.default.createDirectory(at: scriptDirectory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let scriptURL = scriptDirectory.appendingPathComponent(UUID().uuidString + ".command")
            let script = "#!/bin/zsh\ncd -- \(shellLiteral(directory.path)) || exit 1\nexec /bin/zsh -il\n"
            try Data(script.utf8).write(to: scriptURL, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
            guard NSWorkspace.shared.open(scriptURL) else {
                try? FileManager.default.removeItem(at: scriptURL)
                throw CommandPromptError.couldNotOpen
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = L10n.text("Could not open a command prompt.")
            if let promptError = error as? CommandPromptError {
                alert.informativeText = L10n.text(promptError.messageKey)
            } else {
                alert.informativeText = error.localizedDescription
            }
            alert.addButton(withTitle: L10n.text("OK"))
            alert.runModal()
        }
    }

    private static func workingDirectory(for projectURL: URL?) throws -> URL {
        guard let projectURL else { return FileManager.default.homeDirectoryForCurrentUser }
        let directory = projectURL.standardizedFileURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CommandPromptError.projectFolderUnavailable
        }
        return directory
    }

    private static func shellLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private enum CommandPromptError: LocalizedError {
    case couldNotOpen
    case projectFolderUnavailable

    var messageKey: String {
        switch self {
        case .couldNotOpen: "Terminal could not be opened."
        case .projectFolderUnavailable: "The current project folder is not available."
        }
    }

    var errorDescription: String? {
        messageKey
    }
}
