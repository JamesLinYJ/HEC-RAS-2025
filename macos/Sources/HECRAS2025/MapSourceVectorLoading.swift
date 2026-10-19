import CryptoKit
import Foundation
import RASWorkspaceCore
import SwiftUI

enum MapVectorLoadPhase: String, Sendable {
    case loading
    case cancelling
    case completed
    case cancelled
    case failed
}

struct MapVectorLoadState: Equatable, Sendable {
    let operationID: UUID
    let projectSessionID: UUID
    let mapWorkflowIdentity: String
    let phase: MapVectorLoadPhase
    let completedFiles: Int
    let totalFiles: Int
    let currentSourceName: String?
    let issues: [String]

    var fraction: Double? {
        guard totalFiles > 0 else { return nil }
        return min(max(Double(completedFiles) / Double(totalFiles), 0), 1)
    }

    var isActive: Bool { phase == .loading || phase == .cancelling }

    func replacing(phase: MapVectorLoadPhase? = nil, completedFiles: Int? = nil,
                   currentSourceName: String?? = nil, issues: [String]? = nil) -> Self {
        .init(operationID: operationID, projectSessionID: projectSessionID,
              mapWorkflowIdentity: mapWorkflowIdentity, phase: phase ?? self.phase,
              completedFiles: completedFiles ?? self.completedFiles,
              totalFiles: totalFiles,
              currentSourceName: currentSourceName ?? self.currentSourceName,
              issues: issues ?? self.issues)
    }
}

struct MapVectorSourceReadRequest: Sendable {
    let mapID: UUID
    let url: URL
    let sourceIdentity: String
    let sourceRevision: String
    let nodeIDs: [String]
    let displayName: String

    var canonicalPath: String { SourceFilePaths.canonical(url) }
}

struct MapVectorSourceReadRequests: Sendable {
    let files: [MapVectorSourceReadRequest]
    let gdbLayers: [GdbMapVectorSourceReadRequest]
    let issues: [String]

    init(files: [MapVectorSourceReadRequest], gdbLayers: [GdbMapVectorSourceReadRequest] = [], issues: [String]) {
        self.files = files
        self.gdbLayers = gdbLayers
        self.issues = issues
    }

    var totalSources: Int { files.count + gdbLayers.count }
}

struct MapVectorSourceLoadProgress: Sendable {
    let completedFiles: Int
    let totalFiles: Int
    let currentSourceName: String?
    let issues: [String]
}

struct MapVectorSourceBatchLoadResult: Sendable {
    let layers: [MapVectorLayer]
    let issues: [String]
}

enum MapVectorSourceLoader {
    private static let mapTypes: [String: (kind: MapFeature.Kind, sourceClass: String)] = [
        "PointsVector": (.point, "PointMapLayerVisualContext"),
        "PolylinesVector": (.line, "PolylineMapLayerVisualContext"),
        "PolygonsVector": (.polygon, "PolygonMapLayerVisualContext")
    ]

    static func capture(nodes: [LayerTreeNode], mapID: UUID,
                        urlForNode: (LayerTreeNode) -> URL?) -> MapVectorSourceReadRequests {
        var candidates: [String: (url: URL, revision: String, identity: String,
                                  nodeIDs: [String], name: String)] = [:]
        var issues: [String] = []
        var conflictingPaths = Set<String>()
        var gdbLayers: [GdbMapVectorSourceReadRequest] = []
        var gdbNodeIDs = Set<String>()

        for node in nodes {
            guard let locator = node.sourceLocator else { continue }

            if locator.nodeType == "GdbVectorLayer" || locator.mapType == "GdbVectorLayer" {
                guard locator.nodeType == "GdbVectorLayer", locator.mapType == "GdbVectorLayer",
                      node.sourceClass == "GdbVectorLayerVisualContext",
                      !node.id.isEmpty, gdbNodeIDs.insert(node.id).inserted,
                      let url = urlForNode(node),
                      let layerName = node.properties.first(where: { $0.id == "Source/GdbLayerName" })?.value,
                      !layerName.isEmpty,
                      let vectorType = node.properties.first(where: { $0.id == "Source/GdbVectorType" })?.value,
                      GdbMapLayerDescriptor.featureKind(for: vectorType) != nil,
                      GdbFileGeodatabasePath.root(for: url) == url.standardizedFileURL.resolvingSymlinksInPath() else {
                    issues.append("\(node.name): the exact File Geodatabase layer identity is unavailable.")
                    continue
                }
                gdbLayers.append(.init(mapID: mapID, url: url, nodeID: node.id, locator: locator,
                    layerName: layerName, vectorType: vectorType, displayName: node.name))
                continue
            }

            guard locator.nodeType == "MapLayer",
                  let mapType = locator.mapType,
                  let expected = mapTypes[mapType] else { continue }

            guard node.sourceClass == expected.sourceClass,
                  !node.id.isEmpty,
                  let url = urlForNode(node),
                  node.diagnosticStatus == "loaded",
                  let identity = node.diagnosticSourceIdentity,
                  identity.hasPrefix("/"),
                  SourceFilePaths.canonical(URL(fileURLWithPath: identity)) == SourceFilePaths.canonical(url),
                  let revision = node.diagnosticSourceRevision,
                  revision.count == 64,
                  revision.allSatisfy(\.isHexDigit) else {
                issues.append("\(node.name): source identity or stable revision is unavailable.")
                continue
            }

            let path = SourceFilePaths.canonical(url)
            guard !conflictingPaths.contains(path) else { continue }
            if var existing = candidates[path] {
                guard existing.revision.caseInsensitiveCompare(revision) == .orderedSame,
                      SourceFilePaths.canonical(URL(fileURLWithPath: existing.identity)) == path else {
                    candidates.removeValue(forKey: path)
                    conflictingPaths.insert(path)
                    issues.append("\(node.name): source nodes disagree about the captured file revision.")
                    continue
                }
                existing.nodeIDs.append(node.id)
                candidates[path] = existing
            } else {
                candidates[path] = (url, revision.uppercased(), identity,
                                    [node.id], node.name)
            }
        }

        let files = candidates.values
            .sorted { SourceFilePaths.canonical($0.url) < SourceFilePaths.canonical($1.url) }
            .map { value in
                MapVectorSourceReadRequest(mapID: mapID, url: value.url,
                    sourceIdentity: SourceFilePaths.canonical(URL(fileURLWithPath: value.identity)),
                    sourceRevision: value.revision,
                    nodeIDs: Array(Set(value.nodeIDs)).sorted(), displayName: value.name)
            }
        return .init(files: files,
            gdbLayers: gdbLayers.sorted {
                ($0.canonicalPath, $0.nodeID) < ($1.canonicalPath, $1.nodeID)
            }, issues: issues)
    }

    /// Reads and parses each exact captured file once. Task cancellation is
    /// observed between files and after parsing; Foundation's synchronous file
    /// read and the GeoJSON parser cannot be interrupted in the middle of one
    /// source file, so callers must also refuse to install a cancelled result.
    static func load(_ requests: [MapVectorSourceReadRequest],
                     initialIssues: [String] = [],
                     progress: @Sendable (MapVectorSourceLoadProgress) -> Void = { _ in }) throws -> MapVectorSourceBatchLoadResult {
        var layers: [MapVectorLayer] = []
        var issues = initialIssues
        let total = requests.count
        var completed = 0
        progress(.init(completedFiles: completed, totalFiles: total,
                       currentSourceName: requests.first?.displayName, issues: issues))

        for request in requests {
            try Task.checkCancellation()
            do {
                let data = try Data(contentsOf: request.url, options: [.mappedIfSafe])
                try Task.checkCancellation()
                let observedRevision = digest(data)
                guard observedRevision.caseInsensitiveCompare(request.sourceRevision) == .orderedSame,
                      request.sourceIdentity == request.canonicalPath else {
                    throw SourceFileChangedException()
                }

                let layer = try MapVectorLayer(data: data, sourceURL: request.url)
                try Task.checkCancellation()
                guard layer.sourceRevision?.caseInsensitiveCompare(request.sourceRevision) == .orderedSame else {
                    throw SourceFileChangedException()
                }
                let latestRevision = digest(try Data(contentsOf: request.url, options: [.mappedIfSafe]))
                guard latestRevision.caseInsensitiveCompare(request.sourceRevision) == .orderedSame else {
                    throw SourceFileChangedException()
                }
                layers.append(layer)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                issues.append("\(request.displayName): \(error.localizedDescription)")
            }
            completed += 1
            progress(.init(completedFiles: completed, totalFiles: total,
                           currentSourceName: requests.dropFirst(completed).first?.displayName,
                           issues: issues))
        }
        try Task.checkCancellation()
        return .init(layers: layers, issues: issues)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }
}

struct SourceMapVectorLoadProgressView: View {
    @ObservedObject var store: WorkspaceStore
    let mapID: UUID

    private var load: MapVectorLoadState? { store.sourceMapVectorLoadStates[mapID] }

    var body: some View {
        if let load, load.isActive {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Loading map vectors…").font(.callout.weight(.medium))
                    Spacer()
                    if load.totalFiles > 0 {
                        Text("\(load.completedFiles) / \(load.totalFiles)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                ProgressView(value: load.fraction)
                if let current = load.currentSourceName {
                    Text(current).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack {
                    if load.phase == .cancelling {
                        Label("Stopping after current file…", systemImage: "hourglass")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Cancel") { store.cancelSourceMapVectorLoad(mapID: mapID) }
                        .disabled(load.phase == .cancelling)
                }
            }
            .padding(12)
            .workspaceGlass()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("source-map-vector-load-progress")
        }
    }
}

private struct SourceFileChangedException: Error, LocalizedError {
    var errorDescription: String? { "The vector source changed after the map tree captured it." }
}
