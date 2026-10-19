import CryptoKit
import Foundation
import RASWorkspaceCore

@MainActor
protocol AssociatedMapLayerProvider {
    func load(_ request: AssociatedMapLayersRequest,
              captures: [AssociatedMapLayerCapture]) async throws -> AssociatedMapLayersSnapshot
}

@MainActor
final class BackendAssociatedMapLayerProvider: AssociatedMapLayerProvider {
    private let client: BackendProcessClient
    private let isCurrent: @MainActor () -> Bool
    private var verifiedProjectRevision: String?

    init(client: BackendProcessClient? = nil,
         isCurrent: @escaping @MainActor () -> Bool = { true }) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
        self.isCurrent = isCurrent
    }

    func load(_ request: AssociatedMapLayersRequest,
              captures: [AssociatedMapLayerCapture]) async throws -> AssociatedMapLayersSnapshot {
        guard isCurrent(), !Task.isCancelled,
              Self.requestMatchesCaptures(request, captures: captures) else {
            throw AssociatedMapLayerError.staleContext
        }
        let snapshot: AssociatedMapLayersSnapshot = try await client.request(
            "map.associations.load", parameters: request, as: AssociatedMapLayersSnapshot.self)
        guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
        try await validate(snapshot, request: request, captures: captures)
        guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
        return snapshot
    }

    private func validate(_ snapshot: AssociatedMapLayersSnapshot,
                          request: AssociatedMapLayersRequest,
                          captures: [AssociatedMapLayerCapture]) async throws {
        let map = request.map
        guard snapshot.mapID == map.mapID,
              snapshot.mapIndex == map.mapIndex,
              snapshot.mapName == map.mapName,
              snapshot.mapType == map.mapType,
              SourceFilePaths.canonical(URL(fileURLWithPath: snapshot.projectCanonicalPath))
                == SourceFilePaths.canonical(URL(fileURLWithPath: map.projectPath)),
              Self.isSHA256(snapshot.projectRevision),
              Self.isSHA256(snapshot.projectXmlSHA),
              snapshot.projectXmlSHA.caseInsensitiveCompare(map.projectXmlSHA) == .orderedSame,
              Self.isSHA256(snapshot.visualizationRevision),
              snapshot.visualizationRevision.caseInsensitiveCompare(map.expectedVisualizationRevision)
                == .orderedSame,
              !snapshot.contextToken.isEmpty,
              snapshot.viewport == request.viewport,
              request.viewport.isFiniteAndOrdered,
              !captures.isEmpty,
              snapshot.layers.map(\.locator) == captures.map(\.associationNode),
              Self.uniqueLocators(snapshot.layers.map(\.locator)),
              snapshot.layers.count == captures.count else {
            throw AssociatedMapLayerError.mismatchedReply
        }
        if let expected = request.contextToken, snapshot.contextToken != expected {
            throw AssociatedMapLayerError.sourceChanged
        }
        if let verifiedProjectRevision,
           verifiedProjectRevision.caseInsensitiveCompare(snapshot.projectRevision) != .orderedSame {
            throw AssociatedMapLayerError.sourceChanged
        }
        self.verifiedProjectRevision = snapshot.projectRevision

        let captureByLocator = Dictionary(uniqueKeysWithValues: captures.map { ($0.associationNode, $0) })
        let requestedGeometryNodes = Set(request.geometryNodes)
        let requestedPlanNodes = Set(request.planNodes)
        let requestedResultOwnerIDs = Set(request.resultOwners.map(\.identity))
        let rasterOptionsByLocator = Dictionary(uniqueKeysWithValues:
            request.rasterRuntimeOptions.map { ($0.locator, $0) })
        for layer in snapshot.layers {
            guard let capture = captureByLocator[layer.locator],
                  let requestedKind = AssociatedMapLayerCapture.supportedKind(capture.associationNode.associationKind),
                  layer.kind == requestedKind,
                  layer.plotRasterTileOutlines == Self.expectedTileOutlineValue(
                    for: capture, options: rasterOptionsByLocator),
                  SourceFilePaths.canonical(URL(fileURLWithPath: layer.assetPath)) == capture.assetPath,
                  layer.isChecked == capture.isChecked,
                  layer.effectiveVisible == capture.effectiveVisible,
                  layer.sourceExtent == nil || layer.sourceExtent?.hasFinitePositiveArea == true,
                  layer.width == request.width, layer.height == request.height,
                  Self.uniqueLocators(layer.geometryNodes),
                  layer.geometryNodes.allSatisfy(requestedGeometryNodes.contains),
                  Self.uniqueLocators(layer.planNodes),
                  layer.planNodes.allSatisfy(requestedPlanNodes.contains),
                  Self.uniqueOwners(layer.resultOwners),
                  layer.resultOwners.allSatisfy({ requestedResultOwnerIDs.contains($0.identity) }),
                  Self.isOrderedSubset(layer.geometryNodes, of: capture.geometryNodes),
                  Self.isOrderedSubset(layer.planNodes, of: capture.planNodes),
                  Self.isOrderedOwnerSubset(layer.resultOwners, of: capture.resultOwners),
                  Self.validRevision(layer.revision, allowingMissing: layer.status == .unavailable || layer.status == .failed),
                  Self.validLegend(layer.legend),
                  Self.validDependencies(layer.dependencies) else {
                throw AssociatedMapLayerError.mismatchedReply
            }

            let sourceDependencies = layer.dependencies.filter { $0.role == "source-hdf" }
            guard sourceDependencies.count == 1,
                  SourceFilePaths.canonical(URL(fileURLWithPath: sourceDependencies[0].path)) == capture.assetPath,
                  sourceDependencies[0].revision.caseInsensitiveCompare(layer.revision) == .orderedSame else {
                throw AssociatedMapLayerError.mismatchedReply
            }

            switch layer.status {
            case .available:
                let pixelCount = request.width.multipliedReportingOverflow(by: request.height)
                let byteCount = pixelCount.partialValue.multipliedReportingOverflow(by: 4)
                guard capture.isChecked, capture.effectiveVisible,
                      !layer.geometryNodes.isEmpty || !layer.planNodes.isEmpty || !layer.resultOwners.isEmpty,
                      !pixelCount.overflow, !byteCount.overflow,
                      layer.rgba.count == byteCount.partialValue,
                      Self.isSHA256(layer.revision) else {
                    throw AssociatedMapLayerError.invalidRaster
                }
            case .hidden:
                guard layer.rgba.isEmpty,
                      !layer.isChecked || !layer.effectiveVisible else {
                    throw AssociatedMapLayerError.invalidRaster
                }
            case .empty, .unavailable, .failed:
                guard layer.rgba.isEmpty else { throw AssociatedMapLayerError.invalidRaster }
            }
            try await verifyDependencies(layer.dependencies)
        }
        try await verifyResultOwners(Self.uniqueOwnersInOrder(snapshot.layers.flatMap(\.resultOwners)))
    }

    private func verifyDependencies(_ dependencies: [AssociatedMapLayerDependency]) async throws {
        for dependency in dependencies {
            guard URL(fileURLWithPath: dependency.path).isFileURL,
                  dependency.path.hasPrefix("/"),
                  Self.validRevision(dependency.revision, allowingMissing: true) else {
                throw AssociatedMapLayerError.mismatchedReply
            }
            let canonicalPath = SourceFilePaths.canonical(URL(fileURLWithPath: dependency.path))
            let actualRevision = try await Self.sourceRevision(at: URL(fileURLWithPath: canonicalPath))
            guard actualRevision.caseInsensitiveCompare(dependency.revision) == .orderedSame else {
                throw AssociatedMapLayerError.sourceChanged
            }
        }
    }

    private static func requestMatchesCaptures(_ request: AssociatedMapLayersRequest,
                                               captures: [AssociatedMapLayerCapture]) -> Bool {
        guard let first = captures.first,
              captures.allSatisfy({ $0.map == request.map
                  && $0.mapID == first.mapID
                  && $0.projectSessionID == first.projectSessionID
                  && $0.mapWorkflowIdentity == first.mapWorkflowIdentity }),
              request.map.mapID == first.mapID.uuidString,
              request.associationNodes == captures.map(\.associationNode),
              uniqueLocators(request.associationNodes) else { return false }
        let expectedGeometryNodes = uniqueInOrder(captures.flatMap(\.geometryNodes))
        let expectedPlanNodes = uniqueInOrder(captures.flatMap(\.planNodes))
        let expectedResultOwners = uniqueOwnersInOrder(captures.flatMap(\.resultOwners))
        let captureByLocator = Dictionary(uniqueKeysWithValues: captures.map { ($0.associationNode, $0) })
        let optionsMatch = uniqueLocators(request.rasterRuntimeOptions.map(\.locator))
            && request.rasterRuntimeOptions.allSatisfy { option in
                guard let capture = captureByLocator[option.locator] else { return false }
                return option.matches(capture)
            }
        return request.geometryNodes == expectedGeometryNodes
            && request.planNodes == expectedPlanNodes
            && request.resultOwners.map(\.identity) == expectedResultOwners.map(\.identity)
            && uniqueLocators(request.geometryNodes)
            && uniqueLocators(request.planNodes)
            && uniqueOwners(request.resultOwners)
            && optionsMatch
    }

    private static func expectedTileOutlineValue(
        for capture: AssociatedMapLayerCapture,
        options: [CatalogTreeNodeLocator: AssociatedMapLayerRasterRuntimeOption]
    ) -> Bool? {
        guard let kind = capture.associationNode.associationKind else { return nil }
        guard kind == "Terrain" || kind == "NValue" else { return nil }
        return options[capture.associationNode]?.plotRasterTileOutlines ?? false
    }

    private static func uniqueLocators(_ values: [CatalogTreeNodeLocator]) -> Bool {
        Set(values).count == values.count
    }

    private static func uniqueOwners(_ values: [MapResultGeometryOwner]) -> Bool {
        Set(values.map(\.identity)).count == values.count
    }

    private static func isOrderedSubset<T: Equatable>(_ values: [T], of source: [T]) -> Bool {
        var nextIndex = source.startIndex
        for value in values {
            guard nextIndex < source.endIndex,
                  let match = source[nextIndex...].firstIndex(of: value) else { return false }
            nextIndex = source.index(after: match)
        }
        return true
    }

    private static func isOrderedOwnerSubset(_ values: [MapResultGeometryOwner],
                                             of source: [MapResultGeometryOwner]) -> Bool {
        isOrderedSubset(values.map(\.identity), of: source.map(\.identity))
    }

    private static func uniqueInOrder<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func uniqueOwnersInOrder(_ values: [MapResultGeometryOwner]) -> [MapResultGeometryOwner] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.identity).inserted }
    }

    private func verifyResultOwners(_ owners: [MapResultGeometryOwner]) async throws {
        for owner in owners {
            let url = URL(fileURLWithPath: owner.selectedResultPath)
            let current = try await Self.sourceRevision(at: url)
            guard current.caseInsensitiveCompare(owner.selectedResultRevision) == .orderedSame else {
                throw AssociatedMapLayerError.sourceChanged
            }
        }
    }

    private static func validDependencies(_ values: [AssociatedMapLayerDependency]) -> Bool {
        let keys = values.map { "\($0.role.utf8.count):\($0.role)|\($0.path.utf8.count):\($0.path)" }
        return !values.isEmpty && Set(keys).count == keys.count
            && values.allSatisfy { !$0.role.isEmpty && !$0.path.isEmpty
                && validRevision($0.revision, allowingMissing: true) }
    }

    private static func validLegend(_ values: [AssociatedMapLayerLegendValue]) -> Bool {
        Set(values.map(\.id)).count == values.count
            && values.allSatisfy { (0...255).contains($0.red) && (0...255).contains($0.green)
                && (0...255).contains($0.blue) && (0...255).contains($0.alpha) }
    }

    private static func validRevision(_ value: String, allowingMissing: Bool) -> Bool {
        (allowingMissing && value == "missing") || isSHA256(value)
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value == value.uppercased()
            && value.allSatisfy { $0.isHexDigit }
    }

    private static func sourceRevision(at url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: url.path) else { return "missing" }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            return SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
        }.value
    }
}

enum AssociatedMapLayerError: Error, LocalizedError {
    case staleContext
    case mismatchedReply
    case sourceChanged
    case invalidRaster

    var errorDescription: String? {
        switch self {
        case .staleContext:
            "The selected saved map changed before associated layers could be loaded."
        case .mismatchedReply:
            "The associated layer reply no longer matches the selected map tree."
        case .sourceChanged:
            "An associated map source changed while its raster was loading. Refresh the map layers."
        case .invalidRaster:
            "The associated map service returned invalid raster data."
        }
    }
}
