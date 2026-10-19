import RASWorkspaceCore
import AppKit
import SwiftUI

struct NewShapefileRoute: View {
    @ObservedObject var store: WorkspaceStore
    let mapID: UUID

    var body: some View {
        if let client = store.runtimeInfoClient,
           let context = try? store.captureNewShapefileContext(mapID: mapID) {
            NewShapefileView(store: store, context: context,
                provider: BackendNewShapefileProvider(client: client))
        } else {
            ContentUnavailableView(L10n.text("New Shapefile"), systemImage: "square.and.arrow.down",
                description: Text(L10n.text("Open a saved project and choose a saved map before creating a Shapefile.")))
                .frame(minWidth: 480, minHeight: 300)
        }
    }
}

struct NewShapefileView: View {
    @ObservedObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session: NewShapefileSession

    init(store: WorkspaceStore, context: NewShapefileMapContext,
         provider: any NewShapefileCreationProvider) {
        self.store = store
        _session = StateObject(wrappedValue: NewShapefileSession(context: context, provider: provider,
            isContextCurrent: {
                Self.isCurrent(context, in: store)
            }, importCreated: { receipt in
                guard Self.isCurrent(context, in: store),
                      receipt.projectSessionID.caseInsensitiveCompare(context.projectSessionID.uuidString) == .orderedSame,
                      receipt.mapID.caseInsensitiveCompare(context.mapID.uuidString) == .orderedSame,
                      let source = receipt.family.files.first(where: { $0.role == "source" }),
                      let sourceRevision = source.revision else {
                    throw BackendServiceError(code: "staleContext",
                        message: "The created Shapefile belongs to a project or map that is no longer open.")
                }
                let imported = await store.connectVectorSource(URL(fileURLWithPath: receipt.destinationPath),
                    for: context.mapID, expectedShapefileFamily: receipt.family,
                    expectedSourceRevision: sourceRevision)
                guard imported else {
                    throw BackendServiceError(code: "mapImportFailed",
                        message: "The Shapefile was created, but could not be added to the selected map. Its files are preserved.")
                }
            }))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent(L10n.text("Project"), value: session.context.projectPath.path)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    LabeledContent(L10n.text("Map"), value: mapSummary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)

                    TextField(L10n.text("File name"), text: $session.filename)
                        .disabled(session.isBusy || session.createdReceipt != nil)

                    Picker(L10n.text("Geometry type"), selection: $session.geometryType) {
                        Text(L10n.text("Point")).tag(NewShapefileGeometryType.point)
                        Text(L10n.text("Polyline")).tag(NewShapefileGeometryType.polyline)
                        Text(L10n.text("Polygon")).tag(NewShapefileGeometryType.polygon)
                    }
                    .pickerStyle(.segmented)
                    .disabled(session.isBusy || session.createdReceipt != nil)

                    Picker(L10n.text("Projection"), selection: $session.projectionChoice) {
                        Text(L10n.text("Use project projection"))
                            .tag(NewShapefileProjectionChoice.project)
                            .disabled(session.context.isLocalProject)
                        Text(L10n.text("Local project coordinates"))
                            .tag(NewShapefileProjectionChoice.local)
                            .disabled(!session.context.isLocalProject)
                    }
                    .disabled(session.isBusy || session.createdReceipt != nil)

                    LabeledContent(L10n.text("Project projection"), value: session.context.projectionSummary)
                        .textSelection(.enabled)

                    LabeledContent(L10n.text("Destination")) {
                        HStack {
                            Text(session.destinationDirectory.path)
                                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            Button(L10n.text("Choose folder…"), action: chooseDestinationDirectory)
                                .disabled(session.isBusy || session.createdReceipt != nil)
                        }
                    }

                    LabeledContent(L10n.text("Shapefile path"), value: session.destinationPath)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                } header: {
                    Text(L10n.text("Create an empty Shapefile and add it to the selected map."))
                }

                if let receipt = session.createdReceipt {
                    Section(L10n.text("Created Shapefile")) {
                        LabeledContent(L10n.text("Saved files"), value: receipt.destinationPath)
                            .lineLimit(2).textSelection(.enabled)
                        if session.didImport {
                            Label(L10n.text("Shapefile added to the selected map."), systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Text(L10n.text("The Shapefile is saved. Retry Import adds this same file without creating it again."))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }

                if let error = session.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            .padding()

            Divider()
            HStack {
                if session.isBusy { ProgressView().controlSize(.small) }
                Spacer()
                Button(session.createdReceipt == nil
                    ? L10n.text("Cancel") : L10n.text("Close and Keep Files")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(session.isBusy)
                Button(primaryActionTitle) {
                    Task {
                        if await session.createOrRetryImport() { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!(session.canCreate || session.canRetryImport) || !session.fileNameIsValid)
            }
            .padding()
        }
        .frame(minWidth: 620, minHeight: 480)
        .interactiveDismissDisabled(session.isBusy)
    }

    private var primaryActionTitle: String {
        if session.isBusy {
            return session.createdReceipt == nil
                ? L10n.text("Creating Shapefile…") : L10n.text("Importing Shapefile…")
        }
        return session.createdReceipt == nil
            ? L10n.text("Create and Add to Map") : L10n.text("Retry Import")
    }

    private var mapSummary: String {
        let name = session.context.map.mapName ?? L10n.text("Project map")
        let type = session.context.map.mapType ?? session.context.map.kind
        return name + " · " + L10n.text(type)
    }

    private func chooseDestinationDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.text("Choose folder")
        panel.message = L10n.text("Choose where the Shapefile files will be saved.")
        panel.directoryURL = Self.existingDirectory(near: session.destinationDirectory)
        guard panel.runModal() == .OK, let selected = panel.url,
              selected.hasDirectoryPath else { return }
        session.destinationDirectory = selected.standardizedFileURL
    }

    private static func isCurrent(_ context: NewShapefileMapContext, in store: WorkspaceStore) -> Bool {
        guard store.projectSessionID == context.projectSessionID,
              store.captureCoreLayerRequestContext() == context.map.coreLayerContext,
              store.document?.url?.standardizedFileURL == context.projectPath.standardizedFileURL,
              store.document?.sourceRevision?.caseInsensitiveCompare(context.projectRevision) == .orderedSame,
              store.document?.editorXML(overridingDescription: store.descriptionDraft) == context.map.projectXml,
              !store.isOpeningProject, !store.isRunningProjectTool, !store.isSavingAll, !store.isClosingTab else {
            return false
        }
        if let index = context.map.mapIndex {
            return store.catalogMapDocuments.contains {
                $0.id.caseInsensitiveCompare(context.mapID.uuidString) == .orderedSame
                    && $0.sourceIndex == index && $0.name == context.map.mapName
                    && $0.kind == context.map.mapType
            }
        }
        return context.mapID == MapState.projectMapID
            && !store.catalogMapDocuments.contains(where: { $0.sourceIndex != nil })
    }

    private static func existingDirectory(near directory: URL) -> URL? {
        var candidate = directory.standardizedFileURL
        while true {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent()
            guard parent != candidate else { return nil }
            candidate = parent
        }
    }
}
