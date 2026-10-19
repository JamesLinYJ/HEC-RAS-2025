import RASWorkspaceCore
import SwiftUI

/// Add directly above the source raster canvas. `points` must be exactly the
/// same map transform points as the base map canvas so every surface shares
/// the same camera center and scale.
struct CalculatorMapLayerCanvas: View {
    @ObservedObject private var store: WorkspaceStore
    @ObservedObject private var registry: CalculatorLayerRegistry
    let mapID: UUID
    let points: [MapPoint]
    let scale: CGFloat
    let offset: CGSize
    let viewport: RasterMapViewExtent?

    init(store: WorkspaceStore, mapID: UUID, points: [MapPoint], scale: CGFloat,
         offset: CGSize, viewport: RasterMapViewExtent?) {
        self.store = store
        self.registry = store.calculatorLayerRegistry
        self.mapID = mapID
        self.points = points
        self.scale = scale
        self.offset = offset
        self.viewport = viewport
    }

    private var identity: String { store.mapWorkflowIdentity(mapID) }
    private var ownerIdentity: String {
        let owners = store.catalogMapDocuments.compactMap { map -> String? in
            guard UUID(uuidString: map.id) != nil else { return nil }
            return map.id.lowercased() + "|" + map.kind
        }.sorted()
        return ([store.projectSessionID.uuidString] + owners).joined(separator: "|")
    }
    private var mapTypesByID: [UUID: String] {
        Dictionary(store.catalogMapDocuments.compactMap { map in
            guard let id = UUID(uuidString: map.id) else { return nil }
            return (id, map.kind)
        }, uniquingKeysWith: { _, current in current })
    }
    private var visibleEntries: [CalculatorMapLayerEntry] {
        registry.layers(mapID: mapID, projectSessionID: store.projectSessionID,
            workflowIdentity: identity)
    }
    private var renderRevision: Int {
        store.rasterRevision + visibleEntries.reduce(0) { $0 &+ $1.frameRevision }
    }

    var body: some View {
        RasterCanvas(layers: visibleEntries.compactMap(\.layer), points: points,
            scale: scale, offset: offset, revision: renderRevision)
            .task(id: viewportKey) {
                guard let viewport else { return }
                registry.updateViewport(viewport, mapID: mapID,
                    projectSessionID: store.projectSessionID, workflowIdentity: identity)
            }
            .onAppear {
                registry.synchronizeOwners(projectSessionID: store.projectSessionID,
                    mapTypes: mapTypesByID)
            }
            .onChange(of: ownerIdentity) { _, _ in
                registry.synchronizeOwners(projectSessionID: store.projectSessionID,
                    mapTypes: mapTypesByID)
            }
            .onChange(of: identity) { _, newValue in
                registry.refreshMapCapture(mapID: mapID,
                    projectSessionID: store.projectSessionID,
                    mapCapture: store.mapIdentityRequest(for: mapID),
                    workflowIdentity: newValue, viewport: viewport)
            }
    }

    private var viewportKey: String {
        guard let viewport else { return "none" }
        return [String(viewport.minX), String(viewport.minY),
            String(viewport.maxX), String(viewport.maxY),
            String(viewport.pixelWidth), String(viewport.pixelHeight)].joined(separator: "|")
    }
}

struct CalculatorMapLayerControls: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject private var registry: CalculatorLayerRegistry
    let mapID: UUID
    let viewport: RasterMapViewExtent?
    var onEdit: (String) -> Void = { _ in }

    init(store: WorkspaceStore, mapID: UUID, viewport: RasterMapViewExtent?,
         onEdit: @escaping (String) -> Void = { _ in }) {
        self.store = store
        self.registry = store.calculatorLayerRegistry
        self.mapID = mapID
        self.viewport = viewport
        self.onEdit = onEdit
    }

    private var identity: String { store.mapWorkflowIdentity(mapID) }
    private var entries: [CalculatorMapLayerEntry] {
        guard let mapType = store.mapIdentityRequest(for: mapID)?.mapType else { return [] }
        return registry.allLayers(mapID: mapID,
            projectSessionID: store.projectSessionID, mapType: mapType)
    }

    var body: some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Raster Calculator Layers").font(.headline)
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Toggle(isOn: Binding(get: { entry.isVisible }, set: { value in
                                store.calculatorLayerRegistry.setVisible(value, id: entry.id,
                                    mapID: mapID, projectSessionID: store.projectSessionID,
                                    workflowIdentity: identity)
                            })) { Text(entry.name).lineLimit(1) }
                            .disabled(entry.mapWorkflowIdentity != identity)
                            if entry.isRendering { ProgressView().controlSize(.small) }
                            Button("Edit") { onEdit(entry.id) }
                                .disabled(entry.mapWorkflowIdentity != identity || store.isOpeningProject
                                    || store.isClosingTab || store.isRunningProjectTool)
                            Button(role: .destructive) {
                                store.calculatorLayerRegistry.remove(id: entry.id, mapID: mapID,
                                    projectSessionID: store.projectSessionID, workflowIdentity: identity)
                            } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .disabled(entry.mapWorkflowIdentity != identity)
                            .help("Remove Calculator Layer")
                        }
                        if let renderError = entry.renderError {
                            Label(renderError, systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        if entry.isDynamic {
                            Picker("Profile", selection: Binding(get: { entry.selectedProfileIndex }, set: { index in
                                guard let viewport else { return }
                                store.calculatorLayerRegistry.selectProfile(index, id: entry.id,
                                    viewport: viewport, mapID: mapID,
                                    projectSessionID: store.projectSessionID,
                                    workflowIdentity: identity)
                            })) {
                                ForEach(entry.profiles) { profile in
                                    Text(profile.time).tag(profile.index)
                                }
                            }
                            .disabled(entry.mapWorkflowIdentity != identity || viewport == nil
                                || entry.profiles.isEmpty || entry.isRendering)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

private struct CalculatorLayerEditRequest: Identifiable {
    let id: String
}

struct CalculatorMapLayerMenu: View {
    @ObservedObject private var store: WorkspaceStore
    @ObservedObject private var registry: CalculatorLayerRegistry
    let mapID: UUID
    let viewport: RasterMapViewExtent?
    @State private var isPresented = false
    @State private var editRequest: CalculatorLayerEditRequest?

    init(store: WorkspaceStore, mapID: UUID, viewport: RasterMapViewExtent?) {
        self.store = store
        self.registry = store.calculatorLayerRegistry
        self.mapID = mapID
        self.viewport = viewport
    }

    private var identity: String { store.mapWorkflowIdentity(mapID) }
    private var entries: [CalculatorMapLayerEntry] {
        guard let mapType = store.mapIdentityRequest(for: mapID)?.mapType else { return [] }
        return registry.allLayers(mapID: mapID, projectSessionID: store.projectSessionID,
            mapType: mapType)
    }

    @ViewBuilder
    var body: some View {
        if !entries.isEmpty {
            Button { isPresented.toggle() } label: {
                Label("Calculator Layers", systemImage: "function")
            }
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                CalculatorMapLayerControls(store: store, mapID: mapID,
                    viewport: viewport, onEdit: beginEditing)
                    .padding(12)
                    .frame(width: 360)
            }
            .sheet(item: $editRequest) { request in
                RasterCalculatorWorkspace(store: store, mapID: mapID,
                    viewport: { viewport }, editingLayerID: request.id,
                    onClose: { editRequest = nil })
                    .frame(minWidth: 900, minHeight: 600)
            }
            .onChange(of: store.projectSessionID) { _, _ in dismissPresentations() }
        }
    }

    private func beginEditing(_ layerID: String) {
        let expectedSession = store.projectSessionID
        let expectedWorkflow = identity
        isPresented = false
        Task { @MainActor in
            await Task.yield()
            guard store.projectSessionID == expectedSession,
                  store.mapWorkflowIdentity(mapID) == expectedWorkflow,
                  registry.entry(id: layerID, mapID: mapID,
                      projectSessionID: expectedSession,
                      workflowIdentity: expectedWorkflow) != nil else { return }
            editRequest = CalculatorLayerEditRequest(id: layerID)
        }
    }

    private func dismissPresentations() {
        isPresented = false
        editRequest = nil
    }
}
