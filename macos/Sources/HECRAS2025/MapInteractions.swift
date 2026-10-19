import AppKit
import RASWorkspaceCore
import SwiftUI

struct MapToolDescriptor: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let description: String
    let group: String
    let source: String
}
struct MapInput: Sendable {
    enum Kind: Sendable { case click, doubleClick, drag, dragEnded, pointerMoved }
    let kind: Kind
    let toolID: String
    let mapID: UUID
    let point: MapPoint
    let screenX: Double
    let screenY: Double
    let modifiers: Set<Modifier>
    enum Modifier: String, Sendable { case shift, control, option, command }
    @MainActor static func currentModifiers() -> Set<Modifier> {
        guard let flags = NSApp.currentEvent?.modifierFlags else { return [] }
        var result: Set<Modifier> = []
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.command) { result.insert(.command) }
        return result
    }
}
struct MapHistoryAvailability: Sendable {
    let canUndo: Bool
    let canRedo: Bool
}
struct MapRasterSourceIdentity: Equatable, Hashable, Sendable {
    let resultPath: String
    let revision: String
}
struct MapUpdate: Sendable {
    let vectors: [MapVectorLayer]?
    let rasters: [MapRasterLayer]?
    let preview: [MapFeature]
    let selectedLayerID: String?
    let selectedFeatureID: Int?
    var history: MapHistoryAvailability? = nil
    /// When non-nil, replaces only this map's vector style presentations,
    /// keyed by the associated MapVectorLayer.id. Nil leaves styles unchanged.
    var vectorStyles: [String: MapVectorStylePresentation]? = nil
    /// Source slot ownership for each returned result raster. Nil means the
    /// producer has no ownership mapping; when a live slot is unreadable,
    /// unmapped rasters are conservatively hidden.
    var rasterSelectionIndicesByLayerID: [String: [Int]]? = nil
    /// Raw result identity for each raster, joined from the renderer's exact
    /// source path and revision. Used to prevent stale cached frames from
    /// resurfacing after a live slot changes to another stored Result.
    var rasterSourceIdentityByLayerID: [String: MapRasterSourceIdentity]? = nil
    /// Style-only updates leave the active map's interaction and draft state
    /// untouched while still installing vectorStyles above.
    var preserveInteractionState = false
}
@MainActor
protocol MapInteractionProvider {
    func handle(_ input: MapInput) async throws -> MapUpdate
    func undo() async throws -> MapUpdate
    func redo() async throws -> MapUpdate
    func toolPalette(_ context: ToolPaletteContext) async throws -> ToolPaletteSnapshot?
    func activateTool(_ id: String, context: ToolPaletteContext) async throws -> MapUpdate
    func changeToolOption(_ id: String, value: String, scopeID: String, context: ToolPaletteContext) async throws -> MapUpdate
}
extension MapInteractionProvider {
    func toolPalette(_ context: ToolPaletteContext) async throws -> ToolPaletteSnapshot? { nil }
    func activateTool(_ id: String, context: ToolPaletteContext) async throws -> MapUpdate { throw CocoaError(.featureUnsupported) }
    func changeToolOption(_ id: String, value: String, scopeID: String, context: ToolPaletteContext) async throws -> MapUpdate { throw CocoaError(.featureUnsupported) }
}

enum MapCanvasNavigation {
    /// TiledMap accepts wheel zoom while its current tool is idle, including
    /// when an editing tool is selected. The caller supplies transient active
    /// interaction state; the selected tool ID alone is not that state.
    static func allowsWheelZoom(toolIsActive: Bool) -> Bool {
        !toolIsActive
    }
}

extension MapState {
    /// A pointer annotation is shown only for a concrete descriptor installed
    /// by the source tool palette, never for an unknown tool ID.
    var activeToolAnnotation: PaletteToolDescriptor? {
        guard toolID != "select",
              let descriptor = toolPaletteSession.descriptor(toolID), descriptor.id == toolID else { return nil }
        return descriptor
    }
}

struct MapToolMenu: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var mapState: MapState
    let mapID: UUID
    @ObservedObject private var session: ToolPaletteSession
    @State private var paletteOpen = false
    init(store: WorkspaceStore, mapState: MapState, mapID: UUID) {
        self.store = store; self.mapState = mapState; self.mapID = mapID; session = mapState.toolPaletteSession
    }
    var body: some View {
        Button { paletteOpen.toggle() } label: {
            Label("Map Tools", systemImage: session.descriptor(mapState.toolID)?.symbol ?? "cursorarrow")
        }.popover(isPresented: $paletteOpen) {
            ToolPaletteView(store: store, session: session, close: { paletteOpen = false })
        }
        .task(id: ToolPaletteContext(projectSessionID: store.projectSessionID, mapID: mapID, selectedLayerID: mapState.selectedLayerID)) {
            let context = ToolPaletteContext(projectSessionID: store.projectSessionID, mapID: mapID, selectedLayerID: mapState.selectedLayerID)
            await session.load(provider: store.mapInteractionProvider, context: context)
        }
        .onChange(of: session.currentToolID) { _, id in mapState.toolID = id }
        .alert("HEC-RAS 2025", isPresented: Binding(get: { session.error != nil }, set: { if !$0 { session.error = nil } })) {
            Button("OK") { session.error = nil }
        } message: { Text(session.error ?? "") }
    }
}
