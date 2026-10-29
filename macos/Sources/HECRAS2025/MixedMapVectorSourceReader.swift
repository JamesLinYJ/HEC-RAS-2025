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
                     gdbProvider: any GdbMapSourceLoading,
                     progress: @escaping @MainActor (MapVectorSourceLoadProgress) -> Void) async throws -> MixedMapVectorSourceReadResult {
        var layers: [MapVectorLayer] = []
        var families: [String: MapSourceFamilyCapture] = [:]
        var issues = reads.issues
        let gdbRequests = reads.gdbLayers.sorted {
            ($0.canonicalPath, $0.nodeID) < ($1.canonicalPath, $1.nodeID)
        }
        let orderedNames = reads.files.map(\.displayName) + gdbRequests.map(\.displayName)
        let total = reads.totalSources
        var completed = 0
        progress(.init(completedFiles: 0, totalFiles: total,
                       currentSourceName: orderedNames.first, issues: issues))

        for request in reads.files {
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
            completed += 1
            progress(.init(completedFiles: completed, totalFiles: total,
                           currentSourceName: orderedNames.dropFirst(completed).first, issues: issues))
        }

        let gdbGroups = Dictionary(grouping: gdbRequests, by: \.canonicalPath)
        for path in gdbGroups.keys.sorted() {
            try Task.checkCancellation()
            let requests = (gdbGroups[path] ?? []).sorted { $0.nodeID < $1.nodeID }
            guard let first = requests.first else { continue }
            let firstLayerIndex = layers.count
            var completedInGroup = 0
            do {
                let catalog = try await gdbProvider.catalog(sourcePath: path, expectedSourceRevision: nil)
                try catalog.source.validate(expectedPath: first.url)

                for request in requests {
                    try Task.checkCancellation()
                    do {
                        guard request.canonicalPath == path,
                              request.locator.nodeType == "GdbVectorLayer",
                              request.locator.mapType == "GdbVectorLayer",
                              request.locator.assetID.map({
                                  SourceFilePaths.canonical(URL(fileURLWithPath: $0)) == path
                              }) ?? false else {
                            throw GdbMapSourceError.mismatchedReply
                        }
                        let descriptors = catalog.layers.filter {
                            $0.name == request.layerName && $0.vectorType == request.vectorType
                        }
                        guard descriptors.count == 1, let descriptor = descriptors.first else {
                            throw GdbMapSourceError.mismatchedReply
                        }
                        try descriptor.validate()
                        let response = try await gdbProvider.load(.init(map: map, node: request.locator,
                            expectedSourceRevision: catalog.source.revision))
                        try Task.checkCancellation()
                        let layer = try GdbMapSourceConverter.makeLayer(response: response,
                            expectedMap: map, expectedNode: request.locator, expectedNodeID: request.nodeID,
                            expectedSource: catalog.source, expectedLayerName: request.layerName,
                            expectedLayer: descriptor, mapID: request.mapID)
                        layers.append(layer)
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        issues.append("\(request.displayName): \(L10n.text(error.localizedDescription))")
                    }
                    completed += 1
                    completedInGroup += 1
                    progress(.init(completedFiles: completed, totalFiles: total,
                        currentSourceName: orderedNames.dropFirst(completed).first, issues: issues))
                }

                // Each leaf is read in a separate request. Re-catalog after
                // the group to prevent mixed revisions if any package member
                // changed between two layer loads.
                let verified = try await gdbProvider.catalog(sourcePath: path,
                    expectedSourceRevision: catalog.source.revision)
                guard verified.source == catalog.source else { throw GdbMapSourceError.sourceChanged }
            } catch is CancellationError { throw CancellationError() }
            catch {
                layers.removeSubrange(firstLayerIndex..<layers.count)
                issues.append("\(first.displayName): \(L10n.text(error.localizedDescription))")
                // A catalog failure occurs before any leaf reaches the inner
                // loop. Advance each leaf as failed so the visible count stays
                // honest without presenting a false success state.
                while completedInGroup < requests.count {
                    completed += 1
                    completedInGroup += 1
                    progress(.init(completedFiles: completed, totalFiles: total,
                        currentSourceName: orderedNames.dropFirst(completed).first, issues: issues))
                }
            }
            try Task.checkCancellation()
        }
        return .init(layers: layers, families: families, issues: issues)
    }
}
