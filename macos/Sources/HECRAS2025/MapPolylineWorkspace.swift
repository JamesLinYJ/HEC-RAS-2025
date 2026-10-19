import RASWorkspaceCore
import SwiftUI

/// The editor belongs to the map, so closing its sheet never drops a draft.
struct MapPolylineTools: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var mapState: MapState
    @State private var opening = false
    private var layers: [MapVectorLayer] {
        mapState.vectors(store.mapLayers).filter { layer in
            ["geojson", "json", "shp"].contains(layer.url.pathExtension.lowercased())
                && layer.features.contains { $0.kind == .line }
        }
    }
    var body: some View {
        Menu {
            if mapState.polylineEditor.currentScope != nil {
                Button("Resume Line Editing") { mapState.showsPolylineEditor = true }
                Divider()
            }
            ForEach(layers) { layer in
                Button(layer.name) {
                    opening = true
                    Task {
                        defer { opening = false }
                        _ = await store.openPolylineEditor(layer, mapID: mapState.id)
                    }
                }
            }
            Divider()
            Button("Add Map Layer…") { store.addMapLayer(for: mapState.id) }
        } label: { Label("Polyline editing", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
        .disabled(!store.hasProject || opening || store.isRunningProjectTool || store.isSavingAll)
        .sheet(isPresented: $mapState.showsPolylineEditor) {
            MapPolylineEditorSheet(store: store, mapState: mapState)
        }
    }
}

struct MapPolylineEditorSheet: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var mapState: MapState
    @ObservedObject private var editor: PolylineMapEditingSession
    @Environment(\.dismiss) private var dismiss
    @State private var askingToClose = false
    init(store: WorkspaceStore, mapState: MapState) {
        self.store = store; self.mapState = mapState; editor = mapState.polylineEditor
    }
    private var editingDestinationLayer: MapVectorLayer? {
        guard let scope = editor.currentScope else { return nil }
        return mapState.vectors(store.mapLayers).first {
            $0.id == scope.layerID
                && $0.sourceMapID == scope.mapID
                && $0.sourceRevision == editor.currentSourceRevision
                && SourceFilePaths.canonical($0.url) == scope.canonicalPath
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Polyline editing").font(.headline)
                MapLineChartMenu(store: store, mapState: mapState, editingSelection: true)
                Spacer()
                Button("Done") {
                    if editor.hasUnsavedChanges { askingToClose = true } else { dismiss() }
                }.disabled(editor.isBusy)
            }.padding(12)
            Divider()
            if let scope = editor.currentScope {
                PolylineMapEditingWorkspace(session: editor, scope: scope, destinationLayer: editingDestinationLayer,
                    system: store.system)
            } else {
                ContentUnavailableView("No Layer Selected", systemImage: "point.3.connected.trianglepath.dotted")
            }
        }
        .frame(minWidth: 960, minHeight: 600)
        .interactiveDismissDisabled(editor.hasUnsavedChanges || editor.isBusy)
        .confirmationDialog("Save line edits before closing?", isPresented: $askingToClose, titleVisibility: .visible) {
            Button("Save") { Task { if await editor.save() { dismiss() } } }
            Button("Discard", role: .destructive) { editor.discardForProjectReplacement(); dismiss() }
            Button("Cancel", role: .cancel) {}
        }
    }
}

extension WorkspaceStore {
    @discardableResult
    func openPolylineEditor(_ layer: MapVectorLayer, mapID: UUID) async -> Bool {
        guard hasProject, !isSavingAll, !isRunningProjectTool, !isClosingTab, !isOpeningProject else { return false }
        let project = projectSessionID
        let state = mapState(for: mapID)
        let path = SourceFilePaths.canonical(layer.url)
        let fileType = URL(fileURLWithPath: path).pathExtension.lowercased()
        guard ["geojson", "json", "shp"].contains(fileType),
              layer.sourceMapID == nil || layer.sourceMapID == mapID,
              layer.features.contains(where: { $0.kind == .line }) else {
            errorMessage = L10n.text("Load a supported line layer before editing.")
            return false
        }
        // A shared GeoJSON file must not acquire independent editable drafts in
        // two maps. They would otherwise overwrite one another on Save All.
        guard !hasConflictingMapDraft(path: path, excluding: mapID) else {
            errorMessage = L10n.text("Save or discard this layer's edits in the other map before editing it here.")
            return false
        }
        let scope = PolylineMapEditingScope(projectSessionID: project, mapID: mapID, layerID: layer.id, canonicalPath: path)
        let loaded: Bool
        if fileType == "shp" {
            do {
                guard let sourceRevision = layer.sourceRevision,
                      let provider = layerTreeProvider as? BackendMapTreeProvider else {
                    throw PolylineMapEditingError.invalidScope
                }
                let family: MapSourceFamilyCapture
                if let cached = sourceMapVectorFamilyCaptures[mapID]?[path] {
                    do {
                        family = try MapShapefileVectorConverter.validateFamily(
                            cached, sourcePath: path, sourceRevision: sourceRevision)
                    } catch {
                        family = try await provider.captureShapefileFamily(sourcePath: path)
                    }
                } else {
                    family = try await provider.captureShapefileFamily(sourcePath: path)
                }
                let validated = try MapShapefileVectorConverter.validateFamily(
                    family, sourcePath: path, sourceRevision: sourceRevision)
                loaded = await state.polylineEditor.ensureLoadedShapefile(
                    scope: scope, layer: layer, family: validated)
            } catch {
                errorMessage = L10n.text(error.localizedDescription)
                return false
            }
            state.polylineEditor.didSaveShapefileFamily = { [weak self, weak state] previous, updated, savedScope in
                guard let self, let state else { return false }
                return self.acceptSavedShapefileFamily(updated, previousFamily: previous,
                    scope: savedScope, expectedMapState: state)
            }
        } else {
            loaded = await state.polylineEditor.ensureLoaded(scope: scope)
        }
        guard projectSessionID == project else { return false }
        guard loaded else {
            errorMessage = L10n.text(state.polylineEditor.errorMessage ?? "Load a line layer before editing.")
            return false
        }
        if state.selectedLayerID == layer.id, let selected = state.selectedLineIdentity {
            state.polylineEditor.selectMapComponent(selected, in: layer)
        }
        state.selectedLayerID = layer.id
        state.showsPolylineEditor = true
        return true
    }
}
