import SwiftUI

enum EditorToolImportPresentation: Identifiable {
    case terrain(requestID: UUID)
    case initialConditions(requestID: UUID, consumesHandoff: Bool)
    case classification(requestID: UUID)
    case gridded(requestID: UUID, layer: SpatialBoundaryLayer)
    case chooseGridded(requestID: UUID, layers: [SpatialBoundaryLayer])
    case spatialBoundary(requestID: UUID, assetID: String, layerID: String?)

    var id: UUID {
        switch self {
        case .terrain(let requestID), .classification(let requestID),
             .gridded(let requestID, _), .chooseGridded(let requestID, _),
             .spatialBoundary(let requestID, _, _),
             .initialConditions(let requestID, _): requestID
        }
    }
}

/// Geometry actions navigate to the primary editor and leave real feature
/// selection to its topology workspace. No target FID is synthesized here.
enum GeometryEditorToolDestination {
    case topology
    case recipe
    case arcPoints
    case tagFilter
    case vectorImport

    var pageID: String {
        switch self {
        case .topology: "Topology"
        case .recipe: "Regions"
        case .arcPoints, .tagFilter, .vectorImport: "Arcs"
        }
    }
}

extension EditorToolPresentationRequest {
    var geometryEditorDestination: GeometryEditorToolDestination? {
        switch action {
        case .topology: .topology
        case .topologyRecipe: .recipe
        case .arcPoints: .arcPoints
        case .tagFilter: .tagFilter
        case .vectorImport: .vectorImport
        default: nil
        }
    }
}

/// Hosts the already source-backed editor import sheets. The chooser branch
/// keeps a request alive until a concrete Gridded layer has been selected and
/// its actual import sheet is on screen.
struct EditorToolPresentationSheet: View {
    let presentation: EditorToolImportPresentation
    @ObservedObject var session: ModelEditorSession
    @ObservedObject var store: WorkspaceStore
    let onAccepted: (UUID) -> Void
    let onCancel: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedGridLayerID: String?
    @State private var acceptedRequestID: UUID?

    var body: some View {
        switch presentation {
        case .spatialBoundary(let requestID, let assetID, let layerID):
            SpatialBoundaryImportRouteView(store: store, session: session,
                assetID: assetID, layerID: layerID)
                .onAppear { acceptOnce(requestID) }
        case .initialConditions(let requestID, let consumesHandoff):
            BoundaryInitialConditionsEditorSheet(store: store, editor: session, onReady: {
                if consumesHandoff { acceptOnce(requestID) }
            }, onClose: { onCancel(requestID); dismiss() })
        case .terrain(let requestID):
            TerrainInputImportSheet(initialFiles: [], session: session, store: store)
                .onAppear { acceptOnce(requestID) }
        case .classification(let requestID):
            ClassificationImportSheet(initialFiles: [], session: session, store: store)
                .onAppear { acceptOnce(requestID) }
        case .gridded(let requestID, let layer):
            gridImport(layer, requestID: requestID)
        case .chooseGridded(let requestID, let layers):
            if let selectedGridLayer = layers.first(where: { $0.id == selectedGridLayerID }) {
                gridImport(selectedGridLayer, requestID: requestID)
            } else {
                GriddedImportLayerChooser(layers: layers, onSelect: { layer in
                    selectedGridLayerID = layer.id
                }, onCancel: {
                    onCancel(requestID)
                    dismiss()
                })
                .interactiveDismissDisabled()
            }
        }
    }

    private func gridImport(_ layer: SpatialBoundaryLayer, requestID: UUID) -> some View {
        SpatialGridImportSheet(layer: layer, session: session, store: store, openCumulusImporter: {
            store.startSpatialImport(layerID: layer.id, assetID: session.modelAssetID, tool: .griddedImport, editorID: session.id)
        })
        .onAppear { acceptOnce(requestID) }
    }

    private func acceptOnce(_ requestID: UUID) {
        guard acceptedRequestID != requestID else { return }
        acceptedRequestID = requestID
        onAccepted(requestID)
    }
}

private struct GriddedImportLayerChooser: View {
    let layers: [SpatialBoundaryLayer]
    let onSelect: (SpatialBoundaryLayer) -> Void
    let onCancel: () -> Void
    @State private var selection: String?

    var body: some View {
        VStack(spacing: 12) {
            Text("Choose a Gridded Layer").font(.title2.weight(.semibold))
            List(layers, id: \.id, selection: $selection) { layer in
                Label(LocalizedStringKey(layer.title), systemImage: layer.symbol).tag(Optional(layer.id))
            }
            .frame(minWidth: 360, minHeight: 220)
            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                Spacer()
                Button("Continue") {
                    if let selection, let layer = layers.first(where: { $0.id == selection }) { onSelect(layer) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 320)
    }
}

struct EditorToolPresentationNotice: View {
    let message: String
    let detail: String?
    let retry: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(message).font(.callout)
                if let detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            Button("Retry", action: retry)
            Button("Cancel", role: .cancel, action: cancel)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(12)
    }
}
