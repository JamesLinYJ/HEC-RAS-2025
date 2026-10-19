import Foundation
import RASWorkspaceCore

struct MapResultRenderRequest: Encodable, Sendable {
    let map: MapResultChartMapRequest
    let selectionOverrides: [MapResultSelectionOverride]
    let contextToken: String
    let node: CatalogTreeNodeLocator
    let profileIndex: Int?
    let viewport: RasterMapViewExtent?
    let blockedSelectionIndices: [Int]
    let liveKeyframeAnchor: MapResultRenderLiveKeyframeAnchor?

    init(map: MapResultChartMapRequest,
         selectionOverrides: [MapResultSelectionOverride],
         contextToken: String,
         node: CatalogTreeNodeLocator,
         profileIndex: Int?,
         viewport: RasterMapViewExtent?,
         blockedSelectionIndices: [Int] = [],
         liveKeyframeAnchor: MapResultRenderLiveKeyframeAnchor? = nil) {
        self.map = map
        self.selectionOverrides = selectionOverrides
        self.contextToken = contextToken
        self.node = node
        self.profileIndex = profileIndex
        self.viewport = viewport
        self.blockedSelectionIndices = blockedSelectionIndices
        self.liveKeyframeAnchor = liveKeyframeAnchor
    }
}

struct MapResultRenderLiveKeyframeAnchor: Codable, Hashable, Sendable {
    let node: CatalogTreeNodeLocator
    let selectionIndex: Int
    let runID: String
    let resultPath: String
    let outputBlockName: String
    let profileCount: Int
    let profileIndex: Int
    let profileName: String
    let time: String
}

struct MapResultRenderLiveKeyframeProfile: Equatable, Sendable {
    let index: Int
    let name: String
    let time: String
}

/// Metadata reported by the exact compute-owned BaseOutputBlock. It supplies
/// a temporary keyframe timeline while slot zero's writer-owned Result is
/// excluded from stable Project loading; it never represents raster data.
struct MapResultRenderLiveKeyframeTimeline: Equatable, Sendable {
    let node: CatalogTreeNodeLocator
    let runID: String
    let resultPath: String
    let outputBlockName: String
    let profileCount: Int
    let profiles: [MapResultRenderLiveKeyframeProfile]

    /// Compute currently publishes one BaseOutputBlock. Project it through
    /// the common block shape without changing its source identity.
    var blocks: [LiveMapResultOutputBlock] {
        let indexedProfiles = Dictionary(uniqueKeysWithValues: profiles.map { profile in
            (profile.index, LiveMapResultProfile(index: profile.index,
                name: profile.name, time: profile.time))
        })
        return [LiveMapResultOutputBlock(name: outputBlockName,
            profileCount: profileCount, profilesByIndex: indexedProfiles,
            errorMessage: nil)]
    }

    func anchor(for profileIndex: Int) -> MapResultRenderLiveKeyframeAnchor? {
        guard profileCount > 0, profileIndex >= 0, profileIndex < profileCount,
              let profile = profiles.first(where: { $0.index == profileIndex }),
              !profile.name.isEmpty, Self.isRoundTripTime(profile.time) else { return nil }
        return MapResultRenderLiveKeyframeAnchor(node: node, selectionIndex: 0,
            runID: runID, resultPath: resultPath, outputBlockName: outputBlockName,
            profileCount: profileCount, profileIndex: profile.index,
            profileName: profile.name, time: profile.time)
    }

    private static func isRoundTripTime(_ value: String) -> Bool {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.isLenient = false
        let hasZone = value.hasSuffix("Z") || value.dropFirst(19).contains("+")
            || value.dropFirst(19).contains("-")
        formatter.dateFormat = hasZone
            ? "yyyy-MM-dd'T'HH:mm:ss.SSSSSSSXXXXX"
            : "yyyy-MM-dd'T'HH:mm:ss.SSSSSSS"
        return formatter.date(from: value) != nil
    }
}

struct MapResultRenderStep: Decodable, Identifiable, Sendable {
    let id: Int
    let label: String
    let time: String
}

struct MapResultRenderLegendStop: Decodable, Sendable {
    let color: String
    let value: Double
}

struct MapResultRenderSourceStatus: Decodable, Identifiable, Sendable {
    let resultPath: String
    let revision: String
    let resultName: String
    let selectionIndices: [Int]
    let terrainPath: String?
    let terrainRevision: String?
    let available: Bool
    let profileIndex: Int?
    let unavailableReason: String?

    var id: String { SourceFilePaths.canonical(URL(fileURLWithPath: resultPath)) + "|" + revision }

}

struct MapResultRenderLayerPayload: Decodable, Identifiable, Sendable {
    let id: String
    let sourceID: String
    let sourceMapID: String
    let resultPath: String
    let revision: String
    let resultName: String
    let mapType: String
    let terrainPath: String
    let terrainRevision: String
    let profileIndex: Int
    let profileName: String
    let time: String
    let units: String
    let width: Int
    let height: Int
    let rgba: Data
    let minX: Double
    let minY: Double
    let maxX: Double
    let maxY: Double
    let noDataValue: Float
    let legendStops: [MapResultRenderLegendStop]

    func makeLayer(expectedMapID: UUID) throws -> MapRasterLayer {
        guard let returnedMapID = UUID(uuidString: sourceMapID), returnedMapID == expectedMapID else {
            throw BackendServiceError(code: "sourceChanged", message: "The result render reply belongs to a different map.")
        }
        return try MapRasterLayer(id: id, name: resultName + " · " + mapType,
            width: width, height: height, rgba: rgba,
            lowerLeft: MapPoint(x: minX, y: minY), upperRight: MapPoint(x: maxX, y: maxY),
            sourceMapID: expectedMapID)
    }

}

struct MapResultRenderResult: Decodable, Sendable {
    let contextToken: String
    let sourceID: String
    let selectedProfileIndex: Int
    let selectedProfileTime: String?
    let steps: [MapResultRenderStep]
    let layers: [MapResultRenderLayerPayload]
    let sources: [MapResultRenderSourceStatus]
    let unavailableReason: String?

    func mapUpdate(expectedMapID: UUID) throws -> MapUpdate {
        let renderedLayers = try layers.map { try $0.makeLayer(expectedMapID: expectedMapID) }
        struct SourceIdentity: Hashable {
            let path: String
            let revision: String

            init(path: String, revision: String) {
                self.path = SourceFilePaths.canonical(URL(fileURLWithPath: path))
                self.revision = revision.lowercased()
            }
        }
        var sourceIndices: [SourceIdentity: [Int]] = [:]
        var ambiguousSources: Set<SourceIdentity> = []
        var seenSources: Set<SourceIdentity> = []
        for source in sources {
            let identity = SourceIdentity(path: source.resultPath, revision: source.revision)
            guard seenSources.insert(identity).inserted else {
                ambiguousSources.insert(identity)
                sourceIndices.removeValue(forKey: identity)
                continue
            }
            let indices = source.selectionIndices
            guard !indices.isEmpty, indices.allSatisfy({ $0 >= 0 }),
                  Set(indices).count == indices.count else { continue }
            sourceIndices[identity] = indices
        }

        var selectionIndicesByLayerID: [String: [Int]] = [:]
        var sourceIdentityByLayerID: [String: MapRasterSourceIdentity] = [:]
        var ambiguousLayerIDs: Set<String> = []
        var seenLayerIDs: Set<String> = []
        for layer in layers {
            guard seenLayerIDs.insert(layer.id).inserted else {
                selectionIndicesByLayerID.removeValue(forKey: layer.id)
                sourceIdentityByLayerID.removeValue(forKey: layer.id)
                ambiguousLayerIDs.insert(layer.id)
                continue
            }
            let identity = SourceIdentity(path: layer.resultPath, revision: layer.revision)
            guard !ambiguousSources.contains(identity),
                  let indices = sourceIndices[identity] else { continue }
            if let previous = selectionIndicesByLayerID[layer.id], previous != indices {
                selectionIndicesByLayerID.removeValue(forKey: layer.id)
                sourceIdentityByLayerID.removeValue(forKey: layer.id)
                ambiguousLayerIDs.insert(layer.id)
            } else if !ambiguousLayerIDs.contains(layer.id) {
                selectionIndicesByLayerID[layer.id] = indices
                sourceIdentityByLayerID[layer.id] = MapRasterSourceIdentity(
                    resultPath: layer.resultPath, revision: layer.revision)
            }
        }
        return MapUpdate(vectors: nil, rasters: renderedLayers, preview: [],
            selectedLayerID: nil, selectedFeatureID: nil,
            rasterSelectionIndicesByLayerID: selectionIndicesByLayerID,
            rasterSourceIdentityByLayerID: sourceIdentityByLayerID)
    }
}
