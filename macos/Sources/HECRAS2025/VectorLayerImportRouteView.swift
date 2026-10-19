import SwiftUI

@MainActor
struct VectorLayerImportRouteView: View {
    @ObservedObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    private let initialMapID: UUID

    @State private var selectedMapID: UUID
    @State private var sourceURL: URL?
    @State private var isImporting = false
    @State private var didFailToStart = false

    init(store: WorkspaceStore, initialMapID: UUID) {
        self.store = store
        self.initialMapID = initialMapID
        _selectedMapID = State(initialValue: initialMapID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("Import Vector Layer"))
                .font(.title2.weight(.semibold))

            if !store.hasProject {
                ContentUnavailableView(L10n.text("Open Project"), systemImage: "folder.badge.questionmark")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    Section(L10n.text("Map")) {
                        if mapChoices.isEmpty {
                            ContentUnavailableView(L10n.text("Maps"), systemImage: "map")
                                .frame(minHeight: 100)
                        } else {
                            Picker(L10n.text("Map"), selection: $selectedMapID) {
                                ForEach(mapChoices) { choice in
                                    Text(verbatim: choice.kind.isEmpty
                                        ? choice.name
                                        : choice.name + " · " + L10n.text(choice.kind))
                                        .tag(choice.id)
                                }
                            }
                            .disabled(isImporting)
                        }
                    }

                    Section(L10n.text("Source File")) {
                        Button(L10n.text("Add Map Layer…"), systemImage: "folder") {
                            chooseSource()
                        }
                        .disabled(isImporting)

                        if let sourceURL {
                            LabeledContent(L10n.text("Source File")) {
                                Text(verbatim: sourceURL.path)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            }

                            Label(sourceKind?.displayName ?? L10n.text("Unsupported"),
                                  systemImage: sourceKind?.symbol ?? "exclamationmark.triangle")
                                .foregroundStyle(sourceKind == nil ? Color.orange : Color.secondary)
                        }
                    }

                    if didFailToStart {
                        Section {
                            Label(L10n.text("Import error"), systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .formStyle(.grouped)
            }

            HStack {
                if isImporting { ProgressView().controlSize(.small) }
                Spacer()
                Button(L10n.text("Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isImporting)
                Button(L10n.text("Import"), systemImage: "square.and.arrow.down") {
                    importSelectedSource()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canImport)
            }
        }
        .padding(20)
        .frame(minWidth: 540, idealWidth: 620, minHeight: 350, idealHeight: 420)
        .onAppear(perform: reconcileMapSelection)
        .onChange(of: mapChoiceIDs) { _, _ in reconcileMapSelection() }
        .onChange(of: selectedMapID) { _, _ in didFailToStart = false }
        .onChange(of: store.projectSessionID) { _, _ in
            sourceURL = nil
            didFailToStart = false
            reconcileMapSelection()
        }
    }

    private var mapChoices: [VectorLayerImportMapChoice] {
        guard store.hasProject else { return [] }

        var choices = store.catalogMapDocuments.compactMap { document -> VectorLayerImportMapChoice? in
            guard let id = UUID(uuidString: document.id),
                  store.mapState(for: id).kind != .unsupported else { return nil }
            return VectorLayerImportMapChoice(id: id, name: document.name, kind: document.kind)
        }

        // The project map remains a valid source-map target when a project has
        // no serialized visualization maps yet. Use its stable reserved ID;
        // never infer a target from a map's display name.
        if !choices.contains(where: { $0.id == MapState.projectMapID }),
           store.mapState(for: MapState.projectMapID).kind != .unsupported {
            choices.insert(VectorLayerImportMapChoice(id: MapState.projectMapID,
                name: L10n.text("Project map"), kind: ""), at: 0)
        }
        return choices
    }

    private var mapChoiceIDs: [UUID] { mapChoices.map(\.id) }

    private var sourceKind: VectorLayerImportSourceKind? {
        guard let sourceURL else { return nil }
        if GdbFileGeodatabasePath.root(for: sourceURL) != nil { return .fileGeodatabase }
        switch sourceURL.pathExtension.lowercased() {
        case "shp": return .shapefile
        case "geojson", "json": return .geoJSON
        default: return nil
        }
    }

    private var canImport: Bool {
        !isImporting && store.hasProject && sourceKind != nil
            && mapChoices.contains(where: { $0.id == selectedMapID })
            && !store.isRunningProjectTool && !store.isOpeningProject
            && !store.isSavingAll && !store.isClosingTab
    }

    private func chooseSource() {
        guard let selection = store.system.chooseMapLayer() else { return }
        sourceURL = selection.standardizedFileURL
        didFailToStart = false
    }

    private func reconcileMapSelection() {
        guard !mapChoices.contains(where: { $0.id == selectedMapID }) else { return }
        if mapChoices.contains(where: { $0.id == initialMapID }) {
            selectedMapID = initialMapID
        } else if mapChoices.contains(where: { $0.id == store.lastActiveMapID }) {
            selectedMapID = store.lastActiveMapID
        } else if let first = mapChoices.first {
            selectedMapID = first.id
        }
    }

    private func importSelectedSource() {
        guard canImport, let sourceURL,
              mapChoices.contains(where: { $0.id == selectedMapID }) else { return }

        let mapID = selectedMapID
        let projectSessionID = store.projectSessionID
        isImporting = true
        didFailToStart = false

        Task { @MainActor in
            let didConnect = await store.connectMapSource(sourceURL, for: mapID)
            isImporting = false

            guard store.projectSessionID == projectSessionID else { return }
            guard didConnect else {
                didFailToStart = true
                return
            }

            if let session = store.pendingGdbMapImport, session.mapID == mapID,
               session.sourceURL == GdbFileGeodatabasePath.root(for: sourceURL),
               session.isCurrent(in: store) {
                // The existing GDB import sheet is presented by the target
                // ProjectMapView. Activate that exact map first, then release
                // this global tool sheet so its original presentation route
                // can show the catalog and import controls.
                if mapID == MapState.projectMapID {
                    store.activateMap(mapID)
                    store.activeTab = .page(.map)
                } else if let map = store.mapDocument(for: mapID) {
                    store.openMapDocument(map)
                } else {
                    didFailToStart = true
                    return
                }
            }
            dismiss()
        }
    }
}

private struct VectorLayerImportMapChoice: Identifiable {
    let id: UUID
    let name: String
    let kind: String
}

private enum VectorLayerImportSourceKind: Equatable {
    case shapefile
    case geoJSON
    case fileGeodatabase

    @MainActor var displayName: String {
        switch self {
        case .shapefile: L10n.text("Shapefile")
        case .geoJSON: "GeoJSON"
        case .fileGeodatabase: ".gdb"
        }
    }

    var symbol: String {
        switch self {
        case .shapefile, .geoJSON: "point.3.connected.trianglepath.dotted"
        case .fileGeodatabase: "externaldrive"
        }
    }
}
