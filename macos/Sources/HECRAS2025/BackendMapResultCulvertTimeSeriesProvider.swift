import CryptoKit
import Foundation
import RASWorkspaceCore

@MainActor
final class BackendMapResultCulvertTimeSeriesProvider {
    private let client: BackendProcessClient

    init(client: BackendProcessClient? = nil) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
    }

    func load(_ route: MapResultCulvertTimeSeriesWindowRoute,
              isCurrent: @MainActor () -> Bool) async throws -> MapResultCulvertTimeSeriesSnapshot {
        guard isCurrent(), !Task.isCancelled else { throw MapResultCulvertTimeSeriesError.staleContext }
        let request = route.request
        let resultURL = URL(fileURLWithPath: request.resultOwner.selectedResultPath)
        let projectURL = URL(fileURLWithPath: request.map.projectPath)
        let visualizationURL = projectURL.deletingPathExtension().appendingPathExtension("vis")
        guard FileManager.default.fileExists(atPath: resultURL.path),
              FileManager.default.fileExists(atPath: projectURL.path),
              FileManager.default.fileExists(atPath: visualizationURL.path) else {
            throw MapResultCulvertTimeSeriesError.sourceChanged
        }

        let resultBefore = try await revision(at: resultURL)
        let projectBefore = try await revision(at: projectURL)
        let visualizationBefore = try await revision(at: visualizationURL)
        guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
        guard Self.sameRevision(resultBefore, request.resultOwner.selectedResultRevision),
              Self.sameRevision(projectBefore, route.expectedProjectRevision),
              Self.sameRevision(visualizationBefore, request.map.expectedVisualizationRevision) else {
            throw MapResultCulvertTimeSeriesError.sourceChanged
        }

        let snapshot: MapResultCulvertTimeSeriesSnapshot = try await client.request(
            "map.result.culvertTimeSeries", parameters: request,
            as: MapResultCulvertTimeSeriesSnapshot.self)
        guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
        try Self.validate(snapshot, route: route)

        let resultAfter = try await revision(at: resultURL)
        let projectAfter = try await revision(at: projectURL)
        let visualizationAfter = try await revision(at: visualizationURL)
        guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
        guard Self.sameRevision(resultAfter, resultBefore),
              Self.sameRevision(projectAfter, projectBefore),
              Self.sameRevision(visualizationAfter, visualizationBefore) else {
            throw MapResultCulvertTimeSeriesError.sourceChanged
        }
        return snapshot
    }

    func currentSourcesMatch(_ route: MapResultCulvertTimeSeriesWindowRoute) async -> Bool {
        let request = route.request
        let resultURL = URL(fileURLWithPath: request.resultOwner.selectedResultPath)
        let projectURL = URL(fileURLWithPath: request.map.projectPath)
        let visualizationURL = projectURL.deletingPathExtension().appendingPathExtension("vis")
        guard FileManager.default.fileExists(atPath: resultURL.path),
              FileManager.default.fileExists(atPath: projectURL.path),
              FileManager.default.fileExists(atPath: visualizationURL.path) else { return false }
        do {
            async let result = revision(at: resultURL)
            async let project = revision(at: projectURL)
            async let visualization = revision(at: visualizationURL)
            let (resultRevision, projectRevision, visualizationRevision) = try await
                (result, project, visualization)
            return Self.sameRevision(resultRevision, request.resultOwner.selectedResultRevision)
                && Self.sameRevision(projectRevision, route.expectedProjectRevision)
                && Self.sameRevision(visualizationRevision, request.map.expectedVisualizationRevision)
        } catch {
            return false
        }
    }

    static func validate(_ snapshot: MapResultCulvertTimeSeriesSnapshot,
                         route: MapResultCulvertTimeSeriesWindowRoute) throws {
        let request = route.request
        let map = request.map
        let owner = request.resultOwner
        let expectedResultPath = canonical(owner.selectedResultPath)
        guard canonical(snapshot.projectCanonicalPath) == canonical(map.projectPath),
              sameRevision(snapshot.projectRevision, route.expectedProjectRevision),
              sameRevision(snapshot.projectXmlSHA, map.projectXmlSHA),
              sameRevision(snapshot.visualizationRevision, map.expectedVisualizationRevision),
              snapshot.coreLayerContextIdentity == (map.coreLayerContext?.identityToken ?? ""),
              snapshot.mapID.caseInsensitiveCompare(map.mapID) == .orderedSame,
              snapshot.mapIndex == map.mapIndex,
              snapshot.mapName == map.mapName,
              snapshot.mapType == map.mapType,
              snapshot.contextToken == owner.contextToken,
              snapshot.resultNode == owner.resultNode,
              snapshot.selectionIndex == 0,
              canonical(snapshot.selectedResultPath) == expectedResultPath,
              sameRevision(snapshot.selectedResultRevision, owner.selectedResultRevision),
              snapshot.variable == request.variable,
              ((request.variable == "Flow" && ["CFS", "CMS"].contains(snapshot.units))
                || (request.variable == "Velocity" && ["ft/s", "m/s"].contains(snapshot.units))),
              !snapshot.times.isEmpty,
              snapshot.noDataValue == -9999,
              snapshot.datasets.count == route.expectedBarrels.count,
              zip(snapshot.datasets, route.expectedBarrels).allSatisfy({ pair in
                  let (dataset, barrel) = pair
                  return dataset.id == barrel.id
                      && dataset.sourceOrdinal == barrel.sourceOrdinal
                      && dataset.name == barrel.name
                      && dataset.colorRGBA.count == 8
                      && UInt32(dataset.colorRGBA, radix: 16) != nil
                      && dataset.strokeWidth.isFinite && dataset.strokeWidth > 0
                      && dataset.values.count == snapshot.times.count
                      && dataset.values.allSatisfy(\.isFinite)
              }) else {
            throw MapResultCulvertTimeSeriesError.mismatchedReply
        }
        guard snapshot.times.allSatisfy({ MapResultCulvertTimeSeriesChartData.isValidSourceDate($0) }) else {
            throw MapResultCulvertTimeSeriesError.invalidReply
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

    private static func canonical(_ path: String) -> String {
        SourceFilePaths.canonical(URL(fileURLWithPath: path))
    }

    private static func sameRevision(_ left: String, _ right: String) -> Bool {
        left.caseInsensitiveCompare(right) == .orderedSame
    }
}
