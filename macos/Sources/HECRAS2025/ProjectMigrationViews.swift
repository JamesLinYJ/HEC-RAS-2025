import Foundation
import RASWorkspaceCore
import SwiftUI
import UniformTypeIdentifiers

/// Native front end for the retained v6-to-2025 project converter.
/// The workspace supplies its configured destination root and opens the
/// returned .ras URL through the existing project-document route.
struct ProjectMigrationDialog: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session: ProjectMigrationSession
    @State private var sourceURL: URL?
    @State private var authorizedSourceDirectory: URL?
    @State private var destinationDirectory: URL
    @State private var selectingSource = false
    @State private var selectingSourceDirectory = false
    @State private var selectingDestination = false

    private let onProjectOpened: @MainActor (URL) -> Void

    init(defaultDestinationDirectory: URL, sourceURL: URL? = nil,
         authorizedSourceDirectory: URL? = nil,
         onProjectOpened: @escaping @MainActor (URL) -> Void) {
        _session = StateObject(wrappedValue: ProjectMigrationSession())
        _sourceURL = State(initialValue: sourceURL)
        _authorizedSourceDirectory = State(initialValue: authorizedSourceDirectory)
        _destinationDirectory = State(initialValue: defaultDestinationDirectory)
        self.onProjectOpened = onProjectOpened
    }

    private var projectFileType: UTType { UTType(filenameExtension: "prj") ?? .plainText }
    private var canMigrate: Bool {
        guard session.inspection?.canExecute == true, let sourceURL else { return false }
        return sourceDirectory(for: sourceURL) != nil
    }
    private var progressTitle: String {
        guard let taskName = session.progressTaskName, taskName != "Task" else {
            return L10n.text("Converting the v6 project…")
        }
        return L10n.text(taskName)
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceDialogHeader(
                title: "Migrate V6 Project",
                subtitle: "Convert a HEC-RAS v6 project to HEC-RAS 2025.",
                symbol: "arrow.trianglehead.2.clockwise.rotate.90"
            )
            .padding(20)
            Divider()

            Form {
                Section("Source Project") {
                    HStack {
                        if let sourceURL {
                            Text(sourceURL.path)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        } else {
                            Text("Choose a HEC-RAS v6 .prj file.")
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button("Choose V6 Project…") { selectingSource = true }
                            .disabled(session.isMigrating)
                    }
                    if session.isInspecting {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Checking the v6 project…").foregroundStyle(.secondary)
                        }
                    }
                    if let sourceURL, sourceDirectory(for: sourceURL) == nil {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Authorize the project folder to read its sibling geometry, plan, and data files.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Choose Source Folder…") { selectingSourceDirectory = true }
                                .disabled(session.isMigrating)
                        }
                    }
                    if let inspection = session.inspection {
                        if inspection.canExecute {
                            LabeledContent("Project", value: inspection.projectName ?? sourceURL?.deletingPathExtension().lastPathComponent ?? "")
                        } else if let message = inspection.validationMessage {
                            migrationNotice(L10n.text(message), isError: true)
                        }
                    }
                }

                Section("Destination") {
                    HStack {
                        Text(destinationDirectory.path)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer(minLength: 8)
                        Button("Choose Folder…") { selectingDestination = true }
                            .disabled(session.isMigrating)
                    }
                    if let output = session.inspection?.destinationPath {
                        LabeledContent("New Project Folder", value: output)
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                    Text("The original v6 files are retained. A failed or cancelled conversion may leave a partial output folder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let message = session.errorMessage {
                    Section("Migration Status") { migrationNotice(message, isError: true) }
                }
                if session.isMigrating {
                    Section("Migration Status") {
                        HStack(spacing: 10) {
                            if let fraction = session.progressFraction {
                                ProgressView(value: fraction)
                                    .progressViewStyle(.linear)
                                    .frame(width: 150)
                                Text(fraction, format: .percent.precision(.fractionLength(0)))
                                    .monospacedDigit()
                            } else {
                                ProgressView()
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(session.cancellationRequested ? L10n.text("Cancelling migration…") : progressTitle)
                            }
                        }
                    }
                }
                if let result = session.result {
                    Section("Migration Complete") {
                        Label("Migration finished. Review the converter messages, then open the converted project.",
                              systemImage: "checkmark.circle.fill")
                        LabeledContent("Converted Project", value: result.projectPath)
                            .textSelection(.enabled)
                    }
                }
                if !session.logMessages.isEmpty {
                    Section("Conversion Log") {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(session.logMessages.enumerated()), id: \.offset) { entry in
                                    Text(entry.element)
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(8)
                        }
                        .frame(minHeight: 90, maxHeight: 180)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                    .disabled(session.isMigrating)
                Spacer()
                if session.isMigrating {
                    Button(L10n.text(session.cancellationRequested ? "Cancelling…" : "Cancel Migration")) {
                        session.cancelMigration()
                    }
                    .disabled(session.cancellationRequested)
                } else if let result = session.result {
                    Button("Open Converted Project") {
                        openMigratedProject(URL(fileURLWithPath: result.projectPath))
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Migrate Project") {
                        if let sourceURL, let sourceDirectory = sourceDirectory(for: sourceURL) {
                            session.execute(sourceDirectoryURL: sourceDirectory)
                        }
                    }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canMigrate)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(minWidth: 560, idealWidth: 650, minHeight: 430, idealHeight: 510)
        .fileImporter(isPresented: $selectingSource, allowedContentTypes: [projectFileType], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): sourceURL = urls.first
            case .failure(let error):
                if !(error is CancellationError) { session.reportSelectionError(error) }
            }
        }
        .fileImporter(isPresented: $selectingSourceDirectory, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first, let sourceURL,
                      sameLocation(url, sourceURL.deletingLastPathComponent()) else {
                    session.reportSelectionError(BackendServiceError(code: "invalidInput", message: "Choose the folder containing the selected .prj file."))
                    return
                }
                authorizedSourceDirectory = url
                inspectSelection()
            case .failure(let error):
                if !(error is CancellationError) { session.reportSelectionError(error) }
            }
        }
        .fileImporter(isPresented: $selectingDestination, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { destinationDirectory = url }
            case .failure(let error):
                if !(error is CancellationError) { session.reportSelectionError(error) }
            }
        }
        .onAppear { inspectSelection() }
        .onChange(of: sourceURL) { _, _ in inspectSelection() }
        .onChange(of: destinationDirectory) { _, _ in inspectSelection() }
        .onDisappear { session.cancelAll() }
        .interactiveDismissDisabled(session.isMigrating)
    }

    @ViewBuilder
    private func migrationNotice(_ message: String, isError: Bool) -> some View {
        Label(message, systemImage: isError ? "exclamationmark.triangle" : "info.circle")
            .foregroundStyle(isError ? Color.red : Color.secondary)
            .textSelection(.enabled)
    }

    private func inspectSelection() {
        guard let sourceURL, let sourceDirectory = sourceDirectory(for: sourceURL) else { session.clearInspection(); return }
        session.inspect(sourceURL: sourceURL, sourceDirectoryURL: sourceDirectory, destinationDirectory: destinationDirectory)
    }

    private func sourceDirectory(for source: URL) -> URL? {
        if let authorizedSourceDirectory,
           sameLocation(authorizedSourceDirectory, source.deletingLastPathComponent()) {
            return authorizedSourceDirectory
        }
        return nil
    }

    private func sameLocation(_ left: URL, _ right: URL) -> Bool {
        left.resolvingSymlinksInPath().standardizedFileURL.path == right.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func openMigratedProject(_ url: URL) {
        onProjectOpened(url)
        dismiss()
    }
}

@MainActor
private final class ProjectMigrationSession: ObservableObject {
    @Published private(set) var inspection: ProjectMigrationInspection?
    @Published private(set) var isInspecting = false
    @Published private(set) var isMigrating = false
    @Published private(set) var cancellationRequested = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var progressFraction: Double?
    @Published private(set) var progressTaskName: String?
    @Published private(set) var logMessages: [String] = []
    @Published private(set) var result: ProjectMigrationResult?

    private let client: BackendProcessClient
    private var inspectionTask: Task<Void, Never>?
    private var migrationTask: Task<Void, Never>?
    private var inspectionID = UUID()
    private var activeMigrationID: UUID?

    init(client: BackendProcessClient? = nil) {
        self.client = client ?? BackendProcessClient(
            executableURL: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Backend/HECRASBackend")
        )
    }

    func inspect(sourceURL: URL, sourceDirectoryURL: URL, destinationDirectory: URL) {
        guard !isMigrating else { return }
        inspectionTask?.cancel()
        inspectionID = UUID()
        let requestID = inspectionID
        inspection = nil
        errorMessage = nil
        result = nil
        progressFraction = nil
        progressTaskName = nil
        logMessages = []
        isInspecting = true
        inspectionTask = Task { @MainActor in
            let sourceScope = sourceDirectoryURL.startAccessingSecurityScopedResource()
            let destinationScope = destinationDirectory.startAccessingSecurityScopedResource()
            defer {
                if sourceScope { sourceDirectoryURL.stopAccessingSecurityScopedResource() }
                if destinationScope { destinationDirectory.stopAccessingSecurityScopedResource() }
            }
            do {
                let request = InspectRequest(sourcePath: sourceURL.path, destinationParentPath: destinationDirectory.path)
                let value = try await client.request("projectMigration.inspect", parameters: request, as: ProjectMigrationInspection.self)
                guard !Task.isCancelled, inspectionID == requestID else { return }
                inspection = value
            } catch {
                guard !Task.isCancelled, inspectionID == requestID else { return }
                errorMessage = L10n.text(error.localizedDescription)
            }
            if inspectionID == requestID { isInspecting = false }
        }
    }

    func execute(sourceDirectoryURL: URL) {
        guard let inspection, inspection.canExecute,
              let destinationPath = inspection.destinationPath,
              let revision = inspection.revision else { return }
        inspectionTask?.cancel()
        isMigrating = true
        cancellationRequested = false
        errorMessage = nil
        result = nil
        progressFraction = nil
        progressTaskName = nil
        logMessages = []
        let operationID = UUID()
        activeMigrationID = operationID
        let destinationURL = URL(fileURLWithPath: destinationPath, isDirectory: true)
        migrationTask = Task { @MainActor [self] in
            let sourceScope = sourceDirectoryURL.startAccessingSecurityScopedResource()
            let destinationParent = destinationURL.deletingLastPathComponent()
            let destinationScope = destinationParent.startAccessingSecurityScopedResource()
            defer {
                if sourceScope { sourceDirectoryURL.stopAccessingSecurityScopedResource() }
                if destinationScope { destinationParent.stopAccessingSecurityScopedResource() }
            }
            do {
                let request = MigrationRequest(sourcePath: inspection.sourcePath, destinationPath: destinationPath, revision: revision)
                let progressHandler: @Sendable (BackendProgressUpdate) -> Void = { [weak self] update in
                    Task { @MainActor [weak self] in
                        guard let self, self.activeMigrationID == operationID, !self.cancellationRequested else { return }
                        self.accept(update)
                    }
                }
                let result = try await client.request("projectMigration.execute", parameters: request,
                    as: ProjectMigrationResult.self, progress: progressHandler)
                guard activeMigrationID == operationID, !Task.isCancelled else { return }
                activeMigrationID = nil
                isMigrating = false
                migrationTask = nil
                logMessages = result.messages ?? logMessages
                self.result = result
            } catch is CancellationError {
                guard activeMigrationID == operationID else { return }
                activeMigrationID = nil
                errorMessage = L10n.text("Migration was cancelled. Partial output may remain at:") + "\n" + destinationPath
                isMigrating = false
                cancellationRequested = false
                migrationTask = nil
            } catch {
                guard activeMigrationID == operationID else { return }
                activeMigrationID = nil
                errorMessage = L10n.text(error.localizedDescription)
                isMigrating = false
                cancellationRequested = false
                migrationTask = nil
            }
        }
    }

    func cancelMigration() {
        guard isMigrating, !cancellationRequested else { return }
        cancellationRequested = true
        migrationTask?.cancel()
    }

    func cancelAll() {
        inspectionID = UUID()
        inspectionTask?.cancel()
        if isMigrating { activeMigrationID = nil; cancellationRequested = true }
        migrationTask?.cancel()
    }

    func clearInspection() {
        inspectionID = UUID()
        inspectionTask?.cancel()
        inspection = nil
        isInspecting = false
        errorMessage = nil
        result = nil
        progressFraction = nil
        progressTaskName = nil
        logMessages = []
    }

    func reportSelectionError(_ error: Error) { errorMessage = L10n.text(error.localizedDescription) }

    private func accept(_ update: BackendProgressUpdate) {
        progressTaskName = update.taskName
        if update.message == nil {
            if let fraction = update.fraction, (0...1).contains(fraction) {
                progressFraction = fraction
            } else {
                progressFraction = nil
            }
        }
        if let message = update.message, !message.isEmpty { logMessages.append(message) }
    }

    private struct InspectRequest: Encodable, Sendable {
        let sourcePath: String
        let destinationParentPath: String
    }

    private struct MigrationRequest: Encodable, Sendable {
        let sourcePath: String
        let destinationPath: String
        let revision: String
    }
}

private struct ProjectMigrationInspection: Decodable, Sendable {
    let canExecute: Bool
    let validationMessage: String?
    let sourcePath: String
    let projectName: String?
    let destinationPath: String?
    let revision: String?
}

private struct ProjectMigrationResult: Decodable, Sendable {
    let sourcePath: String
    let destinationPath: String
    let projectPath: String
    let projectName: String
    let messages: [String]?
}
