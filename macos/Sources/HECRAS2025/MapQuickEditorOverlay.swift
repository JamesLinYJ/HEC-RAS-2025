import Foundation
import RASWorkspaceCore
import SwiftUI

/// Exact owner passed by the active map route. It binds a selected map line to
/// a loaded editor session only when both refer to the same current source.
struct MapQuickEditorPayloadContext {
    let capture: BoundaryMapCapture
    let mapLine: BoundaryMapLinePresentation
    let editorSession: ModelEditorSession
    let line: BoundaryLinePresentation

    var identity: String {
        [capture.identity, editorSession.id.uuidString, line.id]
            .map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }
}

/// Port of MapQuickEditor_Opened for the real BoundaryConditionLine owner.
/// The source selection is the composite visible-line identity plus its exact
/// BoundaryMapCapture; editor payloads are never guessed from display names.
enum MapQuickEditorPayloadContextResolver {
    @MainActor
    static func resolve(mapState: MapState, editorSession: ModelEditorSession?,
                        projectSessionID: UUID, mapWorkflowIdentity: String,
                        linkedContext: MapLinkedFeatureSelectionContext? = nil)
        -> MapQuickEditorPayloadContext? {
        guard !mapState.linkedResults.isActive,
              let editorSession, editorSession.loaded else { return nil }

        let source: BoundaryMapSourceState?
        let mapLine: BoundaryMapLinePresentation?
        if let linkedContext {
            guard linkedContext.ownerKind == .boundaryCondition,
                  linkedContext.projectSessionID == projectSessionID,
                  linkedContext.mapWorkflowIdentity == mapWorkflowIdentity,
                  linkedContext.mapID == mapState.id,
                  let linkedSource = mapState.boundaryMap.entries.first(where: {
                      $0.capture.identity == linkedContext.sourceOwnerIdentity
                  }),
                  let linkedLine = linkedSource.visibleLines.first(where: { $0.id == linkedContext.featureIdentity }),
                  linkedContext.sourcePath == linkedSource.capture.sourcePath,
                  linkedContext.sourceRevision == linkedSource.capture.sourceRevision,
                  linkedContext.sourceContextIdentity == "\(mapState.id.uuidString)|\(linkedSource.capture.boundaryNode.sourceIdentity)"
            else { return nil }
            source = linkedSource
            mapLine = BoundaryMapLinePresentation(sourceIdentity: linkedSource.capture.sourceIdentity,
                                                   line: linkedLine)
        } else {
            guard let selectedID = mapState.boundaryMap.selectedLineID,
                  let selectedLine = mapState.boundaryMap.visibleLines.first(where: { $0.id == selectedID }),
                  let selectedSource = mapState.boundaryMap.entries.first(where: {
                      $0.capture.sourceIdentity == selectedLine.sourceIdentity
                  }) else { return nil }
            source = selectedSource
            mapLine = selectedLine
        }

        guard let source, let mapLine,
              source.status == .available,
              source.capture.map.mapID.caseInsensitiveCompare(mapState.id.uuidString) == .orderedSame,
              source.capture.projectSessionID == projectSessionID,
              source.capture.mapWorkflowIdentity == mapWorkflowIdentity,
              source.capture.boundaryNode.nodeType == "BoundaryCondition",
              source.capture.isChecked, source.capture.effectiveVisible,
              let editorAssetID = editorSession.modelAssetID,
              canonicalPath(editorAssetID) == canonicalPath(source.capture.sourcePath),
              editorSession.sourceFileRevision == source.capture.sourceRevision,
              let line = editorSession.boundaryLines?.lines.first(where: { $0.id == mapLine.line.id }) else {
            return nil
        }
        return MapQuickEditorPayloadContext(capture: source.capture, mapLine: mapLine,
                                            editorSession: editorSession, line: line)
    }

    private static func canonicalPath(_ path: String) -> String {
        SourceFilePaths.canonical(URL(fileURLWithPath: path))
    }
}

enum MapQuickEditorOverlayPlacement {
    static func position(anchor: CGPoint, canvasSize: CGSize,
                         panelSize: CGSize = CGSize(width: 380, height: 400),
                         gap: CGFloat = 12) -> CGPoint? {
        guard anchor.x.isFinite, anchor.y.isFinite,
              canvasSize.width.isFinite, canvasSize.height.isFinite,
              panelSize.width.isFinite, panelSize.height.isFinite,
              gap.isFinite, canvasSize.width > 0, canvasSize.height > 0,
              panelSize.width > 0, panelSize.height > 0 else { return nil }
        let margin: CGFloat = 8
        let width = min(panelSize.width, max(canvasSize.width - margin * 2, 1))
        let height = min(panelSize.height, max(canvasSize.height - margin * 2, 1))
        let rightCenter = anchor.x + gap + width / 2
        let x = rightCenter + width / 2 <= canvasSize.width - margin
            ? rightCenter : anchor.x - gap - width / 2
        let belowCenter = anchor.y + gap + height / 2
        let y = belowCenter + height / 2 <= canvasSize.height - margin
            ? belowCenter : anchor.y - gap - height / 2
        return CGPoint(x: min(max(x, margin + width / 2), canvasSize.width - margin - width / 2),
                       y: min(max(y, margin + height / 2), canvasSize.height - margin - height / 2))
    }
}

/// Native attached payload panel for the exact selected Boundary Condition
/// line. The existing source-backed editor view supplies Add Payload and
/// View Payload actions; the parent supplies their current workspace routes.
@MainActor
struct MapQuickEditorPayloadOverlay: View {
    let context: MapQuickEditorPayloadContext?
    @Binding var isPresented: Bool
    let anchor: CGPoint?
    let canvasSize: CGSize
    let onCreate: (BoundaryLinePresentation) -> Void
    let onViewPayload: (BoundaryLinePresentation, String) -> Void

    private var resolvedPosition: CGPoint? {
        guard let anchor else { return nil }
        return MapQuickEditorOverlayPlacement.position(anchor: anchor, canvasSize: canvasSize)
    }

    var body: some View {
        GeometryReader { _ in
            if isPresented, let context, let position = resolvedPosition {
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        Button {
                            isPresented = false
                        } label: {
                            Label("Close", systemImage: "xmark")
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .help(L10n.text("Close"))
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    BoundaryConditionLineQuickEditPicker(
                        line: context.line,
                        session: context.editorSession,
                        onCreate: {
                            isPresented = false
                            onCreate(context.line)
                        },
                        onViewPayload: {
                            isPresented = false
                            onViewPayload(context.line, $0)
                        }
                    )
                }
                .frame(width: 380)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary, lineWidth: 0.7))
                .position(x: position.x, y: position.y)
                .zIndex(10_000)
                .id(context.identity)
                .onAppear { context.editorSession.selectBoundaryLine(context.line.id) }
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .allowsHitTesting(isPresented && context != nil && resolvedPosition != nil)
        .accessibilityIdentifier(context.map { "map-quick-editor-\($0.line.id)" } ?? "map-quick-editor-unavailable")
    }
}
