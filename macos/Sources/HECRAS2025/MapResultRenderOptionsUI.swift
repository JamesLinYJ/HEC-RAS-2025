import SwiftUI
import RASWorkspaceCore

/// Transient rendering controls for one exact active Result/MultiResult slot.
/// The session binds values to the map, node, slot, Result path and revision;
/// changing them never mutates the saved visualization file.
struct MapResultRenderOptionsControls: View {
    @ObservedObject var session: MapResultMapSession
    let mapID: UUID
    let node: CatalogTreeNodeLocator
    let mapType: String?
    let selectionIndex: Int
    let resultPath: String
    let revision: String

    private var options: MapResultRenderOptions {
        session.renderOptions(mapID: mapID, node: node, selectionIndex: selectionIndex,
            resultPath: resultPath, revision: revision)
    }

    private var canEdit: Bool {
        session.canSetRenderOptions(mapID: mapID, node: node, mapType: mapType, selectionIndex: selectionIndex,
            resultPath: resultPath, revision: revision)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if mapType == "Velocity" {
                Picker(L10n.text("Velocity Display Mode"), selection: Binding(
                    get: { options.velocityDisplay },
                    set: { next in
                        var updated = options
                        updated.velocityDisplay = next
                        apply(updated)
                    })) {
                    ForEach(MapResultVelocityDisplay.allCases, id: \.self) { mode in
                        Text(L10n.text(mode.titleKey)).tag(mode)
                    }
                }
                .disabled(!canEdit)

                Toggle(L10n.text("Map Diagnostics"), isOn: Binding(
                    get: { options.mapDiagnostics },
                    set: { next in
                        var updated = options
                        updated.mapDiagnostics = next
                        apply(updated)
                    }))
                    .disabled(!canEdit)
            }

            Toggle(L10n.text("Force Refresh Map Points"), isOn: Binding(
                get: { options.forceRecomputeMapPoints },
                set: { next in
                    var updated = options
                    updated.forceRecomputeMapPoints = next
                    apply(updated)
                }))
                .disabled(!canEdit)
        }
        .font(.caption)
        .accessibilityElement(children: .contain)
    }

    private func apply(_ next: MapResultRenderOptions) {
        session.setRenderOptions(next, mapID: mapID, node: node, mapType: mapType,
            selectionIndex: selectionIndex, resultPath: resultPath, revision: revision)
    }
}

/// Displays only the exact world-space diagnostic labels accepted with the
/// currently installed Result raster layers. Coordinates come from the
/// retained ResultMapRenderLayer, not from a reconstructed mesh or screen guess.
struct MapResultDiagnosticCanvas: View {
    @ObservedObject var session: MapResultMapSession
    let points: [MapPoint]
    let scale: CGFloat
    let offset: CGSize
    let visibleLayerIDs: Set<String>

    var body: some View {
        GeometryReader { geometry in
            let transform = MapTransform(points: points, size: geometry.size,
                scale: scale, offset: offset)
            Canvas { context, _ in
                for annotation in session.diagnosticAnnotations(visibleLayerIDs: visibleLayerIDs) {
                    guard annotation.x.isFinite, annotation.y.isFinite else { continue }
                    let location = transform.screen(MapPoint(x: annotation.x, y: annotation.y))
                    let label = Text(verbatim: annotation.text)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.orange)
                    context.draw(label, at: location)
                }
            }
        }
        .allowsHitTesting(false)
    }
}
