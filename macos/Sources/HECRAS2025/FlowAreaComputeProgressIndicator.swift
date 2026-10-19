import RASWorkspaceCore
import SwiftUI

/// Projects the source FlowAreaNode.ActiveComputeJob onto its exact geometry
/// tree row while the retained Generate Mesh job is active in that editor.
struct FlowAreaComputeProgressIndicator: View {
    let node: LayerTreeNode
    @ObservedObject var treeSession: LayerTreeSession
    @ObservedObject var store: WorkspaceStore

    private var activeMeshSession: GeometryMeshSession? {
        guard node.sourceClass == "FlowAreaLayerVisualContext",
              let treeContext = treeSession.activeContext,
              treeContext.projectSessionID == store.projectSessionID,
              let asset = owningGeometryAsset,
              asset.section == .geometries,
              asset.isModelFile else { return nil }
        return store.activeGeometryMeshGeneration(assetID: asset.id,
            projectSessionID: treeContext.projectSessionID)
    }

    private var owningGeometryAsset: ProjectAsset? {
        guard let roots = treeSession.roots else { return nil }
        var sourcePaths = Set<String>()
        for root in roots {
            guard let ancestorIDs = root.ancestorIDs(of: node.id) else { continue }
            for ancestorID in ancestorIDs {
                guard let ancestor = root.find(ancestorID),
                      ancestor.catalogSummaryKind == .geometry,
                      let assetID = ancestor.assetID else { continue }
                sourcePaths.insert(SourceFilePaths.canonical(URL(fileURLWithPath: assetID)))
            }
        }
        guard sourcePaths.count == 1, let sourcePath = sourcePaths.first else { return nil }
        let matches = store.assets.filter {
            $0.section == .geometries && $0.isModelFile
                && SourceFilePaths.canonical($0.url) == sourcePath
        }
        return matches.count == 1 ? matches.first : nil
    }

    var body: some View {
        if let mesh = activeMeshSession {
            FlowAreaComputeGenerationIndicator(session: mesh)
        }
    }
}

private struct FlowAreaComputeGenerationIndicator: View {
    @ObservedObject var session: GeometryMeshSession

    var body: some View {
        HStack(spacing: 5) {
            if let fraction = session.meshGenerationProgress?.fraction, fraction.isFinite {
                ProgressView(value: min(1, max(0, fraction)))
                    .progressViewStyle(.linear)
                    .frame(width: 42)
                    .accessibilityLabel(L10n.text("Mesh generation progress"))
            } else {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(L10n.text("Mesh generation progress"))
            }
            Text(L10n.text(session.isCancellingMeshGeneration
                ? "Cancelling mesh generation" : "Generating mesh"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if session.canCancelMeshGeneration {
                Button { session.cancelMeshGeneration() } label: {
                    Image(systemName: "xmark.circle")
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L10n.text("Cancel mesh generation"))
                .help(L10n.text("Cancel mesh generation"))
            }
        }
        .accessibilityElement(children: .combine)
    }
}
