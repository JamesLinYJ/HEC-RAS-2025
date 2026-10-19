import CryptoKit
import Foundation
import RASWorkspaceCore

@MainActor
final class BackendBoundaryLineTimeSeriesProvider {
    private let client: BackendProcessClient

    init(client: BackendProcessClient? = nil) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
    }

    func load(_ route: BoundaryLineTimeSeriesWindowRoute,
              isCurrent: @MainActor () -> Bool) async throws -> MapBoundaryLineTimeSeriesSnapshot {
        guard isCurrent(), !Task.isCancelled else { throw BoundaryMapError.staleContext }
        let resultURL = URL(fileURLWithPath: route.request.resultOwner.selectedResultPath)
        let projectURL = URL(fileURLWithPath: SourceFilePaths.canonical(
            URL(fileURLWithPath: route.request.map.projectPath)))
        let protectedPaths = route.request.map.computeReadLease?.canonicalProtectedSourcePaths ?? []
        guard !protectedPaths.contains(SourceFilePaths.canonical(resultURL)) else {
            throw BoundaryMapError.staleContext
        }

        let resultBefore = try await revision(at: resultURL)
        let projectBefore = try await revision(at: projectURL)
        guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
        guard Self.sameRevision(resultBefore, route.request.expectedBoundaryRevision),
              Self.isSHA256(projectBefore) else { throw BoundaryMapError.sourceChanged }

        let snapshot: MapBoundaryLineTimeSeriesSnapshot = try await client.request(
            "map.boundary.lineTimeSeries", parameters: route.request,
            as: MapBoundaryLineTimeSeriesSnapshot.self)
        guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
        try validate(snapshot, route: route, projectRevision: projectBefore)

        let resultAfter = try await revision(at: resultURL)
        let projectAfter = try await revision(at: projectURL)
        guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
        guard Self.sameRevision(resultAfter, resultBefore),
              Self.sameRevision(projectAfter, projectBefore) else {
            throw BoundaryMapError.sourceChanged
        }
        return snapshot
    }

    private func validate(_ snapshot: MapBoundaryLineTimeSeriesSnapshot,
                          route: BoundaryLineTimeSeriesWindowRoute,
                          projectRevision: String) throws {
        let request = route.request
        let map = request.map
        let resultPath = SourceFilePaths.canonical(URL(fileURLWithPath: request.resultOwner.selectedResultPath))
        guard SourceFilePaths.canonical(URL(fileURLWithPath: snapshot.projectCanonicalPath))
                == SourceFilePaths.canonical(URL(fileURLWithPath: map.projectPath)),
              Self.sameRevision(snapshot.projectRevision, projectRevision),
              snapshot.projectXmlSHA?.caseInsensitiveCompare(map.projectXmlSHA) == .orderedSame,
              Self.sameRevision(snapshot.visualizationRevision, map.expectedVisualizationRevision),
              snapshot.mapID.caseInsensitiveCompare(map.mapID) == .orderedSame,
              snapshot.mapIndex == map.mapIndex, snapshot.mapName == map.mapName,
              snapshot.mapType == map.mapType,
              snapshot.resultContextToken == request.resultOwner.contextToken,
              snapshot.boundaryContextToken == request.expectedBoundaryContextToken,
              snapshot.boundaryNode == request.boundaryNode,
              SourceFilePaths.canonical(URL(fileURLWithPath: snapshot.boundaryPath)) == resultPath,
              Self.sameRevision(snapshot.boundaryRevision, request.expectedBoundaryRevision),
              snapshot.resultOwner.matches(request.resultOwner),
              snapshot.variable == request.variable,
              validDatasets(snapshot.datasets, route: route) else {
            throw BoundaryMapError.mismatchedReply
        }
    }

    private func validDatasets(_ datasets: [MapBoundaryLineTimeSeriesDataset],
                               route: BoundaryLineTimeSeriesWindowRoute) -> Bool {
        let expected = Dictionary(uniqueKeysWithValues: route.expectedLines.map { ($0.id, $0.sourceOrdinal) })
        var ids = Set<String>()
        return datasets.allSatisfy { dataset in
            guard ids.insert(dataset.id).inserted,
                  let line = route.expectedLines.first(where: { dataset.id.hasPrefix($0.id + "/") }),
                  dataset.sourceOrdinal == expected[line.id],
                  dataset.name.isEmpty == false,
                  ["Simulated", "Payload"].contains(dataset.kind),
                  dataset.colorRGBA.count == 8,
                  UInt32(dataset.colorRGBA, radix: 16) != nil,
                  dataset.strokeWidth.isFinite, dataset.strokeWidth > 0,
                  dataset.kind != "Simulated" || dataset.id == line.id + "/simulated",
                  dataset.kind != "Payload" || dataset.id.hasPrefix(line.id + "/payload/") else {
                return false
            }
            return true
        }
    }

    private func revision(at url: URL) async throws -> String {
        let worker = Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: bytes)
            }
            return hasher.finalize().map { String(format: "%02X", $0) }.joined()
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func sameRevision(_ left: String, _ right: String) -> Bool {
        left.caseInsensitiveCompare(right) == .orderedSame
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }
}
