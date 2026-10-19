import Foundation
import RASWorkspaceCore

struct MixedMapVectorSourceReadResult: Sendable {
    let layers: [MapVectorLayer]
    let families: [String: MapSourceFamilyCapture]
    let issues: [String]
}

/// Reads one accepted snapshot per physical source. The owning workspace
/// publishes the complete batch only after its map/session guards still match.
@MainActor
enum MixedMapVectorSourceReader {
    static func load(reads: MapVectorSourceReadRequests, nodes: [LayerTreeNode],
                     map: MapTreeMapIdentity, provider: any MapVectorSourceLoading,
                     progress: @escaping @MainActor (MapVectorSourceLoadProgress) -> Void) async throws -> MixedMapVectorSourceReadResult {
        var layers: [MapVectorLayer] = []
        var families: [String: MapSourceFamilyCapture] = [:]
        var issues = reads.issues
        let total = reads.files.count
        progress(.init(completedFiles: 0, totalFiles: total,
                       currentSourceName: reads.files.first?.displayName, issues: issues))
        for (index, request) in reads.files.enumerated() {
            try Task.checkCancellation()
            do {
                if request.url.pathExtension.lowercased() == "shp" {
                    guard let node = nodes.first(where: { request.nodeIDs.contains($0.id) }),
                          let locator = node.sourceLocator else { throw MapSourceLayerError.staleContext }
                    let result = try await MapShapefileSourceLoader.load(map: map, node: locator,
                        expectedSourcePath: request.canonicalPath, expectedSourceRevision: request.sourceRevision,
                        provider: provider)
                    layers.append(result.layer)
                    families[request.canonicalPath] = result.family
                } else {
                    let worker = Task.detached {
                        try MapVectorSourceLoader.load([request])
                    }
                    let result = try await withTaskCancellationHandler {
                        try await worker.value
                    } onCancel: { worker.cancel() }
                    layers.append(contentsOf: result.layers)
                    issues.append(contentsOf: result.issues)
                }
            } catch is CancellationError { throw CancellationError() }
            catch { issues.append("\(request.displayName): \(L10n.text(error.localizedDescription))") }
            try Task.checkCancellation()
            progress(.init(completedFiles: index + 1, totalFiles: total,
                           currentSourceName: reads.files.dropFirst(index + 1).first?.displayName, issues: issues))
        }
        return .init(layers: layers, families: families, issues: issues)
    }
}
