import AppKit
import Darwin
import SwiftUI

private enum WorkspaceDirectoryFailure: Equatable, Sendable {
    case invalidFolderURL
    case pathIsFile
    case system(String)

    @MainActor
    var localizedMessage: String {
        switch self {
        case .invalidFolderURL: L10n.text("Choose a valid local folder.")
        case .pathIsFile: L10n.text("The selected path is a file, not a folder.")
        case .system(let message): message
        }
    }
}

struct WorkspaceDirectoryInspection: Equatable, Sendable {
    let isReady: Bool
    let createdDirectory: Bool
    private let failure: WorkspaceDirectoryFailure?

    static func inspect(_ directory: URL) -> Self {
        let url = directory.standardizedFileURL
        guard url.isFileURL, !url.path.isEmpty else {
            return .init(isReady: false, createdDirectory: false, failure: .invalidFolderURL)
        }

        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        let existed = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard !existed || isDirectory.boolValue else {
            return .init(isReady: false, createdDirectory: false, failure: .pathIsFile)
        }

        do {
            if !existed { try fileManager.createDirectory(at: url, withIntermediateDirectories: true) }
            let probe = url.appendingPathComponent(".hecras-write-check-\(UUID().uuidString)")
            defer { try? fileManager.removeItem(at: probe) }
            try Data().write(to: probe, options: .atomic)
            return .init(isReady: true, createdDirectory: !existed, failure: nil)
        } catch {
            return .init(isReady: false, createdDirectory: false, failure: .system(error.localizedDescription))
        }
    }

    @MainActor
    func message(successMessage: String) -> String {
        guard isReady else {
            return L10n.format("Could not access folder: %@", failure?.localizedMessage ?? L10n.text("Unknown file system error."))
        }
        return L10n.text(createdDirectory ? "Folder created and ready." : successMessage)
    }
}

struct WorkspaceDirectoryPreflightView: View {
    let directory: URL
    let successMessage: String
    @Binding var inspection: WorkspaceDirectoryInspection?

    var body: some View {
        Group {
            if let inspection {
                Label(inspection.message(successMessage: successMessage), systemImage: inspection.isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(inspection.isReady ? Color.secondary : Color.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                    .accessibilityLabel(inspection.message(successMessage: successMessage))
            } else {
                Label("Checking folder access…", systemImage: "clock")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
        }
        .task(id: directory.standardizedFileURL.path) {
            inspection = nil
            let result = await Task.detached(priority: .utility) {
                WorkspaceDirectoryInspection.inspect(directory)
            }.value
            guard !Task.isCancelled else { return }
            inspection = result
        }
    }
}

struct WorkspaceGISModeSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            WorkspaceDialogHeader(
                title: "GIS Mode",
                subtitle: "Use GIS features without storing a hydraulic model.",
                symbol: "globe.americas.fill"
            )
            WorkspaceDialogNotice(message: "GIS Mode is not connected to the native workspace yet.", isError: true)
            VStack(alignment: .leading, spacing: 8) {
                Label("Creates a scratch, in-memory project.", systemImage: "memorychip")
                Label("Uses Web Mercator (EPSG:900913).", systemImage: "location.north.line")
                Label("The source attempts to load its Liberty background map style.", systemImage: "map")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
            HStack {
                Spacer()
                Button("Start GIS Mode") {}
                    .disabled(true)
                    .help(L10n.text("GIS Mode has not been wired to the native workspace."))
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 500)
    }
}

struct WorkspaceEnvironmentNotices: View {
    var projectURL: URL? = nil

    private var warnings: [String] {
        var values: [String] = []
        if geteuid() == 0 {
            values.append("HEC-RAS is running as root. Files it creates may be owned by the system account.")
        }

        if let projectURL,
           let volume = try? projectURL.deletingLastPathComponent()
                .resourceValues(forKeys: [.volumeIsRemovableKey, .volumeIsLocalKey]),
           volume.volumeIsRemovable == true || volume.volumeIsLocal == false {
            values.append("This project is on a removable or network volume. Move it to a local drive for reliable access.")
        }
        return values
    }

    var body: some View {
        ForEach(warnings, id: \.self) { warning in
            WorkspaceDialogNotice(message: warning)
        }
    }
}
