import Foundation
import SwiftUI

/// Native equivalent of the source AdditionalOptionProperties checkbox for
/// raster-backed associations. The caller owns the per-map, per-capture value;
/// the capture gate prevents this option from appearing on unrelated rows.
struct AssociatedMapLayerRasterTileOutlineToggle: View {
    @ObservedObject var store: WorkspaceStore
    let mapID: UUID
    let capture: AssociatedMapLayerCapture

    private var isEnabled: Binding<Bool> {
        Binding(
            get: {
                store.associatedRasterTileOutlines(mapID: mapID,
                    locator: capture.associationNode, assetPath: capture.assetPath)
            },
            set: { enabled in
                store.setAssociatedRasterTileOutlines(enabled, mapID: mapID,
                    locator: capture.associationNode, assetPath: capture.assetPath)
            })
    }

    nonisolated static func supports(_ capture: AssociatedMapLayerCapture) -> Bool {
        guard let kind = capture.associationNode.associationKind else { return false }
        return (kind == "Terrain" || kind == "NValue")
            && capture.isChecked && capture.effectiveVisible
    }

    @ViewBuilder
    var body: some View {
        if Self.supports(capture) {
            Toggle(L10n.text("Plot Raster Tile Outlines"), isOn: isEnabled)
                .disabled(store.isRunningPlanCompute)
        }
    }
}
