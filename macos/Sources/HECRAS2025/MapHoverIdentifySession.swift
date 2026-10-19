import Foundation
import RASWorkspaceCore
import SwiftUI

@MainActor
final class MapHoverIdentifySession: ObservableObject {
    @Published private(set) var response: MapHoverIdentifyResult?
    @Published private(set) var screenPoint: CGPoint?
    @Published private(set) var entries: [MapHoverIdentifyEntry] = []

    private let provider: any MapHoverIdentifyProviding
    private let debounceNanoseconds: UInt64
    private var generation: UInt64 = 0
    private var activeTask: Task<Void, Never>?

    init(provider: any MapHoverIdentifyProviding = BackendMapHoverIdentifyProvider(),
         debounceNanoseconds: UInt64 = 65_000_000) {
        self.provider = provider
        self.debounceNanoseconds = debounceNanoseconds
    }

    func update(_ flight: MapHoverIdentifyFlight,
                currentSourceIdentity: @escaping @MainActor () -> String?) {
        generation &+= 1
        let requestGeneration = generation
        activeTask?.cancel()
        response = nil
        screenPoint = CGPoint(x: flight.screenX, y: flight.screenY)
        entries = flight.localEntries

        guard currentSourceIdentity() == flight.sourceIdentity else {
            entries = []
            return
        }
        guard !flight.request.layers.isEmpty else { return }

        activeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if debounceNanoseconds > 0 {
                    try await Task.sleep(nanoseconds: debounceNanoseconds)
                }
                guard !Task.isCancelled, generation == requestGeneration else { return }
                guard currentSourceIdentity() == flight.sourceIdentity else {
                    entries = []
                    return
                }
                let result = try await provider.identify(flight.request)
                guard !Task.isCancelled, generation == requestGeneration else { return }
                guard currentSourceIdentity() == flight.sourceIdentity else {
                    response = nil
                    entries = []
                    return
                }
                guard Self.response(result, matches: flight.request) else { return }
                response = result
                entries = flight.localEntries + result.entries
            } catch {
                guard generation == requestGeneration else { return }
                response = nil
                entries = currentSourceIdentity() == flight.sourceIdentity ? flight.localEntries : []
            }
        }
    }

    func cancel() {
        generation &+= 1
        activeTask?.cancel()
        activeTask = nil
        response = nil
        screenPoint = nil
        entries = []
    }

    private static func response(_ result: MapHoverIdentifyResult,
                                 matches request: MapHoverIdentifyRequest) -> Bool {
        guard result.requestID == request.requestID,
              samePath(result.projectPath, request.map.projectPath),
              !result.projectRevision.isEmpty,
              result.projectXmlSHA.caseInsensitiveCompare(request.map.projectXmlSHA) == .orderedSame,
              result.visualizationRevision.caseInsensitiveCompare(request.map.expectedVisualizationRevision) == .orderedSame,
              result.mapID.caseInsensitiveCompare(request.map.mapID) == .orderedSame,
              result.mapIndex == request.map.mapIndex,
              result.mapName == request.map.mapName,
              result.mapType == request.map.mapType,
              result.contextToken == request.contextToken,
              result.point == request.point else { return false }

        for entry in result.entries {
            let matches = request.layers.filter { capture in
                guard capture.node == entry.node, capture.kind == entry.kind else { return false }
                switch capture.kind {
                case "result":
                    return capture.mapType == entry.mapType
                        && capture.profileIndex == entry.profileIndex
                        && (capture.resultSelections ?? []).contains { selected in
                            samePath(selected.resultPath, entry.sourcePath ?? "")
                                && selected.resultRevision.caseInsensitiveCompare(entry.sourceRevision ?? "") == .orderedSame
                        }
                case "terrain", "nvalue", "classification", "raster":
                    return capture.sourcePath.map { samePath($0, entry.sourcePath ?? "") } == true
                        && capture.sourceRevision?.caseInsensitiveCompare(entry.sourceRevision ?? "") == .orderedSame
                        && (capture.mapType == nil || capture.mapType == entry.mapType)
                case "mesh":
                    return capture.mesh.map { mesh in
                        samePath(mesh.sourcePath, entry.sourcePath ?? "")
                            && mesh.sourceRevision.caseInsensitiveCompare(entry.sourceRevision ?? "") == .orderedSame
                            && (mesh.resultOwner == nil || mesh.resultOwner?.selectedResultRevision
                                .caseInsensitiveCompare(entry.sourceRevision ?? "") == .orderedSame)
                    } == true
                default:
                    return false
                }
            }
            guard matches.count == 1 else { return false }
        }
        return true
    }

    private static func samePath(_ lhs: String, _ rhs: String) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        return SourceFilePaths.canonical(URL(fileURLWithPath: lhs))
            == SourceFilePaths.canonical(URL(fileURLWithPath: rhs))
    }
}
