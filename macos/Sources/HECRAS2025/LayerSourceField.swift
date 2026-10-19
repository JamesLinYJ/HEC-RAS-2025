import SwiftUI

struct SourceCollection: Sendable {
    let items: [EditorChoice] // Display order supplied by the original adapter.
    let sourcePriorityReversed: Bool
    let canImport: Bool
    let canReorder: Bool
    let multipleImports: Bool
    var canRemove = false
    var importingJobs: [Job] = []
    var removableIDs: Set<String>? = nil
    var itemDetails: [String: SourceItemPresentation] = [:]
    var classificationTools: ClassificationToolsState? = nil
    var terrainConnected = false
    func canRemove(_ id: String) -> Bool { canRemove && (removableIDs?.contains(id) ?? true) }
    func sourceMove(fromDisplay: Int, toDisplay: Int) -> (from: Int, to: Int)? {
        guard items.indices.contains(fromDisplay), items.indices.contains(toDisplay), fromDisplay != toDisplay else { return nil }
        if sourcePriorityReversed { return (items.count - 1 - fromDisplay, items.count - 1 - toDisplay) }
        return (fromDisplay, toDisplay)
    }
}

// LayerSourceControl's list, priority operations, import and overview state.
struct LayerSourceField: View {
    let field: SourceEditorField
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    var fillsHeight = false
    var title: String? = nil
    var overviewTitle = "View All"
    private struct ImportRequest: Identifiable {
        enum Kind { case classification, terrain, terrainUSGS }
        let id = UUID()
        let kind: Kind
        let files: [URL]
        var hintExtent: ViewportRequest? = nil
    }
    private struct TerrainInputRemovalRequest: Identifiable {
        let id = UUID()
        let projectSessionID: UUID
        let session: ModelEditorSession
        let editorID: UUID
        let modelAssetID: String?
        let sourceRevision: String?
        let fieldID: String
        let itemID: String
        let itemTitle: String
    }
    @State private var importRequest: ImportRequest?
    @State private var terrainInputRemovalRequest: TerrainInputRemovalRequest?
    private var collection: SourceCollection? { session.sourceCollections[field.storageID] }
    private var items: [EditorChoice] { collection?.items ?? session.choiceOptions[field.storageID] ?? [] }
    private var selection: Binding<String?> {
        Binding(get: { session.fields[field.storageID].flatMap { $0.isEmpty ? nil : $0 } }, set: { id in Task { await session.perform(.selectSource(field: field.storageID, id: id)) } })
    }
    private var selectedIndex: Int? { items.firstIndex { $0.id == selection.wrappedValue } }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(LocalizedStringKey(title ?? field.title)).font(.headline)
                Spacer()
                ControlGroup {
                    Button { importFiles(store.system.chooseInputFiles()) } label: { Label("Import", systemImage: "plus") }
                        .disabled(!canMutate || collection?.canImport != true || session.terrainInputImportCleanupToken != nil)
                    if field.storageID == TerrainEditorContract.sourceField {
                        Menu {
                            ForEach(TerrainInputCreationKind.allCases) { kind in
                                Button(L10n.text(kind.title), systemImage: kind.symbol) { addTerrainInput(kind) }
                            }
                            Divider()
                            Button(L10n.text("USGS Terrain Products"), systemImage: "mountain.2.circle") {
                                importRequest = .init(kind: .terrainUSGS, files: [],
                                    hintExtent: store.activeMapState.currentExtent)
                            }
                        } label: { Label("Add Layer", systemImage: "square.stack.3d.up.badge.plus") }
                            .disabled(!canMutate || collection?.terrainConnected != true || session.terrainInputImportCleanupToken != nil)
                    }
                    Button { move(-1) } label: { Label("Move Up", systemImage: "arrow.up") }.disabled(!canMutate || collection?.canReorder != true || selectedIndex == nil || selectedIndex == 0)
                    Button { move(1) } label: { Label("Move Down", systemImage: "arrow.down") }.disabled(!canMutate || collection?.canReorder != true || selectedIndex == nil || selectedIndex == items.count - 1)
                    Button { selection.wrappedValue = nil } label: { Label(LocalizedStringKey(overviewTitle), systemImage: "eye") }
                }.labelStyle(.iconOnly)
            }
            SharedVisualDropTarget(
                canDropFolder: false,
                canDropMultipleItems: collection?.multipleImports ?? false,
                onFilesDropped: acceptDroppedFiles
            ) {
                List(items, selection: selection) { item in
                    HStack {
                        if let nameField = collection?.itemDetails[item.id]?.nameFieldID {
                            Image(systemName: "square.3.layers.3d").foregroundStyle(.secondary)
                            DoubleClickText(title: "Name", text: Binding(get: { session.fields[nameField] ?? item.title }, set: { session.set(nameField, $0) }), prompt: Text("Name"), suggestions: session.textSuggestions[nameField] ?? [], showsLabel: false)
                                .disabled(!canMutate)
                        } else {
                            Label(item.titleIsUserData == true ? item.title : L10n.text(item.title), systemImage: "square.3.layers.3d")
                        }
                        Spacer(minLength: 0)
                        if collection?.canRemove(item.id) == true {
                            Button(role: .destructive) {
                                if field.storageID == TerrainEditorContract.sourceField {
                                    terrainInputRemovalRequest = TerrainInputRemovalRequest(
                                        projectSessionID: store.projectSessionID,
                                        session: session,
                                        editorID: session.id,
                                        modelAssetID: session.modelAssetID,
                                        sourceRevision: session.sourceFileRevision,
                                        fieldID: field.storageID,
                                        itemID: item.id,
                                        itemTitle: item.title)
                                } else {
                                    Task { await session.perform(.removeSource(field: field.storageID, id: item.id)) }
                                }
                            } label: { Label("Remove", systemImage: "minus.circle") }.labelStyle(.iconOnly).buttonStyle(.borderless).disabled(!canMutate)
                        }
                    }.tag(item.id)
                        .draggable(item.id)
                        .dropDestination(for: String.self) { ids, _ in
                            guard canMutate, let collection, collection.canReorder,
                                  let from = items.firstIndex(where: { $0.id == ids.first }), let to = items.firstIndex(where: { $0.id == item.id }),
                                  let move = collection.sourceMove(fromDisplay: from, toDisplay: to) else { return false }
                            Task { await session.perform(.reorderSource(field: field.storageID, from: move.from, to: move.to)) }; return true
                        }
                        .contextMenu {
                            if field.storageID == TerrainEditorContract.sourceField,
                               let extent = collection?.itemDetails[item.id]?.terrainInfo?.validExtent,
                               let sourceRevision = session.sourceFileRevision {
                                Button("Zoom to Input Extent", systemImage: "scope") {
                                    let mapID = store.lastActiveMapID
                                    let mapIdentity = store.mapWorkflowIdentity(mapID)
                                    _ = store.zoomTerrainInputToMap(
                                        session: session,
                                        inputID: item.id,
                                        sourceRevision: sourceRevision,
                                        extent: extent,
                                        mapID: mapID,
                                        expectedProjectSessionID: store.projectSessionID,
                                        expectedMapIdentity: mapIdentity)
                                }
                                .disabled(!canMutate || !extent.isFiniteAndOrdered)
                            }
                            if let path = CatalogSourceContextRoutes.rasterTerrainEditorFilePath(
                                fieldID: field.storageID, itemID: item.id,
                                collection: session.sourceCollections[field.storageID]) {
                                Button("Open Containing Folder", systemImage: "folder") {
                                    guard CatalogSourceContextRoutes.rasterTerrainEditorFilePath(
                                            fieldID: field.storageID, itemID: item.id,
                                            collection: session.sourceCollections[field.storageID]) == path,
                                          FileManager.default.fileExists(atPath: path) else { return }
                                    store.system.reveal(URL(fileURLWithPath: path))
                                }
                                .disabled(!FileManager.default.fileExists(atPath: path))
                            }
                        }
                }.frame(minHeight: 100, maxHeight: fillsHeight ? .infinity : 210)
            }
            if items.isEmpty { Text("No source layers.").font(.caption).foregroundStyle(.secondary) }
            ImportingPreviewList(jobs: collection?.importingJobs ?? [])
            if field.storageID == TerrainEditorContract.sourceField,
               session.terrainInputImportCleanupWarning != nil {
                HStack(alignment: .top) {
                    let message = session.terrainInputImportCleanupAfterSave
                        ? "The model was saved, but temporary terrain import files could not be removed."
                        : "Temporary terrain import files could not be removed."
                    Label(L10n.text(message),
                        systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Spacer()
                    Button(L10n.text("Retry Cleanup")) { Task { await session.retryTerrainInputImportCleanup() } }
                        .disabled(session.isBusy || store.isSavingAll)
                }.font(.caption).padding(.top, 8)
            }
            if field.storageID == TerrainEditorContract.sourceField {
                TerrainUSGSCleanupStatus(cleanup: session.terrainUSGSImportCleanup, editor: session)
            }
        }.sheet(item: $importRequest) { request in
            switch request.kind {
            case .classification:
                ClassificationImportSheet(initialFiles: request.files, session: session, store: store)
            case .terrain:
                TerrainInputImportSheet(initialFiles: request.files, session: session, store: store)
            case .terrainUSGS:
                TerrainUSGSImportFlow(session: session, store: store, hintExtent: request.hintExtent)
            }
        }.confirmationDialog(terrainInputRemovalTitle,
            isPresented: Binding(
                get: { terrainInputRemovalRequest != nil },
                set: { if !$0 { terrainInputRemovalRequest = nil } }),
            titleVisibility: .visible) {
                Button("Remove", role: .destructive) { confirmTerrainInputRemoval() }
                Button("Cancel", role: .cancel) { terrainInputRemovalRequest = nil }
            }
    }
    private var terrainInputRemovalTitle: String {
        guard let request = terrainInputRemovalRequest else { return L10n.text("Remove Terrain Input") }
        return L10n.format("Trying to delete %@", request.itemTitle)
    }
    private func confirmTerrainInputRemoval() {
        defer { terrainInputRemovalRequest = nil }
        guard let request = terrainInputRemovalRequest,
              field.storageID == TerrainEditorContract.sourceField,
              request.projectSessionID == store.projectSessionID,
              request.editorID == request.session.id,
              request.session === session,
              request.session.modelAssetID == request.modelAssetID,
              request.session.sourceFileRevision == request.sourceRevision,
              store.editorSession(request.editorID) === request.session,
              request.fieldID == field.storageID,
              request.session.loaded, request.session.canEdit,
              !request.session.isBusy, !request.session.loadingSelection,
              !store.isSavingAll, !store.isOpeningProject,
              !store.isClosingTab, !store.isRunningProjectTool,
              let collection = request.session.sourceCollections[request.fieldID],
              collection.terrainConnected, collection.canRemove(request.itemID),
              collection.items.contains(where: { $0.id == request.itemID && $0.title == request.itemTitle }) else { return }
        let expectedProjectSessionID = request.projectSessionID
        let expectedEditorID = request.editorID
        let expectedSession = request.session
        let expectedModelAssetID = request.modelAssetID
        let expectedSourceRevision = request.sourceRevision
        let expectedFieldID = request.fieldID
        let expectedItemID = request.itemID
        let expectedTitle = request.itemTitle
        Task { @MainActor in
            guard store.projectSessionID == expectedProjectSessionID,
                  store.editorSession(expectedEditorID) === expectedSession,
                  session === expectedSession,
                  expectedSession.modelAssetID == expectedModelAssetID,
                  expectedSession.sourceFileRevision == expectedSourceRevision,
                  let current = expectedSession.sourceCollections[expectedFieldID],
                  current.terrainConnected, current.canRemove(expectedItemID),
                  current.items.contains(where: { $0.id == expectedItemID && $0.title == expectedTitle }),
                  expectedSession.loaded, expectedSession.canEdit,
                  !expectedSession.isBusy, !expectedSession.loadingSelection,
                  !store.isSavingAll, !store.isOpeningProject,
                  !store.isClosingTab, !store.isRunningProjectTool else { return }
            _ = await expectedSession.perform(.removeSource(field: expectedFieldID, id: expectedItemID))
        }
    }
    private var canMutate: Bool { session.canEdit && !session.isBusy && !session.loadingSelection && !store.isSavingAll }
    private func move(_ delta: Int) {
        guard canMutate, let collection, let from = selectedIndex, let move = collection.sourceMove(fromDisplay: from, toDisplay: from + delta) else { return }
        Task { await session.perform(.reorderSource(field: field.storageID, from: move.from, to: move.to)) }
    }
    private func importFiles(_ files: [URL]) {
        guard canMutate, let collection, collection.canImport, !files.isEmpty else { return }
        if field.storageID == ClassificationEditorContract.sourceField {
            importRequest = .init(kind: .classification, files: files); return
        }
        if field.storageID == TerrainEditorContract.sourceField {
            importRequest = .init(kind: .terrain, files: files); return
        }
        Task { await session.perform(.importSource(field: field.storageID, files: collection.multipleImports ? files : Array(files.prefix(1)))) }
    }

    private func acceptDroppedFiles(_ urls: [URL]) -> Bool {
        guard canMutate, let collection, collection.canImport,
              !urls.isEmpty, urls.allSatisfy(\.isFileURL),
              collection.multipleImports || urls.count == 1 else { return false }
        importFiles(urls)
        return true
    }
    private func addTerrainInput(_ kind: TerrainInputCreationKind) {
        guard canMutate, collection?.terrainConnected == true else { return }
        let hintExtent = store.activeMapState.currentExtent.flatMap { extent -> TerrainInputValidExtent? in
            guard TerrainExtent.isValid(extent) else { return nil }
            return TerrainInputValidExtent(minX: extent.lowerLeft.x, maxX: extent.upperRight.x,
                minY: extent.lowerLeft.y, maxY: extent.upperRight.y)
        }
        Task { _ = await session.perform(.addTerrainInput(kind, hintExtent: hintExtent)) }
    }
}
