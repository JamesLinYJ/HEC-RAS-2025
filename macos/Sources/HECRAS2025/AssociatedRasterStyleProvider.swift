import CryptoKit
import Foundation
import RASWorkspaceCore

@MainActor
final class BackendAssociatedRasterStyleProvider: AssociatedRasterStyleProvider {
    typealias CurrentCheck = @MainActor (AssociatedRasterStyleContext) -> Bool
    typealias RefreshContext = @MainActor (AssociatedRasterStyleContext) async throws -> AssociatedRasterStyleContext?
    typealias BeginMutation = @MainActor () -> Bool
    typealias EndMutation = @MainActor () -> Void
    typealias AcceptMapChange = @MainActor (String?, String) throws -> Void

    private let client: BackendProcessClient
    private let isCurrent: CurrentCheck
    private let refreshContext: RefreshContext
    private let beginMutation: BeginMutation
    private let endMutation: EndMutation
    private let acceptMapChange: AcceptMapChange

    init(client: BackendProcessClient? = nil,
         isCurrent: @escaping CurrentCheck,
         refreshContext: @escaping RefreshContext,
         beginMutation: @escaping BeginMutation,
         endMutation: @escaping EndMutation,
         acceptMapChange: @escaping AcceptMapChange) {
        self.client = client ?? BackendProcessClient(executableURL: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Backend/HECRASBackend"))
        self.isCurrent = isCurrent
        self.refreshContext = refreshContext
        self.beginMutation = beginMutation
        self.endMutation = endMutation
        self.acceptMapChange = acceptMapChange
    }

    func load(_ context: AssociatedRasterStyleContext,
              contextToken: String?) async throws -> AssociatedRasterStyleSnapshot {
        try requireCurrent(context)
        try await verifySourceRevision(context)
        let request = AssociatedRasterStyleLoadRequest(map: context.map,
            node: context.node, sourcePath: context.sourcePath,
            sourceRevision: context.sourceRevision, contextToken: contextToken,
            geometryNodes: context.geometryNodes, planNodes: context.planNodes,
            resultOwner: context.resultOwner)
        let snapshot: AssociatedRasterStyleSnapshot = try await client.request(
            "map.associationStyle.load", parameters: request,
            as: AssociatedRasterStyleSnapshot.self)
        try requireCurrent(context)
        try validate(snapshot, context: context)
        try await verifyDependencies(snapshot.dependencies, sourcePath: context.sourcePath,
            sourceRevision: context.sourceRevision, context: context)
        return snapshot
    }

    func apply(_ context: AssociatedRasterStyleContext,
               snapshot: AssociatedRasterStyleSnapshot,
               draft: AssociatedRasterStyleDraft,
               paletteMutation: AssociatedRasterStylePaletteMutation?) async throws
        -> AssociatedRasterStyleLoadedState {
        try requireCurrent(context)
        try validate(snapshot, context: context)
        guard snapshot.sourceRevision.caseInsensitiveCompare(context.sourceRevision) == .orderedSame else {
            throw AssociatedRasterStyleError.sourceChanged
        }
        try await verifyDependencies(snapshot.dependencies, sourcePath: context.sourcePath,
            sourceRevision: context.sourceRevision, context: context)
        guard beginMutation() else { throw AssociatedRasterStyleError.mutationUnavailable }
        defer { endMutation() }

        // A writer may wait for an in-flight map edit, so revalidate the exact
        // context and bytes after the lease has actually been acquired.
        try requireCurrent(context)
        try await verifyDependencies(snapshot.dependencies, sourcePath: context.sourcePath,
            sourceRevision: context.sourceRevision, context: context)
        let request = AssociatedRasterStyleApplyRequest(map: context.map,
            node: context.node, sourcePath: context.sourcePath,
            sourceRevision: context.sourceRevision,
            expectedContextToken: snapshot.contextToken,
            draft: draft, paletteMutation: paletteMutation,
            geometryNodes: context.geometryNodes, planNodes: context.planNodes,
            resultOwner: context.resultOwner)
        let result: AssociatedRasterStyleApplyResult = try await client.request(
            "map.associationStyle.apply", parameters: request,
            as: AssociatedRasterStyleApplyResult.self)

        // The .vis file is already committed by the Host. Accept its exact
        // old/new revisions before refreshing; never report a published write
        // as failed because an unrelated project-draft edit happened meanwhile.
        guard result.previousVisualizationRevision.caseInsensitiveCompare(
                context.map.expectedVisualizationRevision) == .orderedSame,
              Self.isSHA256(result.visualizationRevision),
              result.sourceRevision.caseInsensitiveCompare(context.sourceRevision) == .orderedSame else {
            throw AssociatedRasterStyleError.mismatchedReply
        }
        try acceptMapChange(result.previousVisualizationRevision, result.visualizationRevision)
        guard let refreshed = try await refreshContext(context) else {
            throw AssociatedRasterStyleError.staleContext
        }
        guard Self.sameOwnerOrMaterializedNode(context, refreshed),
              refreshed.map.expectedVisualizationRevision.caseInsensitiveCompare(
                result.visualizationRevision) == .orderedSame else {
            throw AssociatedRasterStyleError.staleContext
        }
        try requireCurrent(refreshed)
        try await verifySourceRevision(refreshed)

        let refreshedSnapshot = try await load(refreshed, contextToken: nil)
        guard Self.sameOwnerOrMaterializedNode(context, refreshed),
              refreshedSnapshot.visualizationRevision.caseInsensitiveCompare(
                result.visualizationRevision) == .orderedSame else {
            throw AssociatedRasterStyleError.staleContext
        }
        return AssociatedRasterStyleLoadedState(context: refreshed, snapshot: refreshedSnapshot)
    }

    private func requireCurrent(_ context: AssociatedRasterStyleContext) throws {
        guard !Task.isCancelled, isCurrent(context) else {
            throw AssociatedRasterStyleError.staleContext
        }
    }

    private func validate(_ snapshot: AssociatedRasterStyleSnapshot,
                          context: AssociatedRasterStyleContext) throws {
        guard ["Terrain", "NValue"].contains(snapshot.sourceKind),
              snapshot.sourceKind == context.node.nodeType,
              SourceFilePaths.canonical(URL(fileURLWithPath: snapshot.sourcePath)) == context.sourcePath,
              snapshot.mapID == context.map.mapID,
              snapshot.mapIndex == context.map.mapIndex,
              snapshot.mapName == context.map.mapName,
              snapshot.mapType == context.map.mapType,
              SourceFilePaths.canonical(URL(fileURLWithPath: snapshot.projectCanonicalPath))
                == SourceFilePaths.canonical(URL(fileURLWithPath: context.map.projectPath)),
              snapshot.projectXmlSHA.caseInsensitiveCompare(context.map.projectXmlSHA) == .orderedSame,
              snapshot.node == context.node,
              snapshot.geometryNodes == context.geometryNodes,
              snapshot.planNodes == context.planNodes,
              Self.sameResultOwner(snapshot.resultOwner, context.resultOwner),
              Self.isSHA256(snapshot.sourceRevision),
              snapshot.sourceRevision.caseInsensitiveCompare(context.sourceRevision) == .orderedSame,
              Self.isSHA256(snapshot.visualizationRevision),
              snapshot.visualizationRevision.caseInsensitiveCompare(
                context.map.expectedVisualizationRevision) == .orderedSame,
              !snapshot.contextToken.isEmpty,
              Self.valid(dependencies: snapshot.dependencies,
                  sourcePath: context.sourcePath, sourceRevision: context.sourceRevision),
              Self.valid(draft: snapshot.draft),
              Self.valid(draft: snapshot.resetDraft),
              snapshot.palettes.allSatisfy(Self.valid(palette:)),
              Set(snapshot.palettes.map(\.id)).count == snapshot.palettes.count,
              snapshot.sourceHistogramValues?.allSatisfy(\.isFinite) ?? true else {
            throw AssociatedRasterStyleError.mismatchedReply
        }
    }

    private func verifySourceRevision(_ context: AssociatedRasterStyleContext) async throws {
        let url = URL(fileURLWithPath: context.sourcePath)
        let actual = try await Self.sourceRevision(at: url)
        guard actual.caseInsensitiveCompare(context.sourceRevision) == .orderedSame else {
            throw AssociatedRasterStyleError.sourceChanged
        }
        try requireCurrent(context)
    }

    private func verifyDependencies(_ dependencies: [AssociatedRasterStyleDependency],
                                    sourcePath: String,
                                    sourceRevision: String,
                                    context: AssociatedRasterStyleContext) async throws {
        guard Self.valid(dependencies: dependencies, sourcePath: sourcePath,
                         sourceRevision: sourceRevision) else {
            throw AssociatedRasterStyleError.mismatchedReply
        }
        for dependency in dependencies {
            if dependency.revision == "missing" {
                if !dependency.path.isEmpty,
                   FileManager.default.fileExists(atPath: dependency.path) {
                    throw AssociatedRasterStyleError.sourceChanged
                }
                continue
            }
            let url = URL(fileURLWithPath: dependency.path)
            let actual = try await Self.sourceRevision(at: url)
            guard actual.caseInsensitiveCompare(dependency.revision) == .orderedSame else {
                throw AssociatedRasterStyleError.sourceChanged
            }
            try requireCurrent(context)
        }
    }

    private static func sameOwnerOrMaterializedNode(_ lhs: AssociatedRasterStyleContext,
                                                     _ rhs: AssociatedRasterStyleContext) -> Bool {
        let exactNode = lhs.node == rhs.node
        let materializedNode = !exactNode
            && sameLocatorOrMaterializationSuccessor(lhs.node, rhs.node)
        let materializedGeometryParent = materializedNode
            && lhs.node.parentGeometryNodePath == nil
            && rhs.node.parentGeometryNodePath?.isEmpty == false
        let workflowIdentityMatches = lhs.mapWorkflowIdentity == rhs.mapWorkflowIdentity
            || materializedNode
        return lhs.projectSessionID == rhs.projectSessionID
            && workflowIdentityMatches
            && sameMapExceptVisualizationRevision(lhs.map, rhs.map)
            && (exactNode || materializedNode)
            && SourceFilePaths.canonical(URL(fileURLWithPath: lhs.sourcePath))
                == SourceFilePaths.canonical(URL(fileURLWithPath: rhs.sourcePath))
            && lhs.sourceRevision.caseInsensitiveCompare(rhs.sourceRevision) == .orderedSame
            && lhs.geometryNodes == rhs.geometryNodes
            && lhs.planNodes == rhs.planNodes
            && sameResultOwner(lhs.resultOwner, rhs.resultOwner)
            && (!materializedGeometryParent || (sameResultParent(lhs.node, owner: lhs.resultOwner)
                && sameResultParent(rhs.node, owner: rhs.resultOwner)))
    }

    /// A committed style write may materialize a source-default raster row. A
    /// Result-owned row can require its implicit Geometry parent to be written
    /// at the same time. Permit only those two nil-to-path changes; all asset,
    /// parent, Result, Plan, association, and revision identities stay exact.
    private static func sameLocatorOrMaterializationSuccessor(
        _ lhs: CatalogTreeNodeLocator,
        _ rhs: CatalogTreeNodeLocator) -> Bool {
        guard lhs.nodePath == nil, let leafPath = rhs.nodePath, !leafPath.isEmpty else {
            return false
        }

        let materializedGeometryParent = lhs.parentGeometryNodePath == nil
            && rhs.parentGeometryNodePath?.isEmpty == false
        var left = lhs
        var right = rhs
        left.nodePath = nil
        right.nodePath = nil
        if materializedGeometryParent {
            left.parentGeometryNodePath = nil
            right.parentGeometryNodePath = nil
        }
        guard left == right else { return false }

        guard materializedGeometryParent else { return true }
        guard let geometryPath = rhs.parentGeometryNodePath,
              let resultPath = rhs.parentResultNodePath,
              !resultPath.isEmpty,
              let resultType = rhs.parentResultNodeType,
              resultType == "Result" || resultType == "MultiResult",
              let resultName = rhs.parentResultNodeName, !resultName.isEmpty,
              let resultAsset = rhs.parentResultAssetID, resultAsset.hasPrefix("/"),
              let resultRevision = rhs.parentResultRevision, isSHA256(resultRevision),
              let geometryName = rhs.parentGeometryNodeName, !geometryName.isEmpty,
              let geometryAsset = rhs.parentGeometryAssetID, geometryAsset.hasPrefix("/"),
              geometryPath.count == resultPath.count + 1,
              Array(geometryPath.prefix(resultPath.count)) == resultPath,
              leafPath.count == geometryPath.count + 1,
              Array(leafPath.prefix(geometryPath.count)) == geometryPath else {
            return false
        }
        return true
    }

    private static func sameResultParent(_ node: CatalogTreeNodeLocator,
                                         owner: MapResultGeometryOwner?) -> Bool {
        guard let owner,
              node.parentResultNodeType == owner.resultNode.nodeType,
              node.parentResultNodePath == owner.resultNode.nodePath,
              node.parentResultNodeName == owner.resultNode.nodeName,
              let parentPath = node.parentResultAssetID,
              SourceFilePaths.canonical(URL(fileURLWithPath: parentPath))
                == SourceFilePaths.canonical(URL(fileURLWithPath: owner.selectedResultPath)),
              let parentRevision = node.parentResultRevision else {
            return false
        }
        return parentRevision.caseInsensitiveCompare(owner.selectedResultRevision) == .orderedSame
    }

    private static func sameMapExceptVisualizationRevision(_ lhs: MapTreeMapIdentity,
                                                            _ rhs: MapTreeMapIdentity) -> Bool {
        lhs.projectPath == rhs.projectPath
            && lhs.projectXml == rhs.projectXml
            && lhs.projectXmlSHA.caseInsensitiveCompare(rhs.projectXmlSHA) == .orderedSame
            && lhs.mapID == rhs.mapID
            && lhs.mapIndex == rhs.mapIndex
            && lhs.mapName == rhs.mapName
            && lhs.mapType == rhs.mapType
    }

    private static func sameResultOwner(_ lhs: MapResultGeometryOwner?,
                                        _ rhs: MapResultGeometryOwner?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (left?, right?):
            return left.resultNode == right.resultNode
                && left.selectionIndex == right.selectionIndex
                && left.selectionOverrides == right.selectionOverrides
                && SourceFilePaths.canonical(URL(fileURLWithPath: left.selectedResultPath))
                    == SourceFilePaths.canonical(URL(fileURLWithPath: right.selectedResultPath))
                && left.selectedResultRevision.caseInsensitiveCompare(right.selectedResultRevision) == .orderedSame
        default: return false
        }
    }

    private static func valid(dependencies: [AssociatedRasterStyleDependency],
                              sourcePath: String,
                              sourceRevision: String) -> Bool {
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let canonicalSourcePath = SourceFilePaths.canonical(sourceURL)
        let sourceDependencies = dependencies.filter { $0.role == "source-hdf" }
        guard !dependencies.isEmpty, sourceDependencies.count == 1,
              SourceFilePaths.canonical(URL(fileURLWithPath: sourceDependencies[0].path)) == canonicalSourcePath,
              sourceDependencies[0].revision.caseInsensitiveCompare(sourceRevision) == .orderedSame else {
            return false
        }

        var identities = Set<String>()
        for dependency in dependencies {
            guard !dependency.role.isEmpty else { return false }
            let key = "\(dependency.role.utf8.count):\(dependency.role)|\(dependency.path.utf8.count):\(dependency.path)"
            guard identities.insert(key).inserted else { return false }
            if dependency.revision == "missing" {
                guard dependency.role != "source-hdf",
                      dependency.path.isEmpty || dependency.path.hasPrefix("/"),
                      dependency.path.isEmpty || SourceFilePaths.canonical(
                        URL(fileURLWithPath: dependency.path)) == dependency.path else { return false }
                continue
            }
            guard ["source-hdf", "geometry-hdf", "plan-hdf", "result-hdf",
                   "terrain-input-raster", "classification-source-hdf",
                   "classification-input-raster"].contains(dependency.role),
                  isSHA256(dependency.revision), dependency.path.hasPrefix("/"),
                  SourceFilePaths.canonical(URL(fileURLWithPath: dependency.path)) == dependency.path else {
                return false
            }
        }
        return true
    }

    private static func valid(draft: AssociatedRasterStyleDraft) -> Bool {
        // The retained source permits an unnamed, manually-authored ramp:
        // DraftFrom maps SurfaceFill.Name == nil to an empty string, and the
        // source validator rejects null but not an empty name. Keep all value,
        // stop-order, and range checks below while preserving that source case.
        guard ["Manual", "Linear", "Histogram"].contains(draft.valueSource),
              (0...255).contains(draft.alpha), ["Nearest", "Linear", "Smooth", "AreaAveraged", "Hybrid"].contains(draft.interpolationMode),
              (0...1_000_000).contains(draft.smoothingRadius),
              (0...1_000_000).contains(draft.resampleCellSizeRatio),
              (0...1_000_000).contains(draft.hillshadeZFactor),
              (-1_000_000...1_000_000).contains(draft.hillshadeAzimuth),
              (-1_000_000...1_000_000).contains(draft.hillshadeZenith),
              (0.000001...1_000_000).contains(draft.contourInterval),
              (0...1_000).contains(draft.contourIndexEvery),
              (0...100).contains(draft.contourOpacity), draft.contourDensity.isFinite,
              (0.025...4).contains(draft.contourDensity),
              (2...256).contains(draft.stops.count),
              draft.stops.enumerated().allSatisfy({ $0.element.index == $0.offset
                  && $0.element.value.isFinite && $0.element.color.hasPrefix("#") }) else { return false }
        return zip(draft.stops, draft.stops.dropFirst()).allSatisfy { $0.value < $1.value }
    }

    private static func valid(palette: AssociatedRasterStylePalette) -> Bool {
        !palette.id.isEmpty && !palette.name.isEmpty && palette.colors.count >= 2
            && palette.colors.allSatisfy { $0.hasPrefix("#") }
            && (palette.values == nil || palette.values?.count == palette.colors.count)
            && (palette.values?.allSatisfy(\.isFinite) ?? true)
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value == value.uppercased()
            && value.allSatisfy(\.isHexDigit)
    }

    private static func sourceRevision(at url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            return SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
        }.value
    }
}
